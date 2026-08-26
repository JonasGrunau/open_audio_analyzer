# Metrics

Every quantity Open Audio Analyzer displays, with its definition and where that
definition comes from. A metric that appears in the UI without an entry here is
a number nobody can verify, which is the same as a number nobody should trust.

**Availability** says whether the current build measures it. Anything not
measured is `NaN` in the snapshot, carries a `OAA_FLAG_*_UNAVAILABLE` flag, and
renders as an em dash — never as a zero.

---

## Loudness

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `LUFS-M` | LUFS | Mean K-weighted loudness over a sliding 400 ms window. ITU-R BS.1770-4 §2, EBU Tech 3341. | **now** |
| `LUFS-S` | LUFS | Same, over 3 s. | **now** |
| `LUFS-I` | LUFS | Gated integrated loudness since reset. 400 ms blocks at 75% overlap; absolute gate −70 LUFS; relative gate 10 LU below the ungated mean of the surviving blocks. ITU-R BS.1770-4 §3. | **now** |
| `LRA` | LU | Loudness range. Distribution of 3 s short-term values, gated absolutely at −70 LUFS and relatively at −20 LU, then the 95th percentile minus the 10th. EBU Tech 3342. | **now** |

Both gated distributions are **histograms of 0.01 LU per bin holding exact
energy sums** — 8000 bins over the useful range — rather than a growing sorted
list. That is O(1) per update in constant memory, which is what makes an
integration that runs for hours cost the same as one that runs for seconds, and
the bin is an order of magnitude finer than the ±0.1 LU the standard asks the
answer to be within. `docs/PLAN.md` says 0.1 LU; the implementation went finer.

The 120-bin histogram published in the snapshot is a **different, coarser
thing** — it is for drawing, spans −60 to 0 LUFS at 0.5 LU, and is finer than a
pixel column on any real display. It is taken from the same population as the
LRA number, so a distribution drawn from it cannot disagree with the readout
beside it.

The **Loudness Distribution** module draws it, bracketed between the two
percentiles with `LRA` printed on the bracket — see
`lib/src/modules/loudness_distribution.dart`. Every bin is drawn at the height
it was published; where the module is narrower than 120 pixels a column takes
the **loudest bin it covers** rather than their mean, which is the same choice,
for the same reason, that the engine makes mapping transform bins into spectrum
bands: a mean at a coarser resolution hides a spike, and a spike here is a
section of the programme that sat at one level.

Note that the *Histogram* module is a different picture of the same
measurement: short-term loudness against time rather than against how often.
Only one of the two names is literally a histogram; both are the names these
displays are known by, so both are kept.

The Histogram **draws an average of its two bands** rather than each 100 ms
column as measured, and says which in its own menu: `Smoothing` is Off (no
averaging), Light (0.5 s), Normal (1.0 s) or Broad (2.0 s), and Normal is the
default. Both bands take the same window, because the gap between them is the
reading and smoothing one of them would make that gap a difference between two
filters. The window is **centred**, not trailing: the module draws history, so a
lagging filter would slide the whole curve along a time axis labelled in seconds
before now and be wrong about *when* — what a symmetric window costs instead is
that the newest column, which has no future yet, is an average of the newest
half-window and settles as it ages. Nothing goes past 2 s, because short-term
loudness is a 3 s window already and a smoother approaching it draws the
momentary band and the short-term curve as one line.

The measurement is untouched by any of it: the module's ring holds the columns
as they were measured and the averaging is applied when they are read, so the
setting redraws the whole programme so far and `Off` is the measured columns
exactly. `LUFS-M`, `LUFS-S` and every other module reading them are unaffected.

K-weighting is the BS.1770-4 two-stage filter: a high-frequency shelf followed
by an RLB high-pass. Coefficients are computed from the analog prototype **at
the stream's actual sample rate**, not read from a 48 kHz table, so 44.1, 88.2,
96 and 192 kHz are correct rather than approximately correct.

