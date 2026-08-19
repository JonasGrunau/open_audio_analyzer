/*
 * oaa_ring.h — the single-producer, single-consumer ring between the audio
 * callback and the analysis thread.
 *
 * SPDX-License-Identifier: MIT
 *
 * This is the one piece of the engine that a real-time audio callback touches,
 * so it is the one piece with a hard constraint: **the producer must never
 * block, allocate, take a lock, or make a syscall.** A capture callback that
 * misses its deadline does not slow anything down — it drops a buffer of audio
 * outright, and that audio is gone.
 *
 * Which is why the interesting design decision here is not the ring at all, it
 * is what happens when the ring is full.
 *
 * ---------------------------------------------------------------------------
 * Overruns are counted, and the count is published
 *
 * The obvious thing to do when the consumer has fallen behind is to overwrite
 * the oldest data and carry on. For a *display* that is right; for a
 * *measurement* it is a quiet lie. Integrated loudness is an average over every
 * block since the reset, so dropping a second of audio does not make the
 * reading slightly stale — it makes it an average of a different programme than
 * the one that played, and nothing on screen would say so.
 *
 * So this ring drops, and counts what it dropped, and the engine surfaces that
 * count in the snapshot. A user who sees a non-zero overrun figure knows their
 * integrated reading is not trustworthy. A user who never sees the figure would
 * simply have been given a wrong number.
 */

#ifndef OAA_RING_H
#define OAA_RING_H

#include "oaa_atomic.h"

#include <stdint.h>

typedef struct {
  float *data;

  /* In frames, and always a power of two so the index wrap is a mask rather
   * than a modulo — a division on the audio thread is not expensive enough to
   * matter, but it is not free either, and there is no reason to pay it. */
  uint32_t capacity;
  uint32_t mask;
  uint32_t channels;

  /* Monotonically increasing frame counters, masked on use. Keeping them
   * unwrapped is what makes "full" and "empty" distinguishable without wasting
   * a slot: the difference is the fill level, and it is exact until the
   * counters themselves wrap at 2^32 frames — 24 hours at 48 kHz, and a wrap
   * is harmless anyway because only the difference is ever read. */
  oaa_atomic_u32 write_index;
  oaa_atomic_u32 read_index;

  /* Frames the producer had to discard because the consumer was behind.
   * Written by the producer, read by anyone. See the header comment: this is
   * not diagnostics, it is a correctness signal. */
  oaa_atomic_u32 dropped;
} oaa_ring;

/*
 * `capacity_frames` is rounded up to a power of two. Returns 0 on allocation
 * failure.
 *
 * Size it generously. The consumer runs at roughly the display rate and the
 * producer at whatever the device chose, so a few hundred milliseconds of slack
 * costs a trivial amount of memory and absorbs every ordinary scheduling
 * hiccup. Sizing it tightly buys nothing and turns a hiccup into lost audio.
 */
int oaa_ring_init(oaa_ring *ring, uint32_t capacity_frames, uint32_t channels);
void oaa_ring_free(oaa_ring *ring);

/* Discards the contents without disturbing the drop counter's meaning: a reset
 * clears it too, because the count describes the current measurement. */
void oaa_ring_clear(oaa_ring *ring);

/*
 * Producer side. Real-time safe. Returns the number of frames actually
 * written; anything short of `frames` has been dropped and counted.
 */
uint32_t oaa_ring_write(oaa_ring *ring, const float *interleaved,
                        uint32_t frames);

/* Consumer side. Returns the number of frames actually read. */
uint32_t oaa_ring_read(oaa_ring *ring, float *interleaved, uint32_t frames);

/* Frames currently readable. */
uint32_t oaa_ring_available(const oaa_ring *ring);

/* Frames dropped since the last clear. */
uint32_t oaa_ring_dropped(const oaa_ring *ring);

/*
 * Zeroes the drop counter alone, leaving the data indices untouched.
 *
 * This is the one thing that *is* safe to do while the producer is running.
 * `oaa_ring_clear` is not — it moves both indices and would race the callback
 * — but the drop count is add-only, so the worst a concurrent reset can do is
 * lose a single increment, and the next dropped frame restores the signal.
 * That matters because a user pressing Reset must be able to clear a stale
 * overrun warning without stopping the device.
 */
void oaa_ring_clear_dropped(oaa_ring *ring);

#endif /* OAA_RING_H */
