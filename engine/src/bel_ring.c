/*
 * bel_ring.c — the SPSC ring between the audio callback and the analysis.
 *
 * SPDX-License-Identifier: MIT
 */

#include "bel_ring.h"

#include <stdlib.h>
#include <string.h>

static uint32_t round_up_power_of_two(uint32_t value) {
  if (value < 2) {
    return 2;
  }
  value--;
  value |= value >> 1;
  value |= value >> 2;
  value |= value >> 4;
  value |= value >> 8;
  value |= value >> 16;
  return value + 1;
}

int bel_ring_init(bel_ring *ring, uint32_t capacity_frames, uint32_t channels) {
  memset(ring, 0, sizeof(*ring));

  const uint32_t capacity = round_up_power_of_two(capacity_frames);
  ring->data = (float *)calloc((size_t)capacity * channels, sizeof(float));
  if (ring->data == NULL) {
    return 0;
  }

  ring->capacity = capacity;
  ring->mask = capacity - 1;
  ring->channels = channels;
  return 1;
}

void bel_ring_free(bel_ring *ring) {
  free(ring->data);
  ring->data = NULL;
  ring->capacity = 0;
}

void bel_ring_clear(bel_ring *ring) {
  /* Only safe with the producer stopped, which is the only time it is called —
   * a device is opened or closed around it. Doing this while a callback was
   * running would race with the producer's own index. */
  bel_atomic_store_release(&ring->read_index, 0);
  bel_atomic_store_release(&ring->write_index, 0);
  bel_atomic_store_release(&ring->dropped, 0);
}

uint32_t bel_ring_available(const bel_ring *ring) {
  const uint32_t write = bel_atomic_load_acquire(&ring->write_index);
  const uint32_t read = bel_atomic_load_acquire(&ring->read_index);
  /* Unsigned subtraction, so a counter wrap is harmless: only the difference
   * is ever meaningful, and it stays correct across the wrap. */
  return write - read;
}

uint32_t bel_ring_dropped(const bel_ring *ring) {
  return bel_atomic_load_acquire(&ring->dropped);
}

void bel_ring_clear_dropped(bel_ring *ring) {
  bel_atomic_store_release(&ring->dropped, 0);
}

uint32_t bel_ring_write(bel_ring *ring, const float *interleaved,
                        uint32_t frames) {
  const uint32_t channels = ring->channels;
  const uint32_t write = bel_atomic_load_acquire(&ring->write_index);
  const uint32_t read = bel_atomic_load_acquire(&ring->read_index);
  const uint32_t free_frames = ring->capacity - (write - read);

  const uint32_t writable = frames < free_frames ? frames : free_frames;

  if (writable < frames) {
    /* The consumer is behind and this audio is gone. Counting it is the whole
     * reason this function does not simply overwrite: a measurement taken over
     * audio that was silently discarded is wrong, and the only honest response
     * is to make the loss visible. See the header. */
    bel_atomic_add(&ring->dropped, frames - writable);
  }

  /* Up to two memcpys: one to the end of the buffer, one from the start. No
   * branch per frame, no modulo per sample. */
  const uint32_t start = write & ring->mask;
  const uint32_t first = (ring->capacity - start) < writable
                             ? (ring->capacity - start)
                             : writable;

  memcpy(&ring->data[(size_t)start * channels], interleaved,
         (size_t)first * channels * sizeof(float));

  if (writable > first) {
    memcpy(ring->data, &interleaved[(size_t)first * channels],
           (size_t)(writable - first) * channels * sizeof(float));
  }

  /* Release: everything written above is visible to the consumer before it can
   * observe the new index. */
  bel_atomic_store_release(&ring->write_index, write + writable);
  return writable;
}

uint32_t bel_ring_read(bel_ring *ring, float *interleaved, uint32_t frames) {
  const uint32_t channels = ring->channels;
  const uint32_t write = bel_atomic_load_acquire(&ring->write_index);
  const uint32_t read = bel_atomic_load_acquire(&ring->read_index);
  const uint32_t available = write - read;

  const uint32_t readable = frames < available ? frames : available;
  if (readable == 0) {
    return 0;
  }

  const uint32_t start = read & ring->mask;
  const uint32_t first = (ring->capacity - start) < readable
                             ? (ring->capacity - start)
                             : readable;

  memcpy(interleaved, &ring->data[(size_t)start * channels],
         (size_t)first * channels * sizeof(float));

  if (readable > first) {
    memcpy(&interleaved[(size_t)first * channels], ring->data,
           (size_t)(readable - first) * channels * sizeof(float));
  }

  bel_atomic_store_release(&ring->read_index, read + readable);
  return readable;
}
