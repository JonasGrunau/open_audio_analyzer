# engine/src/

| File | Job |
|------|-----|
| `bel_atomic.h` | The four atomic operations the seqlock needs, implemented twice (C11 and MSVC intrinsics). Deliberately tiny. |
| `bel_internal.h` | The engine struct and the two OS primitives. Nothing here is ABI. |
| `bel_snapshot.c` | The seqlock. Wait-free for the writer; the *reader* retries. |
| `bel_source.c` | Where blocks of audio come from — silence, the test tone, a device, a file, or samples the caller pushes. All five behind one `bel_source_render`, which takes a frame count and a buffer and exposes nothing about their origin. |
| `bel_kweight.h/.c` | The BS.1770-4 K-weighting biquads, **designed at the stream's sample rate** rather than tabulated, plus the channel weight table. |
| `bel_loudness.h/.c` | Sub-block accumulation, R128 gating, momentary/short-term/integrated, and the LRA histogram. |
| `bel_truepeak.h/.c` | The BS.1770-4 Annex 2 4x polyphase oversampler. |
| `bel_spectrum.h/.c` | The Hann STFT behind the analyser, the spectrogram and the stereo cloud — a 4096-point window zero-padded into a 16384-point transform. One set of transforms serves all three. |
| `bel_ring.h/.c` | The SPSC ring between the audio callback and analysis. Drops are **counted and published**, never silently overwritten. |
| `bel_device.h/.c` | miniaudio, cut down to enumeration and capture. The only file that includes miniaudio.h. |
| `bel_decode.c` | dr_libs, as `bel_file_open/read/seek/close`. The only file that does I/O, and the only one that includes dr_wav/dr_flac/dr_mp3. No analysis: the caller pushes what it reads. |
| `bel_analysis.c` | One pass over a block: the simple meters inline, the two standards-defined ones driven. |
| `bel_engine.c` | Lifecycle, the analysis thread, and the OS shims. |

## Rules

- **The capture callback is real-time context.** No malloc, no locks, no
  syscalls, no logging — it does a bounds check and up to two memcpys and
  returns. Anything added there that can block will drop audio.
- **Open a device, size the ring, then start it.** The ring's frame stride must
  equal the device's channel count, and that is not known until the device has
  been negotiated. Sizing the ring for BEL_MAX_CHANNELS and starting inside
  open reads eight floats per frame out of a one-float-per-frame buffer; it
  crashed immediately on a mono built-in microphone and would have corrupted
  memory quietly on a stereo one.
- **After `bel_device_start` returns, nothing may `free(engine)` without
  closing the device first.** The callback holds `&engine->ring`, on a thread
  we do not own, and the block it points into goes straight back to the
  allocator. Every failure path in `bel_engine_create` therefore exits through
  `bel_engine_destroy`, which is safe on a half-built engine because every
  owned resource hangs off a field `calloc` left null or a flag it left clear.
  The paths that get this wrong are the out-of-memory ones, where the next
  allocation — the one that reuses the block — is exactly what is under
  pressure.
- **`bel_engine_stop` joins on `thread_started`, not on either atomic flag.**
  `should_run` is the stop *signal*, so testing it makes stop() decide whether
  to join by reading the flag it is about to clear; `thread_alive` is the
  thread's own report and goes false a few instructions before the thread
  returns. Only "did we start a thread we have not joined" answers the
  question, and only the owner's thread touches it.
- **The engine adopts the device's format; it never converts to its own.** A
  resampler in front of the measurement moves inter-sample peaks and shifts the
  K-weighted energy. MA_NO_DECODING is set partly to make that impossible.
- **`MA_NO_DECODING` is now load-bearing twice.** As well as forbidding format
  conversion on the capture path, it is what stops miniaudio compiling its own
  bundled copies of dr_wav, dr_flac and dr_mp3 — which would collide at link
  time with the ones `bel_decode.c` compiles. If a duplicate-symbol error ever
  appears, removing it is not the fix.
- **File decoding does not resample or remix either.** `bel_file_open` reports
  the file's own rate and channel count and the caller configures the engine to
  match. Offline analysis then pushes decoded blocks through the same
  `bel_analyse` a device drives, which is what makes "the file report equals
  what the meters showed" true by construction rather than by inspection.
- **Push in blocks, not in one call.** The gated loudness measurements are
  sample-accurate and independent of block size, but RMS, crest and the VU
  ballistics are computed per pushed block — a whole file in one push reports
  one RMS averaged over the entire programme and a VU needle that moves once.
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
- **Reduce an index where it is used, not where it is produced, and do not
  carry it in a field.** A cursor kept beside the array it indexes is the same
  number stored twice, and the copy has to be *trusted* every time it is
  dereferenced. `bel_loudness`'s sub-block ring had one; something outside that
  file put a float bit pattern in it, and a 100 ms boundary became an 8-byte
  store 229 GB past the engine, in reserved address space. The row is now
  `subblocks_done % BEL_SHORTTERM_SUBBLOCKS`, computed at the point of use, so
  the store is in range whatever the counter holds. `window_energy` was already
  written this way and was never exposed. One modulo per 100 ms.
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
- **When an approximation is used, say so and say what is missing.** The VU used
  to be a one-pole, which matched the 300 ms figure and had none of the
  overshoot that makes a VU meter feel like one; the comment saying so is what
  eventually got it replaced with the second-order movement that is there now.
  Do not let a comment like that quietly get deleted as the thing gets promoted
  to "good enough".
- **Display ballistics belong here, display *choices* do not.** The spectrum's
  peak hold is in the engine because a transform runs every hop and a publish
  carries only the last one, so a hold computed downstream would miss whatever
  landed between them. The goniometer's 45° rotation is not, because it is a
  convention one module has and the CLI does not — and baking it into the ABI
  would make every other consumer undo it.
