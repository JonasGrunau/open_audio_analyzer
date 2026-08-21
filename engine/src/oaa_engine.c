/*
 * oaa_engine.c — lifecycle, the analysis thread, and the OS primitives.
 *
 * SPDX-License-Identifier: MIT
 *
 * The analysis thread is the spine of the whole design. It is the only thread
 * that writes measurements, which is what lets the reader side be a seqlock
 * instead of a mutex, which is what lets the UI read on the thread that is
 * about to paint. Everything downstream of that — no isolates, no channels, no
 * per-frame allocation — falls out of this one thread existing.
 *
 * It also *generates* the signal for the synthetic sources, because there is no
 * capture device yet. When one arrives, a real-time audio callback fills a ring
 * buffer and this thread drains it; the loop below is already shaped for that,
 * which is why it paces itself against a monotonic clock rather than spinning.
 *
 * OAA_SOURCE_PUSH has no thread at all — the caller's thread does the work
 * inside oaa_engine_push(). Everything the thread would have done in a given
 * iteration happens there instead, in the same order.
 */

#include "oaa_device.h"
#include "oaa_internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <errno.h>
#include <time.h>
#endif

#define OAA_VERSION_STRING "0.4.0"

#define OAA_DEFAULT_SAMPLE_RATE 48000u
#define OAA_DEFAULT_CHANNELS 2u

/* 1024 frames is 21.3 ms at 48 kHz, so measurements publish at about 47 Hz.
 * That is deliberately close to a display refresh: publishing much slower makes
 * the meters visibly steppy, and publishing much faster spends CPU on frames
 * nobody will ever see. */
#define OAA_DEFAULT_BLOCK_FRAMES 1024u

/* How much lateness the analysis loop will make up before giving up and
 * resynchronising. Roughly a dozen blocks: enough to absorb ordinary scheduler
 * jitter and a slow host, far short of replaying a backlog after a laptop
 * wakes from sleep. */
#define OAA_MAX_CATCHUP_SECONDS 0.25

/* How much audio the capture ring holds. Half a second is far more than any
 * ordinary scheduling hiccup needs and costs 384 kB at 48 kHz stereo; sizing
 * it tightly would save nothing worth having and would turn a hiccup into lost
 * audio, which is the one outcome a measurement cannot absorb. */
#define OAA_RING_SECONDS 0.5

/* ------------------------------------------------------------------------ */
/* OS primitives                                                             */
/* ------------------------------------------------------------------------ */

#if defined(_WIN32)

typedef struct {
  void *(*entry)(void *);
  void *arg;
} oaa_thread_trampoline;

static DWORD WINAPI oaa_thread_shim(LPVOID raw) {
  oaa_thread_trampoline *t = (oaa_thread_trampoline *)raw;
  void *(*entry)(void *) = t->entry;
  void *arg = t->arg;
  free(t);
  entry(arg);
  return 0;
}

int oaa_thread_start(oaa_thread *thread, void *(*entry)(void *), void *arg) {
  oaa_thread_trampoline *t =
      (oaa_thread_trampoline *)malloc(sizeof(oaa_thread_trampoline));
  if (t == NULL) {
    return OAA_ERR_OUT_OF_MEMORY;
  }
  t->entry = entry;
  t->arg = arg;

  *thread = CreateThread(NULL, 0, oaa_thread_shim, t, 0, NULL);
  if (*thread == NULL) {
    free(t);
    return OAA_ERR_THREAD;
  }
  return OAA_OK;
}

void oaa_thread_join(oaa_thread thread) {
  if (thread != NULL) {
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
  }
}

double oaa_now_seconds(void) {
  static LARGE_INTEGER frequency;
  if (frequency.QuadPart == 0) {
    QueryPerformanceFrequency(&frequency);
  }
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return (double)counter.QuadPart / (double)frequency.QuadPart;
}

void oaa_sleep_seconds(double seconds) {
  if (seconds <= 0.0) {
    return;
  }
  Sleep((DWORD)(seconds * 1000.0));
}

#else /* POSIX */

int oaa_thread_start(oaa_thread *thread, void *(*entry)(void *), void *arg) {
  return pthread_create(thread, NULL, entry, arg) == 0 ? OAA_OK : OAA_ERR_THREAD;
}

void oaa_thread_join(oaa_thread thread) { pthread_join(thread, NULL); }

