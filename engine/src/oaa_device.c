/*
 * oaa_device.c — miniaudio, wrapped down to the two things Open Audio Analyzer
 * needs.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/*
 * Only the device layer is compiled in. miniaudio is a complete audio engine —
 * decoding, resampling, a node graph, spatialisation — and none of it is
 * wanted here. Switching the rest off is not just about the roughly 4 MB of
 * header: MA_NO_DECODING in particular guarantees that no format conversion can
 * creep into the capture path, which is the property this file exists to
 * protect. Open Audio Analyzer measures what the hardware produced.
 */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "oaa_device.h"
#include "oaa_tap.h"

#include <stdlib.h>
#include <string.h>

struct oaa_device {
  /* Non-NULL for the one device that is not miniaudio's: the macOS process
   * tap. When it is set, every entry point below delegates and none of the
   * miniaudio fields are touched. Keeping the two behind one handle is what
   * lets oaa_engine.c stay ignorant of which it opened — it negotiates a
   * format, sizes a ring and starts, and the tap answers that sequence the
   * same way a sound card does. */
  oaa_tap *tap;

  ma_context context;
  ma_device device;
  int context_ready;
  int device_ready;
  oaa_ring *ring;

  /* Set from miniaudio's notification callback when the backend stops the
   * device behind our back, cleared when it starts one.
   *
   * `ma_device_get_state` is asked first and this is asked second, because the
   * two do not always agree: the state field describes what the *API* was last
   * told to do, and a backend that lost its device — an interface unplugged, a
   * route change the backend could not follow — reports the stop through the
   * notification while the state still reads `started`. Believing only the
   * state is how a dead device goes on looking healthy forever. */
  oaa_atomic_u32 stopped;
};

struct oaa_device_list {
  uint32_t count;
  oaa_device_info *items;
};

/* ------------------------------------------------------------------------ */
/* The capture callback                                                      */
/* ------------------------------------------------------------------------ */

/*
 * Real-time context. Everything this touches is lock-free and pre-allocated:
 * one bounds check and up to two memcpys. No malloc, no logging, no atomics
 * beyond the ring's two indices.
 *
 * It also, deliberately, does nothing about a full ring. `oaa_ring_write`
 * counts what it could not take and the engine publishes that count, because
 * quietly overwriting would leave the integrated loudness averaging over audio
 * that never reached it.
 */
static void oaa_device_callback(ma_device *device, void *output,
                                const void *input, ma_uint32 frame_count) {
  (void)output; /* capture only */

  oaa_device *self = (oaa_device *)device->pUserData;
  if (self == NULL || input == NULL || self->ring == NULL) {
    /* The ring is attached by oaa_device_start. A callback firing before that
     * would mean the driver started the device behind our back; dropping the
     * buffer is the only safe response, and it cannot happen in the intended
     * sequence. */
    return;
  }
  oaa_ring_write(self->ring, (const float *)input, (uint32_t)frame_count);
}

/*
 * Not a real-time context, but treated as one: this is called from whichever
 * thread the backend felt like, including its audio thread, so it does one
 * atomic store and nothing else. Everything that has to be decided about a
 * stopped device is decided by the analysis thread in oaa_device_revive.
 */
static void oaa_device_notification(const ma_device_notification *notification) {
  if (notification == NULL || notification->pDevice == NULL) {
    return;
  }
  oaa_device *self = (oaa_device *)notification->pDevice->pUserData;
  if (self == NULL) {
    return;
  }

  switch (notification->type) {
    case ma_device_notification_type_stopped:
      oaa_atomic_store_release(&self->stopped, 1);
      break;
    case ma_device_notification_type_started:
      oaa_atomic_store_release(&self->stopped, 0);
      break;
    default:
      /* `rerouted` is deliberately not a stop: miniaudio has already moved the
       * device to the new default and is delivering again. It arrives on the
       * one path where the format cannot have changed under us — we asked for
       * the device's own rate and channel count, so a reroute that produced a
       * different format would have failed inside miniaudio instead. */
      break;
  }
}

/* ------------------------------------------------------------------------ */
/* Enumeration                                                               */
/* ------------------------------------------------------------------------ */

static void copy_bounded(char *destination, size_t capacity,
                         const char *source) {
  if (source == NULL) {
    destination[0] = '\0';
    return;
  }
  size_t length = strlen(source);
  if (length >= capacity) {
    length = capacity - 1;
  }
  memcpy(destination, source, length);
  destination[length] = '\0';
}

