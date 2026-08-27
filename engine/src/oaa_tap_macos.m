/*
 * oaa_tap_macos.m — Core Audio process taps. See oaa_tap.h for what and why.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Objective-C, and only just
 *
 * `CATapDescription` is an Objective-C class and `AudioHardwareCreateProcessTap`
 * takes one, so there is no C spelling of this and there will not be —
 * AudioHardwareTapping.h is wrapped in `#ifdef __OBJC__` in the SDK. This is
 * the only file in the engine that is not C, and it is deliberately the only
 * one: everything it exposes to the rest of the engine is the plain C in
 * oaa_tap.h, so oaa_device.c never sees an object.
 *
 * Manual retain/release rather than ARC, because enabling ARC is a compiler
 * flag and there is no per-source flag in either of the engine's two build
 * descriptions — it would land on all thirteen translation units and on
 * vendored miniaudio and pffft, to spare this file exactly two `release` calls.
 * Both are marked. The `CFRelease` calls are not among them: Core Foundation
 * objects are hand-released under ARC too.
 *
 * ---------------------------------------------------------------------------
 * The real-time contract
 *
 * `io_proc` runs on a Core Audio thread with the same rules as the miniaudio
 * callback in oaa_device.c: no allocation, no locking, no Objective-C. It does
 * a bounds check and a memcpy into the lock-free ring, or — when the tap hands
 * back deinterleaved buffers — an interleave into a scratch buffer allocated
 * once at open, in bounded chunks so that no buffer size can make it allocate.
 *
 * It deliberately does nothing about a full ring: `oaa_ring_write` counts what
 * it could not take and the engine publishes that as OAA_FLAG_OVERRUN, because
 * quietly overwriting would leave the integrated loudness averaging over audio
 * that never reached it.
 */

#include "oaa_tap.h"

#if OAA_TAP_SUPPORTED

#include "oaa/oaa.h"

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Chunk size for the deinterleaving path. Bounded so that the scratch buffer
 * is a fixed size at open and no buffer any device produces can make the
 * callback allocate — a larger block is interleaved in several passes. */
#define OAA_TAP_SCRATCH_FRAMES 4096

struct oaa_tap {
  /* Built in this order and torn down in reverse. Every one of them is
   * kAudioObjectUnknown / NULL until it exists, which is what lets
   * teardown_chain run against a half-built chain — an aggregate device that
   * outlives the process is visible to every audio application on the machine
   * until a reboot, so a failed open must not leak one. */
  AudioObjectID tap;
  AudioObjectID aggregate;
  AudioDeviceIOProcID proc;
  int running;

  /* The device this tap is bound to, and the format the engine was configured
   * against. A rebuild that cannot match both does not happen — see the
   * "What it does not do" section of oaa_tap.h. */
  AudioObjectID bound_device;
  uint32_t sample_rate;
  uint32_t channels;

  /* Published by oaa_tap_start before the IO proc can run, read by the
   * callback. */
  oaa_ring *ring;

  /* Deinterleaving scratch, or NULL when the tap hands back interleaved
   * buffers — which is what every device tested so far does. Allocated at
   * open, never in the callback. */
  float *scratch;

  /* Serialises rebuild against close. The callback never takes it. */
  pthread_mutex_t lock;
  int closing;

  dispatch_queue_t queue;
  AudioObjectPropertyListenerBlock listener;
};

/* ------------------------------------------------------------------------ */
/* Reading the system's mind                                                 */
/* ------------------------------------------------------------------------ */

static const AudioObjectPropertyAddress kDefaultOutputAddress = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain};

static AudioObjectID default_output_device(void) {
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                 &kDefaultOutputAddress, 0, NULL, &size,
                                 &device) != noErr) {
    return kAudioObjectUnknown;
  }
  return device;
}

/* Caller releases. */
static CFStringRef copy_device_uid(AudioObjectID device) {
  CFStringRef uid = NULL;
  UInt32 size = sizeof(uid);
  const AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceUID,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &uid) !=
      noErr) {
    return NULL;
  }
  return uid;
}

/*
 * The virtual format of the device's first output stream.
 *
 * Queried on the *stream* rather than the device, because that is exactly what
 * `initExcludingProcesses:andDeviceUID:withStream:` binds to — the SDK says
 * "the format of the tap will match the format of this stream", so asking the
 * same object the same question is what makes the number reported by probe the
 * number open will produce.
 */
