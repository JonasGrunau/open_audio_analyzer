/*
 * OaaTransportBox.h — one transport reading, handed from the audio thread to
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
 * So: a seqlock, which is the same technique `oaa_snapshot` uses for the same
 * reason, and the symmetry is deliberate — there is one way this codebase moves
 * a wide struct between threads.
 *
 * The asymmetry that makes it the right choice here: the writer is the thread
 * with the hard deadline and it never waits, never retries and never blocks.
 * All of the cost lands on the reader, which is a background thread that can
 * afford to try again. When the reader loses the race it simply keeps the
 * previous transport for one frame — at fifty frames a second, over values
 * that move continuously, that is not observable.
 *
 * ---------------------------------------------------------------------------
 * Why one flag is not carried in the payload at all
 *
 * "Not observable" is true of a *position*, and false of an *edge*.
 *
 * The writer publishes once per audio block. The reader reads once per
 * published measurement, which is one push of the engine's block size — every
 * second block at a 512-frame host buffer, one in sixteen at 64. So a value
 * that is true for exactly one block is a value the reader will usually miss:
 * `kDiscontinuity` marks the single block where the playhead jumped, and a
 * measured run of three loop laps delivered it to the app zero times out of
 * 186 published frames.
 *
 * Losing it is not cosmetic. It is the whole point of the flag — an integrated
 * reading that silently spans two passes of the same music, which is what
 * `docs/WIRE.md` says this bit exists to prevent.
 *
 * So edge flags do not ride in the seqlock payload. They accumulate in an
 * atomic beside it and are handed to the reader whole, once, on the next
 * successful read. Sampling rate stops mattering: the reader cannot miss an
 * edge, only learn about it up to one frame late.
 */

#pragma once

#include <atomic>

#include "OaaWire.h"

namespace oaa {

/*
 * Both atomics here are read and written from `processBlock`, and the whole
 * argument for a seqlock over `atomic<Transport>` is that a lock on the audio
 * thread fails occasionally, under load, as a click. That argument is only
 * sound if these are genuinely lock-free, which is an assumption worth being a
 * build failure rather than a sentence in a comment.
 */
static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "This design puts two 32-bit atomics on the audio thread. If they "
              "are not lock-free on this target, a seqlock is no safer here than "
              "the mutex it exists to avoid.");

class TransportBox {
public:
  /*
   * Flags that describe a moment rather than a state, and so must not be
   * sampled. Set for one block by the writer, delivered exactly once to the
   * reader. Anything added here must be something a consumer counts or reacts
   * to, not something it displays — a *state* belongs in the payload, where the
   * most recent value is the right answer.
   */
  static constexpr uint32_t kStickyFlags = wire::kDiscontinuity;

  /*
   * Audio thread. Real-time safe: no allocation, no lock, no syscall, no
   * unbounded loop.
   *
   * The odd/even sequence is the whole mechanism. An odd value means "a write
   * is in progress, what you are reading may be half of two different
   * transports"; the reader sees that and retries rather than believing it.
   */
  void publish(const wire::Transport& t) noexcept {
    /* Before the payload, and by OR rather than by assignment: two relocates
     * between two reads must both survive, and a `store` would drop the first.
     * `fetch_or` on a 32-bit atomic is lock-free everywhere this builds, which
     * is what makes it legal here at all. */
    if (const uint32_t edges = t.flags & kStickyFlags)
      sticky_.fetch_or(edges, std::memory_order_relaxed);

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
  bool read(wire::Transport& out) noexcept {
    /* Taken before the payload, and the order is the point: it means the flag
     * arrives beside a position at or after the jump — where the playhead
     * landed — rather than the one it left. Read the payload first and an edge
     * published in between would be delivered with the previous position, and a
     * consumer reading the pair together would place the relocate a frame too
     * early. Put back below if the payload read loses its race, because an edge
     * dropped on the floor is the defect this whole mechanism exists to
     * remove. */
    const uint32_t edges = sticky_.exchange(0, std::memory_order_relaxed);

    for (int attempt = 0; attempt < 4; ++attempt) {
      const uint32_t before = sequence_.load(std::memory_order_relaxed);
      if ((before & 1u) != 0u)
        continue;  // a write is in flight

      std::atomic_thread_fence(std::memory_order_acquire);
      const wire::Transport candidate = value_;
      std::atomic_thread_fence(std::memory_order_acquire);

      if (sequence_.load(std::memory_order_relaxed) == before) {
        out = candidate;
        out.flags |= edges;
        return true;
      }
    }

    if (edges != 0)
      sticky_.fetch_or(edges, std::memory_order_relaxed);

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

  /* Edges seen since the last successful read. Not part of the seqlock: the
   * whole reason it is out here is that the payload is sampled and this must
   * not be. */
  std::atomic<uint32_t> sticky_{0};
};

}  // namespace oaa
