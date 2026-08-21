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
 * Every atomic here is read and written from `processBlock`, and the whole
 * argument for a seqlock over `atomic<Transport>` is that a lock on the audio
 * thread fails occasionally, under load, as a click. That argument is only
 * sound if these are genuinely lock-free, which is an assumption worth being a
 * build failure rather than a sentence in a comment.
 */
static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "This design puts three 32-bit atomics on the audio thread. If they "
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

    /* **The edges are stripped from the payload, and this line is the whole
     * reason `kStickyFlags` is a named set.** The payload is *sampled* — the
     * reader takes whatever is current, and the same block can be current for
     * two reads in a row — so a flag left in it is a flag that can be delivered
     * twice. `sticky_` is the only place an edge may live, because it is the
     * only thing here that is claimed rather than sampled.
     *
     * This shipped, and it took a loaded machine to show: the streamer normally
     * publishes less often than the audio thread does, so a jump block was
     * sampled once and the duplicate never appeared. On a busy CI runner the
     * two rates cross — two frames went out inside one audio block, both
     * carrying the jump block's own flags — and a single relocate arrived as
     * two. `docs/WIRE.md` lets a consumer count relocations by counting flagged
     * frames, so the count was simply wrong, and the same run reported four
     * laps of a three-lap loop. Found by
     * `packages/oaa_wire/test/plugin_e2e_test.dart` on macOS, which was the
     * first time those cases had ever run on that runner. */
    value_.flags &= ~kStickyFlags;

    std::atomic_thread_fence(std::memory_order_release);

    sequence_.store(start + 2, std::memory_order_relaxed);

    /* Outside the seqlock on purpose. This is not part of the reading — it is
     * the answer to "is the host saying anything at all", which the status
     * panel asks from the message thread and must be able to get without taking
     * part in a retry loop it could lose. Sticky bits are excluded for the same
     * reason they are stripped from the payload above: a relocate is an event,
     * not a state, and a single flagged block must not leave this claiming a
     * transport that has since gone away. */
    stateFlags_.store(t.flags & ~kStickyFlags, std::memory_order_relaxed);
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

  /*
   * True while the host is telling us where it is. There is nothing to show
   * when it is false, and the display must say so rather than render a
   * default-constructed transport parked at bar one.
   *
   * **Not "has a block gone through yet",** which is what this was and which
   * made the plugin's own status panel report a playhead the moment audio
   * started flowing — on a host that had said nothing at all, which is the one
   * state that line exists to report. `captureTransport` publishes for *every*
   * block, the empty transport included, so a publication having happened says
   * nothing about a transport having arrived. The flags say it: a host that
   * reports anything at all sets at least one, and an empty transport sets
   * none.
   *
   * Current rather than ever, because the panel is read beside the
   * application's dashes and answers *why* they are there. A host that stops
   * reporting a position — which `captureTransport` handles as a state rather
   * than as an error — is a host the display has stopped drawing one for.
   */
  bool hostReportsPosition() const noexcept {
    return stateFlags_.load(std::memory_order_relaxed) != 0u;
  }

private:
  std::atomic<uint32_t> sequence_{0};
  wire::Transport value_{};

  /* Edges seen since the last successful read. Not part of the seqlock: the
   * whole reason it is out here is that the payload is sampled and this must
   * not be. */
  std::atomic<uint32_t> sticky_{0};

  /* The state flags of the most recent publication, for a reader that only
   * wants to know whether the host is saying anything. */
  std::atomic<uint32_t> stateFlags_{0};
};

}  // namespace oaa