Channel weights are BS.1770-4: L, R, C at 1.0, and the surround pair at 1.41
(+1.5 dB). The LFE channel is excluded from loudness, as the standard requires.
**Everything past 5.1 is unweighted** — the rear surrounds of a 7.1 layout weigh
the same as the front, which is what Report ITU-R BS.2217's channel table states
and what its two 7.1 files measure; weighting them 1.41 read those files 0.35 LU
high.

An interleaved buffer does not say which channel is which, so the layout is
inferred from the channel count — see `oaa_channel_weight` for the table. The
four-channel case is read as quad (L R Ls Rs) rather than L R C LFE, because
mistaking a surround channel for LFE would silently drop real content from the
measurement. When a device or file source supplies a real channel layout, that
should replace the inference.

## Peak

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `True Peak` | dBTP | Maximum inter-sample peak over a sliding 3 s window. ITU-R BS.1770-4 Annex 2: 4× oversampling with the specified 48-tap polyphase FIR (12 taps per phase). | **now** |
| `TP Max` | dBTP | Same, maximum since reset. | **now** |
| `Peak` | dBFS | Highest sample magnitude, with the meter's hold and fall applied. Default hold 1.5 s, fall 20 dB/s. | **now** |
| `Peak Max` | dBFS | Highest sample magnitude since reset, unheld. | **now** |
| `RMS` | dBFS | Root mean square, smoothed in the mean-square domain with a 300 ms one-pole. | **now** |
| `Clip` | samples | Longest run of consecutive samples at or above 0.999 since the last reset, per channel. **Latched**: non-zero means this channel clipped and stays non-zero until Reset. Drawn as the Digital Meter's clip lamp. | **now** |

Sample peak and true peak differ, and the difference is the point: a signal can
sit at −0.1 dBFS and still reconstruct above 0 dBTP after conversion. Only true
peak is checked against a delivery ceiling.

Oversampling is 4× at every sample rate. Above 96 kHz the standard allows 2×,
but that needs a second filter design to be correct, and 4× is never *less*
accurate — only more work, and not enough of it to notice.

## Dynamics

Analysers in this class often report one proprietary "dynamics" figure, defined
nowhere anybody outside can read it. Any claim to reproduce such a number would
be a guess presented as a measurement, so Open Audio Analyzer implements none of
them and approximates none of them. These are defined here instead, and anyone
can check them.

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Crest` | dB | Sample peak minus RMS, both over the same block — the block's own values, *not* the held peak and smoothed RMS the meters draw. For a sine this is exactly 3.0103 dB and for DC it is 0. Multichannel reports the peakiest channel rather than the loudest peak minus the loudest RMS, which could describe no channel at all. | **now** |
| `DR-S` | LU | `TruePeak − LUFS-S`. Short-term dynamic headroom. | **now** |
| `DR-I` | LU | `TruePeakMax − LUFS-I`. Programme dynamic headroom. | **now** |
| `PLR` | LU | Peak to loudness ratio: `TruePeakMax − LUFS-I`. **Identical to `DR-I`** — both names are in common use, so both are offered. | **now** |
| `PSR` | LU | Peak to short-term ratio: `TruePeak − LUFS-S` over the same 3 s window. **Identical to `DR-S`**, for the same reason. | **now** |

Those are four names for two numbers, and the engine computes each pair once so
they cannot drift apart. A report prints each value once — under `PLR`, the
spelling in wider use outside this project — rather than listing the same
measurement twice under two headings with nothing saying they are the same.

None of these is the "DR" of the offline TT Dynamic Range meter, which is a
different measurement with a different algorithm. Open Audio Analyzer does not
report that number under any name.

## Stereo field

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Correlation` | — | Pearson correlation of L and R. `+1` identical (mono), `0` uncorrelated, `−1` polarity-inverted. Smoothed with a 200 ms one-pole so it is readable. | **now** |
| `Balance` | — | `(E_R − E_L) / (E_R + E_L)` where E is block energy. `−1` hard left, `0` centred, `+1` hard right. | **now** |

Mono sources report correlation `+1` and balance `0`. Saying so is more useful
than reporting nothing, and it is also true.