static int stream_format(AudioObjectID device, AudioStreamBasicDescription *out) {
  const AudioObjectPropertyAddress streams_address = {
      kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
      kAudioObjectPropertyElementMain};

  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &streams_address, 0, NULL,
                                     &size) != noErr ||
      size < sizeof(AudioObjectID)) {
    return 0;
  }

  AudioObjectID first = kAudioObjectUnknown;
  size = sizeof(first);
  /* Asking for one stream's worth returns the first one; the device may have
   * more and we want stream 0, which is the one the tap is bound to. */
  if (AudioObjectGetPropertyData(device, &streams_address, 0, NULL, &size,
                                 &first) != noErr ||
      first == kAudioObjectUnknown) {
    return 0;
  }

  const AudioObjectPropertyAddress format_address = {
      kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  size = sizeof(*out);
  if (AudioObjectGetPropertyData(first, &format_address, 0, NULL, &size, out) !=
      noErr) {
    return 0;
  }
  return 1;
}

static void copy_device_name(AudioObjectID device, char *out, size_t capacity) {
  out[0] = '\0';
  CFStringRef name = NULL;
  UInt32 size = sizeof(name);
  const AudioObjectPropertyAddress address = {kAudioObjectPropertyName,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) !=
          noErr ||
      name == NULL) {
    return;
  }
  CFStringGetCString(name, out, (CFIndex)capacity, kCFStringEncodingUTF8);
  CFRelease(name);
}

/* ------------------------------------------------------------------------ */
/* The real-time callback                                                    */
/* ------------------------------------------------------------------------ */

static void io_proc(oaa_tap *self, const AudioBufferList *input) {
  oaa_ring *ring = self->ring;
  if (ring == NULL || input == NULL || input->mNumberBuffers == 0) {
    /* The ring is attached by oaa_tap_start. A callback before that would mean
     * Core Audio started the aggregate behind our back; dropping is the only
     * safe response and it cannot happen in the intended sequence. */
    return;
  }

  const uint32_t channels = self->channels;

  /* The ordinary case, and the only one seen on any device tested: one buffer
   * carrying every channel, already interleaved. Straight into the ring. */
  if (input->mNumberBuffers == 1) {
    const AudioBuffer *buffer = &input->mBuffers[0];
    if (buffer->mData == NULL || buffer->mNumberChannels != channels) {
      return;
    }
    const uint32_t frames =
        (uint32_t)(buffer->mDataByteSize / (sizeof(float) * channels));
    if (frames > 0) {
      oaa_ring_write(ring, (const float *)buffer->mData, frames);
    }
    return;
  }

  /* Deinterleaved: one buffer per channel. Interleave into the scratch
   * allocated at open, in chunks, so nothing here can allocate. */
  if (self->scratch == NULL || input->mNumberBuffers != channels) {
    return;
  }

  uint32_t frames = UINT32_MAX;
  for (UInt32 c = 0; c < input->mNumberBuffers; c++) {
    if (input->mBuffers[c].mData == NULL) return;
    const uint32_t count =
        (uint32_t)(input->mBuffers[c].mDataByteSize / sizeof(float));
    if (count < frames) frames = count;
  }
  if (frames == 0 || frames == UINT32_MAX) return;

  for (uint32_t offset = 0; offset < frames;) {
    uint32_t chunk = frames - offset;
    if (chunk > OAA_TAP_SCRATCH_FRAMES) chunk = OAA_TAP_SCRATCH_FRAMES;

    for (uint32_t c = 0; c < channels; c++) {
      const float *source = (const float *)input->mBuffers[c].mData + offset;
      float *destination = self->scratch + c;
      for (uint32_t i = 0; i < chunk; i++) {
        destination[(size_t)i * channels] = source[i];
      }
    }
    oaa_ring_write(ring, self->scratch, chunk);
    offset += chunk;
  }
}

/* ------------------------------------------------------------------------ */
/* Building and unbuilding the chain                                         */
/* ------------------------------------------------------------------------ */

static void teardown_chain(oaa_tap *self) {
  if (self->proc != NULL) {
    if (self->running) {
      AudioDeviceStop(self->aggregate, self->proc);
      self->running = 0;
    }
    AudioDeviceDestroyIOProcID(self->aggregate, self->proc);
    self->proc = NULL;
  }
  if (self->aggregate != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(self->aggregate);
    self->aggregate = kAudioObjectUnknown;
  }
  if (self->tap != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(self->tap);
    self->tap = kAudioObjectUnknown;
  }
}

