/*
 * bel_device.c — miniaudio, wrapped down to the two things Bel needs.
 *
 * SPDX-License-Identifier: MIT
 */

/*
 * Only the device layer is compiled in. miniaudio is a complete audio engine —
 * decoding, resampling, a node graph, spatialisation — and none of it is
 * wanted here. Switching the rest off is not just about the roughly 4 MB of
 * header: MA_NO_DECODING in particular guarantees that no format conversion can
 * creep into the capture path, which is the property this file exists to
 * protect. Bel measures what the hardware produced.
 */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "bel_device.h"

#include <stdlib.h>
#include <string.h>

struct bel_device {
  ma_context context;
  ma_device device;
  int context_ready;
  int device_ready;
  bel_ring *ring;
};

struct bel_device_list {
  uint32_t count;
  bel_device_info *items;
};

/* ------------------------------------------------------------------------ */
/* The capture callback                                                      */
/* ------------------------------------------------------------------------ */

/*
 * Real-time context. Everything this touches is lock-free and pre-allocated:
 * one bounds check and up to two memcpys. No malloc, no logging, no atomics
 * beyond the ring's two indices.
 *
 * It also, deliberately, does nothing about a full ring. `bel_ring_write`
 * counts what it could not take and the engine publishes that count, because
 * quietly overwriting would leave the integrated loudness averaging over audio
 * that never reached it.
 */
static void bel_device_callback(ma_device *device, void *output,
                                const void *input, ma_uint32 frame_count) {
  (void)output; /* capture only */

  bel_device *self = (bel_device *)device->pUserData;
  if (self == NULL || input == NULL || self->ring == NULL) {
    /* The ring is attached by bel_device_start. A callback firing before that
     * would mean the driver started the device behind our back; dropping the
     * buffer is the only safe response, and it cannot happen in the intended
     * sequence. */
    return;
  }
  bel_ring_write(self->ring, (const float *)input, (uint32_t)frame_count);
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

bel_device_list *bel_devices_enumerate(void) {
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

  bel_device_list *list = (bel_device_list *)calloc(1, sizeof(bel_device_list));
  if (list == NULL) {
    ma_context_uninit(&context);
    return NULL;
  }

  if (capture_count > 0) {
    list->items =
        (bel_device_info *)calloc(capture_count, sizeof(bel_device_info));
    if (list->items == NULL) {
      free(list);
      ma_context_uninit(&context);
      return NULL;
    }
  }

  for (ma_uint32 i = 0; i < capture_count; i++) {
    ma_device_info detail;
    bel_device_info *out = &list->items[list->count];

    copy_bounded(out->name, BEL_DEVICE_NAME_MAX, capture_infos[i].name);
    out->is_default = capture_infos[i].isDefault ? 1u : 0u;

    /* The id is an opaque platform union. Storing its bytes as hex keeps it
     * printable, comparable and safe to put in a preset, without this file
     * having to know what any backend's id actually contains. */
    const unsigned char *raw = (const unsigned char *)&capture_infos[i].id;
    const size_t raw_size = sizeof(capture_infos[i].id);
    const size_t hex_size = raw_size * 2 < (BEL_DEVICE_ID_MAX - 1)
                                ? raw_size * 2
                                : (BEL_DEVICE_ID_MAX - 1);
    static const char kHex[] = "0123456789abcdef";
    for (size_t b = 0; b * 2 + 1 < hex_size; b++) {
      out->id[b * 2] = kHex[(raw[b] >> 4) & 0xF];
      out->id[b * 2 + 1] = kHex[raw[b] & 0xF];
    }
    out->id[hex_size] = '\0';

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

uint32_t bel_device_list_count(const bel_device_list *list) {
  return list == NULL ? 0 : list->count;
}

const bel_device_info *bel_device_list_at(const bel_device_list *list,
                                          uint32_t index) {
  if (list == NULL || index >= list->count) {
    return NULL;
  }
  return &list->items[index];
}

void bel_device_list_free(bel_device_list *list) {
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

int32_t bel_device_open(bel_device **out, const char *device_id,
                        uint32_t *sample_rate, uint32_t *channels) {
  if (out == NULL) {
    return BEL_ERR_INVALID_ARGUMENT;
  }
  *out = NULL;

  bel_device *self = (bel_device *)calloc(1, sizeof(bel_device));
  if (self == NULL) {
    return BEL_ERR_OUT_OF_MEMORY;
  }

  if (ma_context_init(NULL, 0, NULL, &self->context) != MA_SUCCESS) {
    free(self);
    return BEL_ERR_UNSUPPORTED;
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

  config.dataCallback = bel_device_callback;
  config.pUserData = self;

  if (ma_device_init(&self->context, &config, &self->device) != MA_SUCCESS) {
    ma_context_uninit(&self->context);
    free(self);
    return BEL_ERR_UNSUPPORTED;
  }
  self->device_ready = 1;

  const uint32_t actual_channels = self->device.capture.channels;
  const uint32_t actual_rate = self->device.sampleRate;

  if (actual_channels == 0 || actual_channels > BEL_MAX_CHANNELS) {
    /* Bel's graph carries at most 7.1. A wider interface — and 16- or 32-input
     * interfaces are ordinary in a studio — is refused rather than silently
     * measuring the first eight channels and calling the result the programme
     * loudness. */
    bel_device_close(self);
    return BEL_ERR_UNSUPPORTED;
  }

  /* Deliberately not started here — see the header. */
  if (sample_rate != NULL) *sample_rate = actual_rate;
  if (channels != NULL) *channels = actual_channels;

  *out = self;
  return BEL_OK;
}

int32_t bel_device_start(bel_device *device, bel_ring *ring) {
  if (device == NULL || ring == NULL) {
    return BEL_ERR_INVALID_ARGUMENT;
  }
  if (ring->channels != device->device.capture.channels) {
    /* The mismatch this split exists to prevent. Refusing is the only safe
     * response: the callback would read past the end of the buffer the driver
     * handed it. */
    return BEL_ERR_INVALID_ARGUMENT;
  }

  /* Published before the callback can run, so the first callback sees it. */
  device->ring = ring;

  return ma_device_start(&device->device) == MA_SUCCESS ? BEL_OK
                                                        : BEL_ERR_THREAD;
}

void bel_device_close(bel_device *device) {
  if (device == NULL) {
    return;
  }
  if (device->device_ready) {
    ma_device_uninit(&device->device);
  }
  if (device->context_ready) {
    ma_context_uninit(&device->context);
  }
  free(device);
}