**The two displays that plot the stereo field do not draw it, though.** The raw
sample stream a goniometer reads is built the same way the spectrum's pan is —
channel 0 is copied into the right slot of every frame when there is only one
channel — so a one-channel source is `L == R` exactly, and the Phase Scope
rotates that into a hard, perfectly straight vertical line that never moves. It
is a true picture of a tautology and it is indistinguishable from a display that
has stuck, which is what the Stereo Cloud's version of it was reported as. Both
say **MONO SOURCE** across the face instead and leave their graticule drawn. The
correlation bar under the Phase Scope is drawn as an empty track for the same
reason: `+1` pinned hard against its right end is the same tautology one row
lower. The number itself is still measured and still available — a Number Box set
to `Correlation` prints it, and so does an offline report.

## Spectrum

| Metric | Unit | Definition | Availability |
|---|---|---|---|
| `Spectrum` | dBFS | 512 log-spaced bands from 20 Hz to 20 kHz. A 4096-point Hann window per channel at a 1024-sample hop, zero-padded to a 16384-point transform. A band wide enough to contain bins takes the **loudest bin in the band** rather than their mean, so that a narrow resonance survives the mapping; a band too narrow to contain one reads the transform **between** its two nearest bins. | **now** |
| `Spectrum peak` | dBFS | Per-band hold, computed in the engine because a transform runs every hop and a publish carries only the last one. | **now** |
| `Spectrum pan` | — | Per-band stereo position, `−1` hard left to `+1` hard right. What the stereo cloud draws. | **now**, two channels or more |

The Spectrum Analyzer **draws** an average of these bands rather than the last
one published, and says which in its own menu: `Response` is Fast (no
averaging), Normal (120 ms) or Slow (500 ms), and Normal is the default. The
averaging is one pole per band on the dB value being drawn — a display
ballistic, in the sense a VU movement is one, not a power average of the signal.
The line above the curve is the **envelope of that curve**: the highest it has
been, held for 1.5 s and then let down at 12 dB/s, which is the schedule the
engine's own `Spectrum peak` follows. It therefore moves with the curve instead
of snapping to a peak the curve is still easing towards, and on a slow response
it sits below a peak the programme really reached, because the curve it is
holding never went there. Fast is the setting that catches a click.

`Tilt` in the same menu rotates the drawn curve about **1 kHz**, at 0, 1.5, 3,
4.5 or 6 dB per octave, and 4.5 dB/oct is the default. It adds a fixed offset
per band — nothing else — and exists because programme material falls with
frequency at roughly 3 to 4.5 dB an octave, so an untilted analyser draws every
mix as the same ramp and spends its height on the one part of the picture that
carries no information. At 4.5 dB/oct the ends of the range are rotated 44.8 dB
apart: 20 Hz is drawn 25.4 dB lower than it measures and 20 kHz 19.4 dB higher.
**The dB scale on the right is therefore true at 1 kHz and rotated away from
it**, which is why the module prints the tilt it is drawing at, and why 0 dB/oct
— where the scale is true everywhere — prints nothing.

The measurement above is untouched by any of it: `Spectrum` and `Spectrum peak`
are what the wire protocol carries whatever a module is set to, and every other
module reading these bands — the spectrogram, the stereo cloud — draws them as
published.

Spectrum pan needs a front pair. A one-channel source reports every band at `0`,
for the same reason correlation reports `+1` — mono is dead centre, and it is
true. The stereo cloud does not *draw* that, because a column of centred bands
is a bright vertical line down the middle of the display and is read as a
broken module rather than as a mono signal; it says **MONO SOURCE** instead, as
the Phase Scope does for the same reason — see **Stereo field**.

Levels are window-compensated: a full-scale sine on a bin centre reads
0.0 dBFS, and that is asserted on every push. A tone **between** two bin centres
reads within 0.3 dB of its own level, asserted likewise.