/*
 * Adds the system-output entry, where there is one to add.
 *
 * It goes at the *front* of the list rather than in backend order, because it
 * is the entry most people opening the source menu are looking for and every
 * other entry is a piece of hardware whose position in the list is arbitrary
 * anyway.
 *
 * Returns the number of entries written: one, or zero on any platform or any
 * macOS below 14.2, which is an ordinary state and not a failure — the menu
 * then looks exactly as it did before this existed.
 */
static uint32_t add_system_output(oaa_device_info *out) {
#if OAA_TAP_SUPPORTED
  uint32_t rate = 0;
  uint32_t channels = 0;
  if (oaa_tap_probe(&rate, &channels, out->name, OAA_DEVICE_NAME_MAX) !=
      OAA_OK) {
    return 0;
  }
  copy_bounded(out->id, OAA_DEVICE_ID_MAX, OAA_DEVICE_ID_SYSTEM_OUTPUT);
  out->channels = channels;
  out->sample_rate = rate;
  /* Never the default *capture* device — that is a property of the hardware
   * list and belongs to whatever the system nominated. */
  out->is_default = 0u;
  out->is_loopback = 1u;
  return 1;
#else
  (void)out;
  return 0;
#endif
}

oaa_device_list *oaa_devices_enumerate(void) {
  ma_context context;
  if (ma_context_init(NULL, 0, NULL, &context) != MA_SUCCESS) {
    /* Normal on a headless machine with no audio backend at all. A metering
     * app with no devices to offer is a usable state; a crash is not. */
    return NULL;
  }

  ma_device_info *capture_infos = NULL;
  ma_uint32 capture_count = 0;
  if (ma_context_get_devices(&context, NULL, NULL, &capture_infos,
                             &capture_count) != MA_SUCCESS) {
    ma_context_uninit(&context);
    return NULL;
  }

  oaa_device_list *list = (oaa_device_list *)calloc(1, sizeof(oaa_device_list));
  if (list == NULL) {
    ma_context_uninit(&context);
    return NULL;
  }

  /* One more than the backend offered, for the system-output entry. Allocated
   * unconditionally — a machine with no capture hardware at all can still have
   * an output to tap, and that is a perfectly ordinary laptop. */
  list->items =
      (oaa_device_info *)calloc(capture_count + 1, sizeof(oaa_device_info));
  if (list->items == NULL) {
    free(list);
    ma_context_uninit(&context);
    return NULL;
  }

  list->count += add_system_output(&list->items[list->count]);

  for (ma_uint32 i = 0; i < capture_count; i++) {
    ma_device_info detail;
    oaa_device_info *out = &list->items[list->count];

    copy_bounded(out->name, OAA_DEVICE_NAME_MAX, capture_infos[i].name);
    out->is_default = capture_infos[i].isDefault ? 1u : 0u;

    /* The id is an opaque platform union. Storing its bytes as hex keeps it
     * printable, comparable and safe to put in a preset, without this file
     * having to know what any backend's id actually contains.
     *
     * The byte count is derived from the space available rather than the other
     * way round, and the two hex digits of a byte are always written together.
     * The previous form clamped the *digit* count to OAA_DEVICE_ID_MAX - 1,
     * which is odd, so it wrote an odd number of digits, left the last one
     * unwritten and terminated one byte past where the digits stopped — it only
     * produced a valid string because the list was calloc'd. It also halved the
     * id: 127 of miniaudio's 256 bytes. That round-trips today because the tail
     * a real backend leaves is zeros, which is luck rather than a design, and
     * an id long enough to reach the cut would fail to reopen its device with
     * nothing anywhere saying why.
     *
     * Trailing zero bytes are dropped before encoding, which is what keeps
     * every id a real backend produces well inside the field. `ma_device_id` is
     * a 256-byte union and almost every member is far smaller than that — a
     * NUL-terminated ALSA, PulseAudio or Core Audio name, a 4-byte integer, a
     * UTF-16 WASAPI path — so what is significant is tens of bytes, not 256.
     * `parse_device_id` zeroes the union before filling it, so dropping the
     * zeros and restoring them is exact. The residual bound is 127 significant
     * bytes; reaching it needs a device name of over 127 characters, and
     * raising OAA_DEVICE_ID_MAX past it is an ABI bump that would make every
     * consumer recompile for a case no backend has yet produced. */
    const unsigned char *raw = (const unsigned char *)&capture_infos[i].id;
    size_t raw_size = sizeof(capture_infos[i].id);
    while (raw_size > 0 && raw[raw_size - 1] == 0) {
      raw_size--;
    }
    const size_t room_bytes = (OAA_DEVICE_ID_MAX - 1) / 2;
    const size_t bytes = raw_size < room_bytes ? raw_size : room_bytes;
    static const char kHex[] = "0123456789abcdef";
    for (size_t b = 0; b < bytes; b++) {
      out->id[b * 2] = kHex[(raw[b] >> 4) & 0xF];
      out->id[b * 2 + 1] = kHex[raw[b] & 0xF];
    }
    out->id[bytes * 2] = '\0';

    /* Native format, where the backend will tell us. Best effort: several
     * backends only report it after the device is opened, and reporting zero
     * is more honest than reporting a guess. */
    if (ma_context_get_device_info(&context, ma_device_type_capture,
                                   &capture_infos[i].id,
                                   &detail) == MA_SUCCESS &&
        detail.nativeDataFormatCount > 0) {
      out->channels = detail.nativeDataFormats[0].channels;
      out->sample_rate = detail.nativeDataFormats[0].sampleRate;
    }

    list->count++;
  }

  ma_context_uninit(&context);
  return list;
}

