# Metrics

Every quantity Bel displays, with its definition and where that definition comes
from. A metric that appears in the UI without an entry here is a number nobody
can verify, which is the same as a number nobody should trust.

**Availability** says whether the current build measures it. Anything not
measured is `NaN` in the snapshot, carries a `BEL_FLAG_*_UNAVAILABLE` flag, and
renders as an em dash — never as a zero.

---

## Loudness

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `LUFS-M` | LUFS | Mean K-weighted loudness over a sliding 400 ms window. ITU-R BS.1770-4 §2, EBU Tech 3341. | Phase 1 |
| `LUFS-S` | LUFS | Same, over 3 s. | Phase 1 |
| `LUFS-I` | LUFS | Gated integrated loudness since reset. 400 ms blocks at 75% overlap; absolute gate −70 LUFS; relative gate 10 LU below the ungated mean of the surviving blocks. ITU-R BS.1770-4 §3. | Phase 1 |
| `LRA` | LU | Loudness range. Distribution of 3 s short-term values, gated absolutely at −70 LUFS and relatively at −20 LU, then the 95th percentile minus the 10th. EBU Tech 3342. | Phase 1 |

K-weighting is the BS.1770-4 two-stage filter: a high-frequency shelf followed
by an RLB high-pass. Coefficients are computed from the analog prototype **at
the stream's actual sample rate**, not read from a 48 kHz table, so 44.1, 88.2,
96 and 192 kHz are correct rather than approximately correct.

Channel weights are BS.1770-4: L, R, C at 1.0, and the surround channels at
1.41. The LFE channel is excluded from loudness, as the standard requires.

## Peak

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `True Peak` | dBTP | Maximum inter-sample peak over a sliding 3 s window. ITU-R BS.1770-4 Annex 2: 4× oversampling with the specified 48-tap polyphase FIR (12 taps per phase); 2× at ≥96 kHz. | Phase 1 |
| `TP Max` | dBTP | Same, maximum since reset. | Phase 1 |
| `Peak` | dBFS | Highest sample magnitude, with the meter's hold and fall applied. Default hold 1.5 s, fall 20 dB/s. | **now** |
| `Peak Max` | dBFS | Highest sample magnitude since reset, unheld. | **now** |
| `RMS` | dBFS | Root mean square, smoothed in the mean-square domain with a 300 ms one-pole. | **now** |

Sample peak and true peak differ, and the difference is the point: a signal can
sit at −0.1 dBFS and still reconstruct above 0 dBTP after conversion. Only true
peak is checked against a delivery ceiling.

## Dynamics

Decibel reports a figure called *TrueDyn*. It is proprietary and undocumented,
so any claim to reproduce it would be a guess presented as a measurement. Bel
does not implement it and does not approximate it. These are defined here
instead, and anyone can check them.

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Crest` | dB | Sample peak minus RMS, both over the same block. For a sine this is exactly 3.0103 dB, which is what the engine's test suite asserts. | **now** |
| `DR-S` | LU | `TruePeak − LUFS-S`. Short-term dynamic headroom. | Phase 1 |
| `DR-I` | LU | `TruePeakMax − LUFS-I`. Programme dynamic headroom. | Phase 1 |
| `PLR` | LU | Peak to loudness ratio: `TruePeakMax − LUFS-I`. Identical to `DR-I`; both names are in common use, so both are offered. | Phase 1 |
| `PSR` | LU | Peak to short-term ratio: `TruePeak − LUFS-S` over the same 3 s window. | Phase 1 |

None of these is the "DR" of the offline TT Dynamic Range meter, which is a
different measurement with a different algorithm. Bel does not report that
number under any name.

## Stereo field

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Correlation` | — | Pearson correlation of L and R. `+1` identical (mono), `0` uncorrelated, `−1` polarity-inverted. Smoothed with a 200 ms one-pole so it is readable. | **now** |
| `Balance` | — | `(E_R − E_L) / (E_R + E_L)` where E is block energy. `−1` hard left, `0` centred, `+1` hard right. | **now** |

Mono sources report correlation `+1` and balance `0`. Saying so is more useful
than reporting nothing, and it is also true.

## Spectrum

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Spectrum` | dBFS | 512 log-spaced bands. Hann window, FFT size 1024–8192, **peak per band** rather than mean so that narrow peaks survive the mapping. A, C or Z weighting. | Phase 1 |
| `Spectrum peak` | dBFS | Per-band hold. | Phase 1 |

## Conventions

- **The dB floor is −144.0**, a little below the noise floor of 24-bit audio.
  Real `-INFINITY` is avoided because differences of dB values are meaningful
  here — crest is peak minus RMS — and `-inf − -inf` is `NaN`, which would turn
  a silent passage into "no data".
- **Reset** clears every integrating quantity (`LUFS-I`, `LRA`, all `Max`
  values, clip counters) and restarts the elapsed clock. Momentary values are
  left alone; they describe the signal, not the session.
- **Elapsed time is counted in samples, never in wall clock.** A file analysed
  at 200× real time must produce exactly the same numbers as the same file
  played back live — that identity is how offline analysis is verified.

## Conformance

From Phase 1, CI runs the **EBU R128 / ITU-R BS.2217** conformance vectors
through the engine and fails the build if any result differs from the published
value by more than 0.1 LU. `libebur128` is used as a second oracle in the C test
suite.

Until that suite is green, the loudness fields stay flagged unavailable — the
flag is cleared in the same change that adds the test, not before.