The window and the transform are different lengths and they answer different
questions. The **window** is what the analysis can resolve: 4096 points is an
11.7 Hz main lobe at 48 kHz, and two tones closer together than that merge into
one hump no matter what follows. The **transform** is how finely that lobe is
sampled for drawing, and padding the window out to 16384 samples the same
transform of the same audio every 2.93 Hz instead of every 11.7 Hz. Nothing is
invented by it: a zero-padded DFT is the exact continuous-frequency transform of
the windowed frame, read at four times as many frequencies.

That is also why the bands below about 216 Hz are allowed to read between two
bins. The bottom octave of the display is 51 of the 512 bands spread across
20 Hz and no real-time transform puts a bin every 0.4 Hz, so rounding each band
to its nearest bin drew the bass as a staircase. The bins on either side are not
separate measurements with unknown territory between them — they are samples of
one continuous curve, taken four to a main lobe, and a straight line between two
of them is within about a tenth of a decibel of it. Frequency **resolution** is
unchanged by any of this; only the sampling of it is finer.

A/C/Z weighting and selectable FFT sizes are named in `docs/PLAN.md` and are
**not built**: the window is 4096 points, unweighted (Z). One set of
transforms feeds the analyser, the spectrogram and the stereo cloud, so three
modules cannot disagree about where a peak is.

## Conventions

- **The dB floor is −144.0**, a little below the noise floor of 24-bit audio.
  Real `-INFINITY` is avoided because differences of dB values are meaningful
  here — crest is peak minus RMS — and `-inf − -inf` is `NaN`, which would turn
  a silent passage into "no data".
- **Reset** clears every integrating quantity (`LUFS-I`, `LRA`, all `Max`
  values, the latched clip runs) and restarts the elapsed clock. Momentary
  values are left alone; they describe the signal, not the session. For `Clip`
  this is the *only* thing that clears it: a clip lamp that goes out on its own
  is a clip lamp you can miss by looking away.
- **Elapsed time is counted in samples, never in wall clock.** A file analysed
  at 200× real time must produce exactly the same numbers as the same file
  played back live — that identity is how offline analysis is verified.
- **Every loudness window is built from 10 ms sub-blocks**, so `LUFS-M` and
  `LUFS-S` advance every 10 ms and the `Max` of either resolves a transient to
  within 0.054 LU wherever it falls. The two *gated* windows still step 100 ms —
  the 75% overlap BS.1770 specifies for the 400 ms blocks behind `LUFS-I`, and
  the same rate for the 3 s blocks behind `LRA` — so the sub-block is finer than
  the standard's grid without changing what the standard computes.

## Conformance

CI runs the **EBU Tech 3341 and 3342** cases on every push, on Linux, macOS and
Windows, and fails the build if any result differs from the standard's value by
more than its stated tolerance. See
`packages/oaa_engine/test/conformance_test.dart`.

The signals are **generated rather than downloaded**. Every case is a sine at a
stated level or a sequence of them, so each is constructed exactly in a few
lines — no fixtures, no network, no WAV decoder — and the expected values are
derived from the standard in the comments rather than copied from somebody's
output. The suite also asserts two properties the standard does not state
directly but which no correct implementation can violate:

- **Sample rate independence.** The same tone reads the same loudness at 44.1,
  48, 88.2, 96 and 192 kHz. This is what catches the tempting shortcut of using
  the 48 kHz coefficient table BS.1770-4 prints instead of designing the filter
  at the stream's rate — a shortcut that passes every 48 kHz test there is and
  is wrong by a fraction of a dB on the most common delivery rate in music.
- **Block size independence.** Pushing ten seconds in one call, in 512-frame
  device blocks, and in 377-frame chunks agree to within 0.001 LU.

- **Decoding does not change a reading.** A generated signal analysed directly
  and the same signal written to a WAV, decoded and analysed again produce
  identical numbers, to the bit. That is the property offline analysis rests on,
  and it is asserted rather than assumed — see
  `packages/oaa_engine/test/decode_test.dart`.

### The official vectors