uint32_t oaa_device_list_count(const oaa_device_list *list) {
  return list == NULL ? 0 : list->count;
}

const oaa_device_info *oaa_device_list_at(const oaa_device_list *list,
                                          uint32_t index) {
  if (list == NULL || index >= list->count) {
    return NULL;
  }
  return &list->items[index];
}

void oaa_device_list_free(oaa_device_list *list) {
  if (list == NULL) {
    return;
  }
  free(list->items);
  free(list);
}

/* ------------------------------------------------------------------------ */
/* Opening                                                                   */
/* ------------------------------------------------------------------------ */

/* Turns the hex form back into the backend's own id bytes. */
static int parse_device_id(const char *hex, ma_device_id *out) {
  memset(out, 0, sizeof(*out));
  const size_t length = strlen(hex);
  if (length == 0 || (length % 2) != 0 || length / 2 > sizeof(*out)) {
    return 0;
  }

  unsigned char *bytes = (unsigned char *)out;
  for (size_t i = 0; i < length / 2; i++) {
    int high = -1, low = -1;
    for (int k = 0; k < 16; k++) {
      const char digit = "0123456789abcdef"[k];
      if (hex[i * 2] == digit) high = k;
      if (hex[i * 2 + 1] == digit) low = k;
    }
    if (high < 0 || low < 0) {
      return 0;
    }
    bytes[i] = (unsigned char)((high << 4) | low);
  }
  return 1;
}