double oaa_now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

void oaa_sleep_seconds(double seconds) {
  if (seconds <= 0.0) {
    return;
  }
  struct timespec request;
  request.tv_sec = (time_t)seconds;
  request.tv_nsec = (long)((seconds - (double)request.tv_sec) * 1e9);

  /* nanosleep returns early on a signal, and this thread will be interrupted
   * by the profiler and by the debugger. Resuming the remainder keeps the
   * pacing honest instead of quietly running fast. */
  struct timespec remaining;
  while (nanosleep(&request, &remaining) == -1 && errno == EINTR) {
    request = remaining;
  }
}

#endif

/* ------------------------------------------------------------------------ */
/* Resetting the integrators                                                 */
/* ------------------------------------------------------------------------ */

static void oaa_clear_measurements(oaa_engine *engine) {
  memset(engine->channel, 0, sizeof(engine->channel));
  oaa_loudness_reset(&engine->loudness);
  oaa_truepeak_reset(&engine->truepeak);
  oaa_spectrum_reset(&engine->spectrum);
  if (engine->ring_ready) {
    /* Clears the warning, not the ring: the audio already in flight is still
     * wanted, it is only the record of past losses that this measurement no
     * longer inherits. */
    oaa_ring_clear_dropped(&engine->ring);
  }
  engine->frames_done = 0;
  engine->sample_peak_max_linear = 0.0f;
  engine->corr_sum_lr = 0.0;
  engine->corr_sum_ll = 0.0;
  engine->corr_sum_rr = 0.0;

  oaa_snapshot *s = &engine->staging;
  s->elapsed_seconds = 0.0;
  s->sample_rate = engine->cfg.sample_rate;
  s->channels = engine->cfg.channels;
  s->flags = OAA_FLAG_SPECTRUM_UNAVAILABLE;
  s->dropped_frames = 0;

  s->lufs_momentary = NAN;
  s->lufs_short = NAN;
  s->lufs_integrated = NAN;
  s->lra = NAN;
  s->lra_low = NAN;
  s->lra_high = NAN;
  s->lra_gate = NAN;
  s->true_peak = NAN;
  s->true_peak_max = NAN;
  s->dr_short = NAN;
  s->dr_integrated = NAN;
  s->plr = NAN;
  s->psr = NAN;

  s->sample_peak_max = OAA_DB_FLOOR;
  s->crest = 0.0f;
  s->correlation = engine->cfg.channels >= 2 ? 0.0f : 1.0f;
  s->balance = 0.0f;

  for (uint32_t c = 0; c < OAA_MAX_CHANNELS; c++) {
    s->peak[c] = OAA_DB_FLOOR;
    s->rms[c] = OAA_DB_FLOOR;
    s->vu[c] = OAA_DB_FLOOR;
    s->clip[c] = 0;
  }
  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    s->spectrum[b] = OAA_DB_FLOOR;
    s->spectrum_peak[b] = OAA_DB_FLOOR;
    s->spectrum_pan[b] = 0.0f;
  }
  memset(s->scope, 0, sizeof(s->scope));
  memset(s->histogram, 0, sizeof(s->histogram));
}

/* ------------------------------------------------------------------------ */
/* The analysis thread                                                       */
/* ------------------------------------------------------------------------ */

/* The silence gate. Runs on the analysing thread, immediately before the block
 * it is judging is measured.
 *
 * Costs one read-only pass over the block, and only when the mode that needs it
 * is on — which is why it is a branch here rather than a term folded into
 * `oaa_analyse`'s existing loop. Every other caller (file analysis, and the
 * three LUFS modes driven by a playhead instead) pays nothing at all.
 *
 * The reset is performed in place rather than through `reset_pending`, because
 * that flag is honoured at the *start* of the next block — which would measure
 * this one into the integration it is supposed to begin and then throw it away.
 * See the note in oaa.h about material that opens on a transient. In place is
 * safe here for the same reason the pending flag exists: this runs on the thread
 * that owns the integrators, between blocks. */