/*
 * Builds tap -> aggregate -> IO proc against `device`.
 *
 * `want_rate` and `want_channels` are zero on the first open, meaning "adopt
 * whatever this device produces", and are the engine's configured format on a
 * rebuild, meaning "refuse anything else". That asymmetry is the whole of the
 * device-change policy: the engine's DSP is sized once and a rebuild that
 * changed the format underneath it would be measuring a different signal than
 * the one the meters were built for.
 */
static int32_t build_chain(oaa_tap *self, AudioObjectID device,
                           uint32_t want_rate, uint32_t want_channels) {
  if (device == kAudioObjectUnknown) {
    return OAA_ERR_UNSUPPORTED;
  }

  AudioStreamBasicDescription asbd;
  memset(&asbd, 0, sizeof(asbd));
  if (!stream_format(device, &asbd)) {
    return OAA_ERR_UNSUPPORTED;
  }

  const uint32_t rate = (uint32_t)asbd.mSampleRate;
  const uint32_t channels = asbd.mChannelsPerFrame;
  if (rate == 0 || channels == 0 || channels > OAA_MAX_CHANNELS) {
    /* Open Audio Analyzer's graph carries at most 7.1. A wider output is
     * refused rather than silently measuring the first eight channels and
     * calling the result the programme loudness. */
    return OAA_ERR_UNSUPPORTED;
  }
  if ((want_rate != 0 && want_rate != rate) ||
      (want_channels != 0 && want_channels != channels)) {
    return OAA_ERR_UNSUPPORTED;
  }

  CFStringRef uid = copy_device_uid(device);
  if (uid == NULL) {
    return OAA_ERR_UNSUPPORTED;
  }

  int32_t status = OAA_ERR_UNSUPPORTED;

  @autoreleasepool {
    /* Two UUIDs, not one. The tap and the aggregate device are separate Core
     * Audio objects and each is looked up by its own UID string; giving them
     * the same one works today and is the kind of coincidence that stops
     * working quietly. */
    NSUUID *uuid = [NSUUID UUID];
    NSString *aggregate_uid = [[NSUUID UUID] UUIDString];

    /* Bound to one stream of one device, not a global mixdown: the global
     * variants fold everything to stereo. `CATapUnmuted` keeps the audio
     * flowing to the speakers — metering must not be audible. */
    CATapDescription *description = [[CATapDescription alloc]
        initExcludingProcesses:@[]
                  andDeviceUID:(__bridge NSString *)uid
                    withStream:0];
    if (description == nil) {
      CFRelease(uid);
      return OAA_ERR_UNSUPPORTED;
    }
    description.name = @"Open Audio Analyzer";
    description.UUID = uuid;
    description.muteBehavior = CATapUnmuted;
    /* Visible only to this process, so the tap never appears in anybody
     * else's device list. */
    description.privateTap = YES;

    AudioObjectID tap = kAudioObjectUnknown;
    const OSStatus created = AudioHardwareCreateProcessTap(description, &tap);
    [description release]; /* (1 of 2) manual release. */

    if (created != noErr || tap == kAudioObjectUnknown) {
      CFRelease(uid);
      return OAA_ERR_UNSUPPORTED;
    }
    self->tap = tap;

    /* A tap cannot be read from. It becomes readable by being a sub-tap of a
     * private aggregate device, whose input stream then carries it. The output
     * device rides along as the main sub-device so the aggregate has a clock
     * to run on; we never write to it. */
    NSDictionary *aggregate_description = @{
      @kAudioAggregateDeviceNameKey : @"Open Audio Analyzer System Capture",
      @kAudioAggregateDeviceUIDKey : aggregate_uid,
      @kAudioAggregateDeviceIsPrivateKey : @YES,
      @kAudioAggregateDeviceIsStackedKey : @NO,
      @kAudioAggregateDeviceTapAutoStartKey : @YES,
      @kAudioAggregateDeviceSubDeviceListKey :
          @[ @{@kAudioSubDeviceUIDKey : (__bridge NSString *)uid} ],
      @kAudioAggregateDeviceMainSubDeviceKey : (__bridge NSString *)uid,
      @kAudioAggregateDeviceTapListKey : @[ @{
        @kAudioSubTapUIDKey : [uuid UUIDString],
        @kAudioSubTapDriftCompensationKey : @YES,
      } ],
    };

    AudioObjectID aggregate = kAudioObjectUnknown;
    if (AudioHardwareCreateAggregateDevice(
            (__bridge CFDictionaryRef)aggregate_description, &aggregate) !=
            noErr ||
        aggregate == kAudioObjectUnknown) {
      teardown_chain(self);
      CFRelease(uid);
      return OAA_ERR_UNSUPPORTED;
    }
    self->aggregate = aggregate;

    AudioDeviceIOProcID proc = NULL;
    if (AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregate, NULL,
            ^(const AudioTimeStamp *now, const AudioBufferList *input,
              const AudioTimeStamp *input_time, AudioBufferList *output,
              const AudioTimeStamp *output_time) {
              (void)now;
              (void)input_time;
              (void)output;
              (void)output_time;
              io_proc(self, input);
            }) != noErr ||
        proc == NULL) {
      teardown_chain(self);
      CFRelease(uid);
      return OAA_ERR_UNSUPPORTED;
    }
    self->proc = proc;

    self->bound_device = device;
    self->sample_rate = rate;
    self->channels = channels;
    status = OAA_OK;
  }

  CFRelease(uid);
  return status;
}