int32_t oaa_device_open(oaa_device **out, const char *device_id,
                        uint32_t *sample_rate, uint32_t *channels) {
  if (out == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  *out = NULL;

  oaa_device *self = (oaa_device *)calloc(1, sizeof(oaa_device));
  if (self == NULL) {
    return OAA_ERR_OUT_OF_MEMORY;
  }

  /* The one id that is not a backend's. Delegated before miniaudio is even
   * initialised, because a process tap is not a miniaudio device and never
   * becomes one. */
  if (device_id != NULL &&
      strcmp(device_id, OAA_DEVICE_ID_SYSTEM_OUTPUT) == 0) {
#if OAA_TAP_SUPPORTED
    const int32_t status =
        oaa_tap_open(&self->tap, sample_rate, channels);
    if (status != OAA_OK) {
      free(self);
      return status;
    }
    *out = self;
    return OAA_OK;
#else
    /* Asked for by a preset written on a Mac and opened on Windows or Linux.
     * Refused rather than silently falling back to the default input, which
     * would meter a microphone while the user believed they were metering
     * their output. */
    free(self);
    return OAA_ERR_UNSUPPORTED;
#endif
  }

  if (ma_context_init(NULL, 0, NULL, &self->context) != MA_SUCCESS) {
    free(self);
    return OAA_ERR_UNSUPPORTED;
  }
  self->context_ready = 1;

  ma_device_id parsed;
  const int have_id = device_id != NULL && parse_device_id(device_id, &parsed);

  ma_device_config config = ma_device_config_init(ma_device_type_capture);
  config.capture.pDeviceID = have_id ? &parsed : NULL;
  config.capture.format = ma_format_f32;

  /* Zero means "whatever the device wants". Naming a rate or a channel count
   * here is what would insert miniaudio's converter into the measurement path;
   * see this file's header. */
  config.capture.channels = 0;
  config.sampleRate = 0;

  config.dataCallback = oaa_device_callback;
  config.notificationCallback = oaa_device_notification;
  config.pUserData = self;

  if (ma_device_init(&self->context, &config, &self->device) != MA_SUCCESS) {
    ma_context_uninit(&self->context);
    free(self);
    return OAA_ERR_UNSUPPORTED;
  }
  self->device_ready = 1;

  const uint32_t actual_channels = self->device.capture.channels;
  const uint32_t actual_rate = self->device.sampleRate;

  if (actual_channels == 0 || actual_channels > OAA_MAX_CHANNELS) {
    /* Open Audio Analyzer's graph carries at most 7.1. A wider interface — and 16- or 32-input
     * interfaces are ordinary in a studio — is refused rather than silently
     * measuring the first eight channels and calling the result the programme
     * loudness. */
    oaa_device_close(self);
    return OAA_ERR_UNSUPPORTED;
  }

  /* Deliberately not started here — see the header. */
  if (sample_rate != NULL) *sample_rate = actual_rate;
  if (channels != NULL) *channels = actual_channels;

  *out = self;
  return OAA_OK;
}

int32_t oaa_device_start(oaa_device *device, oaa_ring *ring) {
  if (device == NULL || ring == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
#if OAA_TAP_SUPPORTED
  if (device->tap != NULL) {
    return oaa_tap_start(device->tap, ring);
  }
#endif
  if (ring->channels != device->device.capture.channels) {
    /* The mismatch this split exists to prevent. Refusing is the only safe
     * response: the callback would read past the end of the buffer the driver
     * handed it. */
    return OAA_ERR_INVALID_ARGUMENT;
  }

  /* Published before the callback can run, so the first callback sees it. */
  device->ring = ring;

  return ma_device_start(&device->device) == MA_SUCCESS ? OAA_OK
                                                        : OAA_ERR_THREAD;
}

int32_t oaa_device_running(oaa_device *device) {
  if (device == NULL) {
    return 0;
  }
#if OAA_TAP_SUPPORTED
  if (device->tap != NULL) {
    return oaa_tap_running(device->tap);
  }
#endif
  if (!device->device_ready || device->ring == NULL) {
    /* Not started yet. Never "stopped": the engine polls this from the moment
     * the analysis thread begins, and a device that has not been handed its
     * ring is one the caller has not finished opening. */
    return 1;
  }
  if (oaa_atomic_load_acquire(&device->stopped)) {
    return 0;
  }
  return ma_device_get_state(&device->device) == ma_device_state_started ? 1 : 0;
}

int32_t oaa_device_revive(oaa_device *device) {
  if (device == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
#if OAA_TAP_SUPPORTED
  if (device->tap != NULL) {
    return oaa_tap_revive(device->tap);
  }
#endif
  if (!device->device_ready || device->ring == NULL) {
    return OAA_ERR_WRONG_STATE;
  }

  /* `ma_device_start` alone, with no stop in front of it. A device the backend
   * has already stopped is in exactly the state start() expects, and a stop()
   * on top of it blocks until the backend's own thread has finished unwinding
   * — on the analysis thread, which is the thread that has to keep publishing.
   * If the state is transitional, start() refuses and the next poll tries
   * again a second later, which is the same outcome for free. */
  if (ma_device_start(&device->device) != MA_SUCCESS) {
    return OAA_ERR_THREAD;
  }
  /* The notification does this too, on the backend's own thread and in its own
   * time. Doing it here as well is what makes a successful revive visible to
   * the very next poll rather than to whichever one happens to follow the
   * callback. */
  oaa_atomic_store_release(&device->stopped, 0);
  return OAA_OK;
}

void oaa_device_close(oaa_device *device) {
  if (device == NULL) {
    return;
  }
#if OAA_TAP_SUPPORTED
  if (device->tap != NULL) {
    oaa_tap_close(device->tap);
    free(device);
    return;
  }
#endif
  if (device->device_ready) {
    ma_device_uninit(&device->device);
  }
  if (device->context_ready) {
    ma_context_uninit(&device->context);
  }
  free(device);
}