static void oaa_silence_gate(oaa_engine *engine, const float *interleaved,
                             uint32_t frames) {
  if (!engine->silence_reset) {
    return;
  }

  const size_t samples = (size_t)frames * engine->cfg.channels;
  float peak = 0.0f;
  for (size_t i = 0; i < samples; i++) {
    const float magnitude = fabsf(interleaved[i]);
    if (magnitude > peak) {
      peak = magnitude;
    }
  }

  const double dt = (double)frames / (double)engine->cfg.sample_rate;

  if (peak < OAA_SILENCE_FLOOR) {
    engine->silence_seconds += dt;
    return;
  }

  if (engine->silence_seconds >= OAA_SILENCE_HOLD_SECONDS) {
    oaa_clear_measurements(engine);
  }
  engine->silence_seconds = 0.0;
}

/* The only way audio reaches the analysis. Three call sites — a push, a capture
 * device and a generated source — and routing all of them through here is what
 * stops the gate being wired into two of the three. */
static void oaa_analyse_gated(oaa_engine *engine, const float *interleaved,
                              uint32_t frames) {
  oaa_silence_gate(engine, interleaved, frames);
  oaa_analyse(engine, interleaved, frames);
}

void oaa_engine_set_silence_reset(oaa_engine *engine, int32_t enabled) {
  if (engine == NULL) {
    return;
  }
  engine->silence_reset = enabled ? 1 : 0;
  if (!enabled) {
    engine->silence_seconds = 0.0;
  }
}

static void *oaa_analysis_thread(void *raw) {
  oaa_engine *engine = (oaa_engine *)raw;

  const double block_seconds =
      (double)engine->cfg.block_frames / (double)engine->cfg.sample_rate;
  double deadline = oaa_now_seconds();

  while (oaa_atomic_load_acquire(&engine->should_run)) {
    /* Reset is requested from the owner's thread but performed here, at a
     * block boundary. Clearing the integrators from under a running analysis
     * pass would be a plain data race, and the symptom — one impossible
     * reading immediately after a reset — is exactly the kind of thing that
     * gets dismissed as a display glitch and never fixed. */
    if (oaa_atomic_load_acquire(&engine->reset_pending)) {
      oaa_clear_measurements(engine);
      oaa_atomic_store_release(&engine->reset_pending, 0);
    }

    if (engine->cfg.source == OAA_SOURCE_DEVICE) {
      /* The device sets the pace, so take whatever has arrived rather than
       * insisting on a full block. A partial block is not a problem: every
       * measurement counts its own windows in samples. */
      const uint32_t got =
          oaa_ring_read(&engine->ring, engine->block, engine->cfg.block_frames);
      if (got > 0) {
        oaa_analyse_gated(engine, engine->block, got);
      }

      const uint32_t dropped = oaa_ring_dropped(&engine->ring);
      engine->staging.dropped_frames = dropped;
      if (dropped > 0) {
        engine->staging.flags |= (uint32_t)OAA_FLAG_OVERRUN;
      }
    } else {
      oaa_source_render(engine, engine->cfg.block_frames);
      oaa_analyse_gated(engine, engine->block, engine->cfg.block_frames);
    }

    oaa_snapshot_publish(engine);

    deadline += block_seconds;
    const double now = oaa_now_seconds();

    if (deadline > now) {
      oaa_sleep_seconds(deadline - now);
    } else if (now - deadline > OAA_MAX_CATCHUP_SECONDS) {
      /* Too far behind to be worth making up — the machine slept, or the
       * process was stopped in a debugger. Drop the debt and carry on from
       * here, because replaying minutes of backlog as fast as the CPU allows
       * would spin without ever catching up. */
      deadline = now;
    }
    /* Otherwise keep the debt. The next iteration's sleep computes as
     * non-positive and returns immediately, so the loop makes the time up one
     * block at a time. That matters more than it looks: `oaa_sleep_seconds`
     * only guarantees *at least* the requested delay, and on a contended host
     * every block overshoots by a few milliseconds. Resetting the deadline on
     * each overshoot — which this loop used to do — discards that error
     * instead of absorbing it, and the engine then runs persistently slower
     * than real time. On an oversubscribed CI runner that came to a third of
     * real speed. */
  }

  oaa_atomic_store_release(&engine->thread_alive, 0);
  return NULL;
}

/* ------------------------------------------------------------------------ */
/* Public API                                                                */
/* ------------------------------------------------------------------------ */

int32_t oaa_abi_version(void) { return OAA_ABI_VERSION; }

const char *oaa_version_string(void) { return OAA_VERSION_STRING; }

