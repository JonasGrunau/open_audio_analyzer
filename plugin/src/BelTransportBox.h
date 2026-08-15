/*
 * BelTransportBox.h — one transport reading, handed from the audio thread to
 * the streaming thread without a lock.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why this is a seqlock and not something simpler
 *
 * `wire::Transport` is 88 bytes, which is far too wide for a `std::atomic` to
 * carry losslessly — `atomic<Transport>` compiles, and then silently degrades
 * to a mutex on every platform, which is exactly what a `processBlock` must
 * never touch. A mutex on the audio thread does not usually fail; it fails
 * occasionally, under load, as a click, which is the worst way for a bug to
 * behave.
 *
 * The alternative would be to publish the fields as separate atomics. That is
 * lock-free and it is wrong: the reader would be able to observe the bar
 * position from one block and the tempo from the next, and display a bar
 * number that never existed. Transport values are only meaningful together.
 *
 * So: a seqlock, which is the same technique `bel_snapshot` uses for the same
 * reason, and the symmetry is deliberate — there is one way this codebase moves
 * a wide struct between threads.
 *
 * The asymmetry that makes it the right choice here: the writer is the thread
 * with the hard deadline and it never waits, never retries and never blocks.
 * All of the cost lands on the reader, which is a background thread that can
 * afford to try again. When the reader loses the race it simply keeps the
 * previous transport for one frame — at fifty frames a second, over values
 * that move continuously, that is not observable.
 */

#pragma once

#include <atomic>

#include "BelWire.h"

namespace bel {

class TransportBox {
public:
  /*
   * Audio thread. Real-time safe: no allocation, no lock, no syscall, no
   * unbounded loop.
   *
   * The odd/even sequence is the whole mechanism. An odd value means "a write
   * is in progress, what you are reading may be half of two different
   * transports"; the reader sees that and retries rather than believing it.
   */
  void publish(const wire::Transport& t) noexcept {
    const uint32_t start = sequence_.load(std::memory_order_relaxed);
    sequence_.store(start + 1, std::memory_order_relaxed);

    /* Keeps the sequence increment from sinking below the payload write. The
     * fences are what make this correct rather than merely usually correct —
     * without them the compiler is entirely within its rights to reorder the
     * struct assignment across the counter, and the reader's whole validity
     * check becomes decorative. */
    std::atomic_thread_fence(std::memory_order_release);
    value_ = t;
    std::atomic_thread_fence(std::memory_order_release);

    sequence_.store(start + 2, std::memory_order_relaxed);
  }

  /*
   * Streaming thread. Returns false if the writer kept winning the race, in
   * which case `out` is untouched and the caller should keep what it had.
   *
   * Bounded retries rather than a spin-until-success loop: the audio thread
   * publishes once per block and this reads once per frame, so a collision is
   * already rare and two in a row is close to impossible. Looping forever to
   * chase the last of them would mean a stall on this thread is unbounded in
   * exactly the situation where the audio thread is already struggling.
   */
  bool read(wire::Transport& out) const noexcept {
    for (int attempt = 0; attempt < 4; ++attempt) {
      const uint32_t before = sequence_.load(std::memory_order_relaxed);
      if ((before & 1u) != 0u)
        continue;  // a write is in flight

      std::atomic_thread_fence(std::memory_order_acquire);
      const wire::Transport candidate = value_;
      std::atomic_thread_fence(std::memory_order_acquire);

      if (sequence_.load(std::memory_order_relaxed) == before) {
        out = candidate;
        return true;
      }
    }
    return false;
  }

  /* True once the host has given us a position at least once. Until then there
   * is nothing to show and the display must say so rather than render a
   * default-constructed transport parked at bar one. */
  bool hasEverPublished() const noexcept {
    return sequence_.load(std::memory_order_relaxed) != 0;
  }

private:
  std::atomic<uint32_t> sequence_{0};
  wire::Transport value_{};
};

}  // namespace bel
