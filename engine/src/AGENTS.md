# engine/src/

| File | Job |
|------|-----|
| `oaa_atomic.h` | The four atomic operations the seqlock needs, implemented twice (C11 and MSVC intrinsics). Deliberately tiny. |
| `oaa_internal.h` | The engine struct and the two OS primitives. Nothing here is ABI. |
| `oaa_snapshot.c` | The seqlock. Wait-free for the writer; the *reader* retries. |
| `oaa_source.c` | Where blocks of audio come from — silence, the test tone, a device, a file, or samples the caller pushes. All five behind one `oaa_source_render`, which takes a frame count and a buffer and exposes nothing about their origin. |
| `oaa_kweight.h/.c` | The BS.1770-4 K-weighting biquads, **designed at the stream's sample rate** rather than tabulated, plus the channel weight table. |
| `oaa_loudness.h/.c` | Sub-block accumulation, R128 gating, momentary/short-term/integrated, and the LRA histogram. |
| `oaa_truepeak.h/.c` | The BS.1770-4 Annex 2 4x polyphase oversampler. |
| `oaa_spectrum.h/.c` | The Hann STFT behind the analyser, the spectrogram and the stereo cloud — a 4096-point window zero-padded into a 16384-point transform. One set of transforms serves all three: one per channel, plus two for the front pair's mid and side as signals of their own, folded into five band sets — the combined loudest-bin fold and the pair's left, right, mid and side, each with its own peak hold. Mid and side are transformed rather than derived because per-channel *power* has thrown away the cross term `2 Re(L R*)` that `\|L + R\|^2` needs. |
| `oaa_ring.h/.c` | The SPSC ring between the audio callback and analysis. Drops are **counted and published**, never silently overwritten. |
| `oaa_device.h/.c` | miniaudio, cut down to enumeration and capture. The only file that includes miniaudio.h. Also the dispatcher: one reserved device id opens a process tap instead. Answers whether the producer is still running, and puts a stopped one back — asked about itself rather than timed, because a device delivering nothing is not necessarily a device that has stopped. |
| `oaa_tap.h` | The system-output tap's C interface, the only place the policy for a changing output device is written down — including why a rebuild that fails must be retried rather than left as no producer at all, and the assertion that fails the build below a macOS 14.2 deployment target — see its header for why a lower one made the whole engine library unloadable. Declares its handle everywhere, its functions on macOS only. |
| `oaa_tap_macos.m` | Core Audio process taps, macOS 14.2+ — which is the engine's deployment floor rather than a runtime check, because that class reference is strong. **The engine's only Objective-C**, and its only source not built on every platform — `CATapDescription` is an Objective-C class and the SDK hides the tapping API behind `#ifdef __OBJC__`. |
| `oaa_decode.c` | dr_libs, as `oaa_file_open/read/seek/close`. The only file that does I/O, and the only one that includes dr_wav/dr_flac/dr_mp3. No analysis: the caller pushes what it reads. |
| `oaa_analysis.c` | One pass over a block: the simple meters inline, the two standards-defined ones driven. |
| `oaa_engine.c` | Lifecycle, the analysis thread, and the OS shims. Also the four-times-a-second watch on the capture source, which is the only thing that can tell an empty ring from a producer that has left. |

## Rules

- **The capture callback is real-time context.** No malloc, no locks, no
  syscalls, no logging — it does a bounds check and up to two memcpys and
  returns. Anything added there that can block will drop audio.
- **Open a device, size the ring, then start it.** The ring's frame stride must
  equal the device's channel count, and that is not known until the device has
  been negotiated. Sizing the ring for OAA_MAX_CHANNELS and starting inside
  open reads eight floats per frame out of a one-float-per-frame buffer; it
  crashed immediately on a mono built-in microphone and would have corrupted
  memory quietly on a stereo one.
- **After `oaa_device_start` returns, nothing may `free(engine)` without
  closing the device first.** The callback holds `&engine->ring`, on a thread
  we do not own, and the block it points into goes straight back to the
  allocator. Every failure path in `oaa_engine_create` therefore exits through
  `oaa_engine_destroy`, which is safe on a half-built engine because every
  owned resource hangs off a field `calloc` left null or a flag it left clear.
  The paths that get this wrong are the out-of-memory ones, where the next
  allocation — the one that reuses the block — is exactly what is under
  pressure.