void oaa_config_defaults(oaa_config *cfg) {
  if (cfg == NULL) {
    return;
  }
  cfg->sample_rate = OAA_DEFAULT_SAMPLE_RATE;
  cfg->channels = OAA_DEFAULT_CHANNELS;
  cfg->source = OAA_SOURCE_TEST_TONE;
  cfg->block_frames = OAA_DEFAULT_BLOCK_FRAMES;
}

oaa_engine *oaa_engine_create(const oaa_config *cfg) {
  oaa_config resolved;
  oaa_config_defaults(&resolved);
  if (cfg != NULL) {
    if (cfg->sample_rate != 0) {
      resolved.sample_rate = cfg->sample_rate;
    }
    if (cfg->channels != 0) {
      resolved.channels = cfg->channels;
    }
    if (cfg->block_frames != 0) {
      resolved.block_frames = cfg->block_frames;
    }
    resolved.source = cfg->source;
  }

  if (resolved.channels > OAA_MAX_CHANNELS || resolved.sample_rate < 8000u) {
    return NULL;
  }
  /* OAA_SOURCE_FILE is declared in the ABI and deliberately not accepted: a
   * file is decoded by the caller and pushed, so that offline analysis runs the
   * same `oaa_analyse` over the same buffers as realtime rather than acquiring
   * a path of its own. See the enum in oaa.h.
   *
   * Failing loudly beats silently substituting the test tone and letting
   * somebody believe they are metering something they are not. */
  if (resolved.source != OAA_SOURCE_SILENCE &&
      resolved.source != OAA_SOURCE_TEST_TONE &&
      resolved.source != OAA_SOURCE_PUSH &&
      resolved.source != OAA_SOURCE_DEVICE) {
    return NULL;
  }

  oaa_engine *engine = (oaa_engine *)calloc(1, sizeof(oaa_engine));
  if (engine == NULL) {
    return NULL;
  }
  engine->cfg = resolved;

  /* Everything below fails through oaa_engine_destroy(), which is safe on a
   * half-built engine because every owned resource is reached through a field
   * that calloc left null or a flag it left clear.
   *
   * This is not tidiness. Once oaa_device_start() has returned, a real-time
   * callback is writing into `engine->ring` on a thread we do not own, and a
   * bare free(engine) hands that callback a dangling ring while the block it
   * points into is being handed to the next allocation. The failures below are
   * out-of-memory paths, so the next allocation is exactly what is under
   * pressure — the one moment the reuse is certain rather than unlikely. */

  /* A device is opened here, before anything is sized, because it is the
   * device that decides the format. The requested rate and channel count are
   * overwritten with what the hardware actually produces — resampling in front
   * of a measurement changes the measurement. */
  if (resolved.source == OAA_SOURCE_DEVICE) {
    uint32_t device_rate = 0;
    uint32_t device_channels = 0;

    /* Negotiate first. The ring's frame stride must match the device's channel
     * count exactly, and until the device is open nobody knows what that is —
     * sizing the ring for OAA_MAX_CHANNELS and letting a mono microphone write
     * into it reads eight floats per frame out of a one-float-per-frame
     * buffer. */
    if (oaa_device_open(&engine->device, cfg != NULL ? cfg->device_id : NULL,
                        &device_rate, &device_channels) != OAA_OK) {
      oaa_engine_destroy(engine);
      return NULL;
    }

    if (!oaa_ring_init(&engine->ring,
                       (uint32_t)(device_rate * OAA_RING_SECONDS),
                       device_channels)) {
      oaa_engine_destroy(engine);
      return NULL;
    }
    engine->ring_ready = 1;

    if (oaa_device_start(engine->device, &engine->ring) != OAA_OK) {
      oaa_engine_destroy(engine);
      return NULL;
    }

    engine->cfg.sample_rate = device_rate;
    engine->cfg.channels = device_channels;
    resolved = engine->cfg;
  }

  engine->block = (float *)calloc(
      (size_t)resolved.block_frames * resolved.channels, sizeof(float));
  if (engine->block == NULL) {
    oaa_engine_destroy(engine);
    return NULL;
  }

  oaa_loudness_init(&engine->loudness, resolved.channels, resolved.sample_rate);
  oaa_truepeak_init(&engine->truepeak, resolved.channels, resolved.sample_rate);

  if (!oaa_spectrum_init(&engine->spectrum, resolved.channels,
                         resolved.sample_rate)) {
    oaa_engine_destroy(engine);
    return NULL;
  }

  oaa_clear_measurements(engine);

  /* Publish once before anybody starts, so a UI that paints before start()
   * shows floors rather than a zeroed struct that reads as 0.0 dBFS — which
   * would be full scale on every meter. */
  memcpy(&engine->shared, &engine->staging, sizeof(oaa_snapshot));
  memcpy(&engine->front, &engine->staging, sizeof(oaa_snapshot));

  return engine;
}

