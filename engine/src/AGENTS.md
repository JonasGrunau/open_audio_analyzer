# engine/src/

| File | Job |
|------|-----|
| `bel_atomic.h` | The four atomic operations the seqlock needs, implemented twice (C11 and MSVC intrinsics). Deliberately tiny. |
| `bel_internal.h` | The engine struct and the two OS primitives. Nothing here is ABI. |
| `bel_snapshot.c` | The seqlock. Wait-free for the writer; the *reader* retries. |
| `bel_source.c` | Where blocks of audio come from. Phase 0: silence and the test tone. |
| `bel_kweight.h/.c` | The BS.1770-4 K-weighting biquads, **designed at the stream's sample rate** rather than tabulated, plus the channel weight table. |
| `bel_loudness.h/.c` | Sub-block accumulation, R128 gating, momentary/short-term/integrated, and the LRA histogram. |
| `bel_truepeak.h/.c` | The BS.1770-4 Annex 2 4x polyphase oversampler. |
| `bel_analysis.c` | One pass over a block: the simple meters inline, the two standards-defined ones driven. |
| `bel_engine.c` | Lifecycle, the analysis thread, and the OS shims. |

## Rules

- **The analysis thread must never be delayed.** It sits downstream of a
  real-time audio callback; if it falls behind, the ring overruns and signal is
  lost for good. That is why publishing is a seqlock and not a mutex, and why
  nothing on this thread may block, allocate or take a lock.
- **The seqlock window is one `memcpy`.** Analysis accumulates into `staging`
  and `bel_snapshot_publish` copies it into `shared` *between* the two sequence
  increments. Writing into `shared` directly would put the payload writes
  outside the odd/even window, and a reader could then observe a torn block with
  matching sequence numbers on both sides and never know.
- **Reset happens at a block boundary,** never in place from the owner's thread.
  Clearing the integrators mid-pass is a plain data race whose symptom — one
  impossible reading right after a reset — gets dismissed as a display glitch
  and never fixed.
- **Ballistics constants are named and commented with their standard.** A magic
  `0.0651f` in a VU meter is unreviewable.
- **Anything with a standard cites it, by clause.** The magic numbers in
  `bel_kweight.c` and the FIR table in `bel_truepeak.c` are only reviewable
  against the document they came from, so the document is named next to them
  and the digits are not rounded.
- **A change to any measurement needs a conformance run and a CHANGELOG entry
  under the 📐 section.** Users make delivery decisions from these numbers; a
  reading that moves without being announced silently invalidates somebody's
  master.
- **When an approximation is used, say so and say what is missing.** See the VU
  comment in `bel_analysis.c`: a one-pole matches the 300 ms figure and has none
  of the overshoot that makes a VU meter feel like one. Do not let a comment
  like that quietly get deleted as the thing gets promoted to "good enough".