/*
 * Whether the chain is running *and* still carrying the format the engine was
 * built around. Called with the lock held.
 *
 * The second half is not paranoia, it is a defect this caught. A Bluetooth
 * output device changes its own sample rate without ever ceasing to be the
 * default output — AirPods offer 48 kHz and 24 kHz and drop to 24 the moment
 * anything opens their microphone — so the default-output listener never fires,
 * the aggregate device goes on running, and the IO proc goes on delivering. At
 * half the frame rate. The engine, whose K-weighting filters, true-peak
 * oversampler, spectrum axis and elapsed clock were all built for 48 kHz, has
 * no way to notice: it simply measures 24 kHz audio through 48 kHz coefficients
 * and publishes the results, with the meters moving and every number wrong by
 * an octave. Measured, not imagined — `elapsed_seconds` advanced at half real
 * time for as long as the mode lasted.
 *
 * So a format that has moved is reported as a source that has stopped, which is
 * what it is: there is no longer anything here this engine can measure. The
 * revive that follows tears the chain down and refuses to rebuild it until the
 * format comes back, and the application reopens at the new rate — the only
 * thing that can, because every coefficient downstream is derived from it.
 *
 * Two HAL property queries on the analysing thread, four times a second. They
 * are cheap and they can block for a few milliseconds while Core Audio
 * reconfigures, which costs a late publish and no audio at all: the ring holds
 * half a second. A listener would avoid even that, and was not worth it — this
 * compares the format the device actually has, rather than trusting a
 * notification to have fired.
 */
static int chain_healthy_locked(oaa_tap *self) {
  if (!self->running) {
    return 0;
  }

  AudioStreamBasicDescription asbd;
  memset(&asbd, 0, sizeof(asbd));
  if (!stream_format(self->bound_device, &asbd)) {
    /* The device stopped answering: unplugged, or turned off. */
    return 0;
  }

  return (uint32_t)asbd.mSampleRate == self->sample_rate &&
         asbd.mChannelsPerFrame == self->channels;
}

/*
 * Tears the chain down and builds a fresh one against `device`, at the format
 * the engine was configured with, and starts it. Called with the lock held.
 *
 * The format is read off the tap's own fields rather than passed in, because
 * they are the engine's: `build_chain` only ever writes them on success and a
 * refused rebuild leaves them naming the format the DSP graph upstairs is still
 * sized for. Passing zeros here — "adopt whatever this device produces" — is
 * the one thing that must not happen on a rebuild, and having exactly one
 * function that can perform one is how that stays true.
 *
 * Returns OAA_OK only when the IO proc is running by the time it returns.
 */