- **`oaa_engine_stop` joins on `thread_started`, not on either atomic flag.**
  `should_run` is the stop *signal*, so testing it makes stop() decide whether
  to join by reading the flag it is about to clear; `thread_alive` is the
  thread's own report and goes false a few instructions before the thread
  returns. Only "did we start a thread we have not joined" answers the
  question, and only the owner's thread touches it.
- **The engine adopts the device's format; it never converts to its own.** A
  resampler in front of the measurement moves inter-sample peaks and shifts the
  K-weighted energy. MA_NO_DECODING is set partly to make that impossible.
- **The system-output tap obeys that rule too, and it is why it is bound to a
  device rather than global.** `CATapDescription` offers global variants that
  are far simpler to use, and every one of them mixes down to mono or stereo —
  a 7.1 output metered as stereo is a measurement of a programme nobody played.
  `initExcludingProcesses:andDeviceUID:withStream:` produces the stream's own
  format instead. The cost is that the tap is then tied to one device, which is
  what the default-output listener in `oaa_tap_start` exists to handle: it
  rebuilds on the new device when the format matches and stops when it does
  not. **It must never follow by resampling.** A tap left bound to a device
  nobody is listening to reads digital black, which is exactly the invented
  measurement this engine refuses to produce — so "stop" is the honest answer
  and "convert" is not.
- **`MA_NO_DECODING` is now load-bearing twice.** As well as forbidding format
  conversion on the capture path, it is what stops miniaudio compiling its own
  bundled copies of dr_wav, dr_flac and dr_mp3 — which would collide at link
  time with the ones `oaa_decode.c` compiles. If a duplicate-symbol error ever
  appears, removing it is not the fix.
- **File decoding does not resample or remix either.** `oaa_file_open` reports
  the file's own rate and channel count and the caller configures the engine to
  match. Offline analysis then pushes decoded blocks through the same
  `oaa_analyse` a device drives, which is what makes "the file report equals
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
  and `oaa_snapshot_publish` copies it into `shared` *between* the two sequence
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
  dereferenced. `oaa_loudness`'s sub-block ring had one; something outside that
  file put a float bit pattern in it, and a sub-block boundary became an 8-byte
  store 229 GB past the engine, in reserved address space. The row is now
  `subblocks_done % OAA_SHORTTERM_SUBBLOCKS`, computed at the point of use, so
  the store is in range whatever the counter holds. `window_energy` was already
  written this way and was never exposed. One modulo per sub-block, which is
  every 10 ms.
- **Ballistics constants are named and commented with their standard.** A magic
  `0.0651f` in a VU meter is unreviewable.
- **Anything with a standard cites it, by clause.** The magic numbers in
  `oaa_kweight.c` and the FIR table in `oaa_truepeak.c` are only reviewable
  against the document they came from, so the document is named next to them
  and the digits are not rounded.
- **A change to any measurement needs a conformance run and a CHANGELOG entry
  under the 📐 section.** Users make delivery decisions from these numbers; a
  reading that moves without being announced silently invalidates somebody's
  master.

  For anything in `oaa_loudness.*`, `oaa_kweight.*` or `oaa_truepeak.*` the
  conformance run means both suites: the generated cases that gate every push,
  *and* the official vectors in
  `packages/oaa_engine/test/vectors_test.dart`, which need the EBU and ITU
  material and skip without it. They are worth the download — the momentary
  sub-block was 100 ms and the 7.1 rear surrounds carried the surround weight,
  and the gated suite could see neither, because a signal you write yourself
  starts where you expect it to and has the channel count you were thinking
  about.
- **When an approximation is used, say so and say what is missing.** The VU used
  to be a one-pole, which matched the 300 ms figure and had none of the
  overshoot that makes a VU meter feel like one; the comment saying so is what
  eventually got it replaced with the second-order movement that is there now.
  Do not let a comment like that quietly get deleted as the thing gets promoted
  to "good enough".
- **Display ballistics belong here, display *choices* do not.** The spectrum's
  peak hold is in the engine because a transform runs every hop and a publish
  carries only the last one, so a hold computed downstream would miss whatever
  landed between them: `spectrum_peak` is a measurement, and it is on the wire
  and in a report whether anything draws it or not. What the analyser draws
  above its curve is *not* that — it is the envelope of the curve it has drawn,
  held on the same schedule, which is a choice about a picture and lives in the
  module. The goniometer's 45° rotation is the same kind of thing, and is not
  here either, because it is a convention one module has and the CLI does not —
  and baking it into the ABI would make every other consumer undo it.