Both official sets are run, and they are **not a gate.** The obstacle was never
technical: neither body licenses its test material for redistribution here, and
fetching 811 MB in CI would put a network dependency in front of the one suite
that must never be flaky. So `packages/oaa_engine/test/vectors_test.dart` skips
per group, unless told where an unzipped copy is:

```sh
cd packages/oaa_engine
OAA_VECTORS=~/ebu-loudness-test-set \
OAA_VECTORS_ITU=~/bs2217 \
  dart test test/vectors_test.dart
```

| Set | Where | Cases |
|---|---|---|
| **EBU Loudness Test Set** v05 | [tech.ebu.ch](https://tech.ebu.ch/publications/ebu_loudness_test_set) | 68. Table 1 of Tech 3341 entire — 1–8 integrated (both authentic programme segments included), 9–11 short-term, 12–14 momentary, 15–23 true peak — and Table 1 of Tech 3342, 1–6, for LRA. |
| **Report ITU-R BS.2217** | [48 archives](https://www.itu.int/oth/R1102000001/en) linked from the report | 44. Twelve tones from 25 Hz to 10 kHz, the constant-loudness sweep, the absolute and relative gate tests, the 5.1 channel and summing checks, both LFE checks, 7.1, and ten programme files in mono, stereo and 5.1. |

**All 112 pass.** Tolerances are the standards' own: ±0.1 LU, +0.2/−0.4 dBTP,
±1 LU for LRA, ±0.1 LKFS for the ITU set.

Six ITU files are wider than 7.1 — 10, 12 and 24 channels — and the engine
carries eight. Those are asserted to be **refused**: it has no weights for those
layouts, and a number produced without them would be read as if it meant
something.

**The run was worth doing, because it found two defects the generated cases could
not.** Both are in `CHANGELOG.md` with their magnitudes:

- **Momentary loudness advanced only every 100 ms.** Tech 3341's tests 13 and 14
  take a 400 ms tone — exactly one momentary window — and slide it through twenty
  files in 20 ms steps, so the tone lies inside exactly one window and no other.
  On a 100 ms grid sixteen of the twenty read up to 0.45 LU low, and test 14 up
  to 0.70. The sub-block is 10 ms now; both gating windows are still filed every
  100 ms, so nothing integrating moved.
- **7.1 carried the surround weight on its rear pair.** The ITU's channel table
  gives 7.1 as 1.00 / 1.00 / 1.00 / N/A / 1.41 / 1.41 / 1.00 / 1.00, and its two
  7.1 files read 0.35 LU high until that was true. They now read −23.000 and
  −24.000 exactly.

Neither could have come from a suite that writes its own signals: one needs a
tone that does not start at sample zero, the other needs a layout wider than the
one the author was thinking about. That is the argument for material somebody
else made — and equally the argument for not treating it as a replacement. The
generated cases gate every push on three platforms and carry the sample-rate and
block-size properties no shipped vector file asserts, so anything the official
files caught that a generated signal can also express is asserted there too.

---

## What a file report states

A snapshot mixes two kinds of quantity, and a report has to treat them
differently or it describes the wrong thing.

**Integrating** — read once at the end, which is correct for them: `LUFS-I`,
`LRA` and its percentiles, `TP Max`, `Peak Max`.

**Instantaneous** — these describe the moment they are read, so at the end of a
file they describe the final block, which is usually the fade-out or silence.
A report watches them across the whole programme instead:

| Reported as | Is |
|---|---|
| `LUFS-M` | the **highest** momentary loudness reached |
| `LUFS-S` | the **highest** short-term loudness reached |
| Correlation | the **mean** across the file; the panel also shows the range |
| Peak per channel | the **highest** on each channel |

`PLR` and `DR-I` are derived — `TP Max` minus `LUFS-I` — rather than stored, so
they cannot disagree with the numbers they are computed from.

A file is analysed in blocks of the same size the realtime path uses. The gated
loudness measurements are sample-accurate and genuinely independent of block
size, but RMS, crest and the VU ballistics are computed per block, so pushing a
whole file in one call would report one RMS averaged across the entire
programme.