static int32_t rebuild_locked(oaa_tap *self, AudioObjectID device) {
  const uint32_t rate = self->sample_rate;
  const uint32_t channels = self->channels;

  teardown_chain(self);

  const int32_t status = build_chain(self, device, rate, channels);
  if (status != OAA_OK) {
    return status;
  }
  if (AudioDeviceStart(self->aggregate, self->proc) != noErr) {
    /* A built chain that will not start is worse than none: it is a tap the
     * next rebuild would have to tear down anyway, and an aggregate device left
     * on the machine if the process died first. */
    teardown_chain(self);
    return OAA_ERR_THREAD;
  }
  self->running = 1;
  return OAA_OK;
}

/* ------------------------------------------------------------------------ */
/* Probe                                                                     */
/* ------------------------------------------------------------------------ */

int32_t oaa_tap_probe(uint32_t *sample_rate, uint32_t *channels, char *name,
                      size_t name_capacity) {
  /* No `@available` check, and its absence is the point. The engine's
   * deployment target is 14.2 — asserted in oaa_tap.h, which says why — so
   * there is no older system to keep out of these symbols. The check that used
   * to be here claimed to be guarding weak-linked ones and was guarding a
   * strong class reference that had already decided whether the library could
   * load at all. */
  const AudioObjectID device = default_output_device();
  if (device == kAudioObjectUnknown) {
    return OAA_ERR_UNSUPPORTED;
  }

  AudioStreamBasicDescription asbd;
  memset(&asbd, 0, sizeof(asbd));
  if (!stream_format(device, &asbd)) {
    return OAA_ERR_UNSUPPORTED;
  }
  const uint32_t rate = (uint32_t)asbd.mSampleRate;
  const uint32_t count = asbd.mChannelsPerFrame;
  if (rate == 0 || count == 0 || count > OAA_MAX_CHANNELS) {
    return OAA_ERR_UNSUPPORTED;
  }

  if (sample_rate != NULL) *sample_rate = rate;
  if (channels != NULL) *channels = count;

  if (name != NULL && name_capacity > 0) {
    /* Naming the device that would be tapped rather than just "System Output",
     * because which output is being metered is exactly the thing a person
     * needs to see and the only thing the menu can tell them. */
    char device_name[128];
    copy_device_name(device, device_name, sizeof(device_name));
    if (device_name[0] == '\0') {
      snprintf(name, name_capacity, "System Output");
    } else {
      snprintf(name, name_capacity, "System Output (%s)", device_name);
    }
  }
  return OAA_OK;
}

/* ------------------------------------------------------------------------ */
/* Open, start, close                                                        */
/* ------------------------------------------------------------------------ */

int32_t oaa_tap_open(oaa_tap **out, uint32_t *sample_rate, uint32_t *channels) {
  if (out == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  *out = NULL;

  oaa_tap *self = (oaa_tap *)calloc(1, sizeof(oaa_tap));
  if (self == NULL) {
    return OAA_ERR_OUT_OF_MEMORY;
  }
  self->tap = kAudioObjectUnknown;
  self->aggregate = kAudioObjectUnknown;
  self->bound_device = kAudioObjectUnknown;
  pthread_mutex_init(&self->lock, NULL);

  const int32_t status = build_chain(self, default_output_device(), 0, 0);
  if (status != OAA_OK) {
    pthread_mutex_destroy(&self->lock);
    free(self);
    return status;
  }

  /* Sized for the worst case the deinterleaving path can be handed, and only
   * allocated at all so that the callback never has to. */
  self->scratch = (float *)calloc((size_t)OAA_TAP_SCRATCH_FRAMES * self->channels,
                                  sizeof(float));
  if (self->scratch == NULL) {
    teardown_chain(self);
    pthread_mutex_destroy(&self->lock);
    free(self);
    return OAA_ERR_OUT_OF_MEMORY;
  }

  if (sample_rate != NULL) *sample_rate = self->sample_rate;
  if (channels != NULL) *channels = self->channels;

  *out = self;
  return OAA_OK;
}

int32_t oaa_tap_start(oaa_tap *tap, oaa_ring *ring) {
  if (tap == NULL || ring == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  if (ring->channels != tap->channels) {
    /* The mismatch the open/start split exists to prevent: the callback would
     * write past the end of a ring sized for a different layout. */
    return OAA_ERR_INVALID_ARGUMENT;
  }

  /* Published before the IO proc can run, so the first callback sees it. */
  tap->ring = ring;

  if (AudioDeviceStart(tap->aggregate, tap->proc) != noErr) {
    return OAA_ERR_THREAD;
  }
  tap->running = 1;

  /*
   * Follow the default output device.
   *
   * Without this, plugging in headphones leaves the tap bound to the speakers,
   * which are no longer being written to — and the meters would sit at their
   * floor showing digital black, which is a measurement of a signal nobody
   * played. Rebuilding on the new device fixes the common case; when the new
   * device's format does not match what the engine was built for, the tap
   * stops instead, which at least fails the same way an unplugged interface
   * does. See oaa_tap.h.
   *
   * Registered after the start, so a change arriving mid-open cannot race a
   * half-built chain.
   */
  tap->queue = dispatch_queue_create("audio.oaa.tap", DISPATCH_QUEUE_SERIAL);
  tap->listener =
      Block_copy(^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count;
        (void)addresses;
        pthread_mutex_lock(&tap->lock);
        if (!tap->closing) {
          const AudioObjectID next = default_output_device();
          if (next != tap->bound_device) {
            /* Failure here leaves `running` at zero and no chain at all, which
             * is exactly the state oaa_tap_revive exists to get out of. It used
             * to be a state nothing ever left: no producer, no retry, and no
             * way for the engine above to find out. See oaa_tap.h. */
            rebuild_locked(tap, next);
          }
        }
        pthread_mutex_unlock(&tap->lock);
      }); /* Block_copy — the matching Block_release is in close. */

  AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                      &kDefaultOutputAddress, tap->queue,
                                      tap->listener);
  return OAA_OK;
}