void oaa_engine_destroy(oaa_engine *engine) {
  if (engine == NULL) {
    return;
  }
  oaa_engine_stop(engine);

  /* The device first, always: it owns the thread that writes into the ring,
   * and freeing the ring under a live callback would be a use-after-free in
   * real-time context — the hardest kind of crash to reproduce. */
  oaa_device_close(engine->device);
  if (engine->ring_ready) {
    oaa_ring_free(&engine->ring);
  }

  oaa_spectrum_free(&engine->spectrum);
  free(engine->block);
  free(engine);
}

int32_t oaa_engine_start(oaa_engine *engine) {
  if (engine == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  if (oaa_atomic_load_acquire(&engine->thread_alive)) {
    return OAA_ERR_WRONG_STATE;
  }

  if (engine->cfg.source == OAA_SOURCE_PUSH) {
    /* Nothing to start. A pushed source has no clock of its own — the caller
     * is the clock — so spawning a thread here would produce an engine that
     * measured silence in between the caller's pushes. */
    engine->staging.flags |= (uint32_t)OAA_FLAG_RUNNING;
    oaa_snapshot_publish(engine);
    return OAA_OK;
  }

  oaa_atomic_store_release(&engine->should_run, 1);
  oaa_atomic_store_release(&engine->thread_alive, 1);

  const int status =
      oaa_thread_start(&engine->thread, oaa_analysis_thread, engine);
  if (status != OAA_OK) {
    oaa_atomic_store_release(&engine->should_run, 0);
    oaa_atomic_store_release(&engine->thread_alive, 0);
    return status;
  }
  engine->thread_started = 1;
  return OAA_OK;
}

int32_t oaa_engine_stop(oaa_engine *engine) {
  if (engine == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  /* The only safe predicate for *joining*: is there a thread we started and
   * have not joined. See the field's note in oaa_internal.h for why neither of
   * the two atomic flags can answer that.
   *
   * It is not the predicate for the whole function, which it used to be. A
   * pushed source never starts a thread, so an early return here left
   * OAA_FLAG_RUNNING set by start() and a stopped engine reporting itself
   * running for the rest of its life. */
  if (engine->thread_started) {
    oaa_atomic_store_release(&engine->should_run, 0);
    oaa_thread_join(engine->thread);
    engine->thread_started = 0;
  }

  engine->staging.flags &= ~(uint32_t)OAA_FLAG_RUNNING;
  oaa_snapshot_publish(engine);
  return OAA_OK;
}

int32_t oaa_engine_push(oaa_engine *engine, const float *interleaved,
                        uint32_t frames) {
  if (engine == NULL || interleaved == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  if (engine->cfg.source != OAA_SOURCE_PUSH) {
    return OAA_ERR_WRONG_STATE;
  }
  if (frames == 0) {
    return OAA_OK;
  }

  if (oaa_atomic_load_acquire(&engine->reset_pending)) {
    oaa_clear_measurements(engine);
    oaa_atomic_store_release(&engine->reset_pending, 0);
  }

  oaa_analyse_gated(engine, interleaved, frames);
  engine->staging.flags |= (uint32_t)OAA_FLAG_RUNNING;
  oaa_snapshot_publish(engine);
  return OAA_OK;
}

void oaa_engine_reset(oaa_engine *engine) {
  if (engine == NULL) {
    return;
  }
  if (oaa_atomic_load_acquire(&engine->thread_alive)) {
    oaa_atomic_store_release(&engine->reset_pending, 1);
    return;
  }
  /* Not running: nobody else touches the state, so do it here rather than
   * leaving a request pending that only a later start() would honour. */
  oaa_clear_measurements(engine);
  oaa_snapshot_publish(engine);
}