int32_t oaa_tap_running(oaa_tap *tap) {
  if (tap == NULL) {
    return 0;
  }
  if (pthread_mutex_trylock(&tap->lock) != 0) {
    /* The listener is rebuilding. Reporting "running" is not optimism, it is
     * the correct answer to the question the caller is really asking — is
     * anything wrong that I should act on — and blocking the analysis thread
     * behind a Core Audio aggregate build would stop it publishing for as long
     * as that takes. */
    return 1;
  }
  /* Before start(): not a fault. The engine polls from the moment its thread
   * begins, and a tap that has not been handed its ring is one the caller has
   * not finished opening. */
  const int32_t running =
      (tap->ring == NULL || chain_healthy_locked(tap)) ? 1 : 0;
  pthread_mutex_unlock(&tap->lock);
  return running;
}

int32_t oaa_tap_revive(oaa_tap *tap) {
  if (tap == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }

  /* Blocking, unlike the poll above: there is nothing to lose by waiting when
   * the producer is already gone, and a revive that skipped because a rebuild
   * held the lock would have to be retried anyway. */
  pthread_mutex_lock(&tap->lock);

  int32_t status;
  if (tap->closing) {
    status = OAA_ERR_WRONG_STATE;
  } else if (tap->ring == NULL) {
    /* Not started yet; oaa_tap_start is what starts it, not this. */
    status = OAA_ERR_WRONG_STATE;
  } else if (chain_healthy_locked(tap)) {
    status = OAA_OK;
  } else {
    /* Against the default output *now*, not against `bound_device`. The device
     * this tap was built for may be the very thing that went away, and the one
     * the user is listening to is by definition the current default. */
    status = rebuild_locked(tap, default_output_device());
  }

  pthread_mutex_unlock(&tap->lock);
  return status;
}

void oaa_tap_close(oaa_tap *tap) {
  if (tap == NULL) {
    return;
  }

  /* Refuse a rebuild before removing the listener, rather than after: removal
   * does not wait for a callback already in flight, and that callback would
   * otherwise build a fresh tap moments before the teardown below and leave
   * an aggregate device behind on the machine. */
  pthread_mutex_lock(&tap->lock);
  tap->closing = 1;
  pthread_mutex_unlock(&tap->lock);

  if (tap->listener != NULL) {
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                           &kDefaultOutputAddress, tap->queue,
                                           tap->listener);
    /* Drains anything already dispatched; the flag above makes it a no-op. */
    if (tap->queue != NULL) {
      dispatch_sync(tap->queue, ^{
      });
    }
    Block_release(tap->listener); /* (2 of 2) */
    tap->listener = NULL;
  }
  if (tap->queue != NULL) {
    dispatch_release(tap->queue);
    tap->queue = NULL;
  }

  teardown_chain(tap);
  free(tap->scratch);
  pthread_mutex_destroy(&tap->lock);
  free(tap);
}

#endif /* OAA_TAP_SUPPORTED */
