# Open Dynamic Range

**ODR specification, version 1.0 — 2026-08-28.** This document is normative.
Where an implementation and this document disagree, this document is right and
the implementation has a bug. The reference implementation is Open Audio
Analyzer, and its conformance suite asserts every case in [§ 7](#7-conformance).

Two readings, one definition: a true peak minus the loudness of the same audio,
in loudness units.

| Reading | Is | Over | Undefined while |
|---|---|---|---|
| **ODR-S** | `TP(3 s) − LUFS-S` | the last 3 s | `LUFS-S ≤ −70 LUFS` |
| **ODR-I** | `TP Max − LUFS-I` | the programme | `LUFS-I` is undefined |

The arithmetic is that of the peak-to-loudness ratios of AES TD1004 (its `PSR`
and `PLR`). What this document adds is every choice that note leaves open — the
peak, the window, the gate, the statistic, the display — so that two
implementations of it cannot disagree by more than the tolerance in § 7.

**Licence.** The text of this specification is © the Open Audio Analyzer
contributors and is published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
so that it can be reproduced in another product's documentation. Implementing
it requires no licence at all. The reference implementation is GPL-3.0-or-later,
which binds its code and not the measurement.

## 1 Scope

This document defines two measures of the dynamics of a programme, for use in
metering, in delivery specifications and in offline analysis. It applies to any
audio for which ITU-R BS.1770-4 loudness and true peak are defined: any channel
count that standard assigns weights to, at any sample rate.

It does not define loudness, loudness range or true peak. Those are taken from
the documents in § 2 unchanged, and an implementation of this specification is
first an implementation of them.

## 2 Normative references

| | |
|---|---|
| **ITU-R BS.1770-4** | Algorithms to measure audio programme loudness and true-peak audio level. K-weighting, channel weighting, the gated integrated measure, and true peak by oversampling (Annex 2). |
| **EBU Tech 3341** | Loudness metering: the momentary (400 ms) and short-term (3 s) measures, and the conformance signals this document's own are modelled on. |
| **EBU R 128** | The −70 LUFS absolute gate this document reuses as its threshold of programme. |

Informative: **AES TD1004.1.15-10**, *Recommendation for Loudness of Audio
Streaming and Network File Playback*, which names PLR and PSR and is where the
arithmetic comes from.

## 3 Terms

- **LU** — loudness unit; one LU is one dB of the difference between two
  loudness values or between a loudness and a true peak, per BS.1770-4.
- **LUFS-S** — short-term loudness: the K-weighted, channel-weighted mean square
  over the last 3 s, ungated, per EBU Tech 3341.
- **LUFS-I** — integrated loudness: the gated measure of BS.1770-4 § 3, over the
  programme.
- **TP** — true peak, dBTP: the largest inter-sample magnitude found by
  oversampling per BS.1770-4 Annex 2, over all channels.
- **Absolute gate** — −70 LUFS, the level below which a 400 ms block is not
  programme (BS.1770-4 § 3; EBU R 128).
- **Programme** — everything measured since the last reset. A reset is the
  event that restarts the integrated measure; it restarts every quantity in
  this document at once.
- **Undefined** — a reading that does not exist yet or cannot exist. It shall
  be carried as *not a number* and displayed as a mark that is not a numeral
  (§ 6.2). It shall never be carried or displayed as zero.

## 4 ODR-S, the short-term reading

### 4.1 Definition

    ODR-S = TP(3 s) − LUFS-S

where `LUFS-S` is the short-term loudness of the last 3 s, and `TP(3 s)` is the
**highest true peak within the same 3 s** — the largest value reached, in any
channel, by the oversampled signal over the window `LUFS-S` averages.

### 4.2 The peak

The peak shall be true peak per BS.1770-4 Annex 2, oversampled at least 4× at
every sample rate. It shall not be sample peak: a limited master's inter-sample
overs are what a dynamics reading is for, and a ratio built on sample peak
understates them by up to 3 dB (§ 7, case 3).

The peak shall be taken over **every channel that carries programme** — the
loudest channel's peak — and not averaged across channels. It is the number a
peak ceiling is checked against, and it is the same number here.

### 4.3 The window

Both operands shall cover the same audio. The peak shall be the maximum over
the 3 s window `LUFS-S` is computed over, aligned with it to within one
loudness sub-block (10 ms; EBU Tech 3341 permits the window to advance in
steps of up to 100 ms). It shall not be a held or decaying meter reading, and
it shall not be the peak of a single block.

### 4.4 The gate

ODR-S is **undefined while `LUFS-S` is at or below the absolute gate**, −70
LUFS. Below that line there is no programme to describe, and an ungated
subtraction of two floored quantities reads a number — 0 LU for digital
silence on an implementation that floors dB at −144, about 8 LU for a noise
floor at −90 dBFS — that describes nothing a listener hears (§ 7, case 4).

ODR-S is also undefined until 3 s of signal have been measured, because
`LUFS-S` is.

### 4.5 Minimum

An implementation that reports on a programme after the fact **shall report
the minimum ODR-S** reached over the programme, taken over every window in
which ODR-S was defined. The minimum is the most limited three seconds of the
programme, and it is the statistic a floor on dynamics is checked against
(§ 6.3); ODR-I cannot serve, for the reason in § 5.3.

The minimum shall be sampled at least once per loudness sub-block (10 ms)
where the implementation measures offline. A live display that keeps a running
minimum may sample it at its own display rate, and shall say so if the two are
compared.

## 5 ODR-I, the integrated reading

### 5.1 Definition

    ODR-I = TP Max − LUFS-I

where `LUFS-I` is the gated integrated loudness of the programme, and `TP Max`
is the highest true peak reached, in any channel, since the last reset.

### 5.2 The gate

ODR-I is undefined for exactly as long as `LUFS-I` is — until at least one
400 ms block has cleared the absolute gate. Nothing else gates it.

### 5.3 The peak is not gated

`TP Max` counts every true peak since reset, **including one that fell in a
block the loudness gate excluded**. A transient in a passage the relative gate
throws out is still a peak a converter will see, and belongs in the ratio
(§ 7, case 5).

The consequence is that ODR-I alone cannot say how hard the loud passages of a
programme were limited: one transient in a quiet introduction rescues a
flattened chorus. That is not a defect in ODR-I, which describes the whole
programme's headroom; it is why § 4.5 exists.

## 6 Values, display and use

### 6.1 Unit and resolution

Both readings are in **LU**. They shall be displayed to a resolution of
**0.1 LU** and computed at a resolution at least ten times finer. Rounding
shall be to nearest.

### 6.2 Undefined readings

An undefined reading shall be carried as *not a number* (IEEE 754 NaN, or the
equivalent) and displayed as an em dash or another mark that cannot be read as
a numeral. It shall never be carried as zero, clamped to a floor, or held at
the last defined value. A serialised report shall write `null` or omit the
field.

### 6.3 Floors

A delivery specification may state a floor on ODR-I, on the minimum ODR-S, or
on both, in LU. A programme meets a floor when the reading is **greater than
or equal to** it. A floor is the only limit in a delivery specification that
runs upward, and a reading below it is a failure in the same sense as a true
peak over its ceiling. An undefined reading meets no floor and fails none; it
is reported as not measured.

No streaming platform publishes a floor. This document recommends none.

### 6.4 Naming

The readings shall be labelled **ODR-S** and **ODR-I**, and the minimum of
§ 4.5 as the minimum of ODR-S. An implementation that also offers the same
subtractions under another name (`PSR`, `PLR`, `DR-S`, `DR-I`) offers one
measurement twice, and shall not present the two as distinct.

### 6.5 Properties an implementation may rely on

- **Gain invariance.** Scaling the programme by a constant moves its peak and
  its loudness together; neither reading changes. A platform that normalises a
  master does not change its ODR.
- **Consistency.** Two implementations that agree with BS.1770-4 on `LUFS-S`,
  `LUFS-I` and `TP` to within the tolerances of EBU Tech 3341 agree with each
  other on ODR-S and ODR-I to within the sum of those tolerances.

## 7 Conformance

An implementation conforms to this specification when it produces the readings
below, within the stated tolerances, for the signals described. Every signal is
a sine or a sequence of sines and can be generated exactly; no recording is
needed. The expected values follow from BS.1770-4: a sine of peak amplitude
*A* has an RMS of *A*/√2, 3.0103 dB below its peak; a stereo pair sums to
+3.0103 dB; the K filter's gain at 1 kHz is +0.691 dB, which cancels the
−0.691 dB offset in the loudness equation.

| Case | Signal | Expected | Tolerance |
|---|---|---|---|
| **1** | Stereo 1 kHz sine, −23 dBFS peak, 5 s | ODR-S = 0.0 LU, ODR-I = 0.0 LU | ±0.1 LU |
| **2** | The same signal, mono | ODR-S = 3.01 LU, ODR-I = 3.01 LU | ±0.1 LU |
| **3** | Stereo 12 kHz sine at 48 kHz sample rate, full scale, phase offset 45°, 4 s. Every sample sits at −3.01 dBFS; the waveform reaches 0 dBFS between samples. | ODR-I − (sample peak max − LUFS-I) = 3.01 LU | ±0.2 LU |
| **4a** | Digital silence, 4 s | ODR-S undefined, ODR-I undefined | — |
| **4b** | then stereo 1 kHz sine at −80 dBFS, 4 s | ODR-S undefined | — |
| **4c** | then stereo 1 kHz sine at −60 dBFS, 4 s | ODR-S = 0.0 LU; ODR-I defined and within 0.3 LU of 0.0 | ±0.1 LU; ±0.3 LU |
| **5** | Stereo 1 kHz sine at −72 dBFS for 10 s with one full-scale sample in the left channel at 5 s, then stereo 1 kHz sine at −23 dBFS for 20 s | LUFS-I = −23.0; ODR-I = 23.0 LU | ±0.1 LU; ±1.0 LU |
| **6** | Case 1 pushed in blocks of 1 s, 512 frames and 377 frames | The same readings | ±0.001 LU between runs |
| **7** | Case 1 at 44.1, 48, 88.2, 96 and 192 kHz | The same readings | ±0.1 LU between rates |

Notes to the cases:

- **Case 1** is the identity at the heart of the definition: the crest of a
  sine, the second channel's contribution and the K filter's gain at 1 kHz
  cancel to nothing, so a reading of anything but zero is one of those three
  terms applied twice or not at all.
- **Case 3** is the one that distinguishes true peak from sample peak: on
  sample peak the reading is 3 dB low. The oversampled peak lands within a few
  hundredths of 0 dBTP; the tolerance covers the interpolation filter.
- **Case 4c** is not exactly zero for ODR-I because the 400 ms blocks that
  straddle the step from −80 to −60 dBFS land between the two levels, above
  the absolute gate and inside the relative gate, and pull the integrated
  reading a tenth or two under the tone. That is BS.1770-4 gating as specified.
- **Case 5** places a peak in a block the relative gate excludes: the click's
  block reads about −43 LUFS, above the absolute gate and ten LU under the
  relative gate the tone sets. The integrated reading is the tone's; the peak
  is the click's; ODR-I is the difference. The tolerance covers the
  oversampling filter's response to a single sample.
- **Cases 6 and 7** are inherited from the loudness conformance suite and are
  what this document means by "independent of the buffer" and "at any sample
  rate".

## 8 Relation to other measures (informative)

| Measure | Relation |
|---|---|
| **PSR / PLR** (AES TD1004) | The same arithmetic. This document fixes the peak (true, loudest channel), the window (aligned), the gate (−70 LUFS), the statistic (the minimum) and the display (§ 6), none of which the AES note specifies. |
| **TrueDyn** (Process.Audio Decibel) | Described by its maker as "the equivalent of peak over average, but in the LUFS world", displayed beside `LUFS-S` and true peak on one rim of its Super Meter and beside `LUFS-I` and true peak max on the other — which is this pair, by that description. It is not published as a definition, so no parity is claimed. |
| **DR** (Pleasurize Music Foundation / TT Dynamic Range Meter) | A different measurement: per channel, sample peak (the second highest) minus the RMS of the loudest 20 % of 3 s blocks, channels averaged, rounded to an integer. Sample peak, unweighted RMS and an integer result put it a generation behind; it is not ODR and shall not be labelled as such. |
| **LRA** (EBU Tech 3342) | How far the programme's short-term loudness *moves*, between its 10th and 95th percentiles. It says nothing about limiting: a programme can be crushed flat with a wide LRA, or breathe with a narrow one. |
| **Crest factor** | Sample peak minus RMS over one block, unweighted. A property of a waveform, not of a programme. |

## Annex A — Reading the numbers (informative)

This annex is guidance, not definition. Nothing in it changes what an
implementation computes, and it may be revised without a version bump. It
exists because a reading without a sense of scale is a number, not a
measurement: somebody watching `ODR-I 6.2` needs to know whether that is a
choice, a casualty or a delivery problem.

### A.1 What ODR-I predicts

Loudness normalisation is one gain: `target − LUFS-I`. Apply it and the
programme's true peak lands at `TP Max + target − LUFS-I`, which is

    target + ODR-I

exactly. That makes ODR-I a prediction, not a score. A platform that
normalises to −14 LUFS under a −1 dBTP ceiling plays a programme at its
target only while `ODR-I ≤ 13 LU`. Below 13, the master was limited harder
than the platform asks: it is turned down to target, and nothing on playback
restores the transients. Above 13, the platform cannot raise the programme to
target without clipping, so on a platform that will not limit — which is most
of them — it plays quieter by the excess, with its dynamics intact.

### A.2 Bands

The anchors below are arithmetic on published delivery levels, and anyone can
recompute them. The descriptions are editorial, and genre-dependent in a way
no number can be: 7 LU is a choice in a techno track and a casualty in a
string quartet.

| ODR-I | Reads as | Anchor |
|---|---|---|
| 0 – 5 LU | Flat. The limiter's ceiling is the loudness. | 0.0 LU is a full-scale stereo sine (§ 7, case 1) |
| 5 – 8 LU | Crushed. The late loudness war. | −6 LUFS at −0.1 dBTP → 5.9 LU |
| 8 – 10 LU | Loud. | −9 LUFS at −0.3 dBTP, a loud CD → 8.7 LU |
| 10 – 13 LU | Balanced. Nothing is lost at −14 LUFS. | −14 LUFS at −1 dBTP → 13.0 LU, the most a −14 platform can play at its target |
| 13 – 16 LU | Dynamic. Plays below target on −14 platforms, transients intact. | −16 LUFS at −1 dBTP → 15.0 LU |
| over 16 LU | Wide. Ordinary for classical, jazz, film and broadcast. | −23 LUFS at −1 dBTP (EBU R 128) → 22.0 LU |

How far the loudness itself moves is LRA's question, not this document's
(§ 8): a programme can sit in one band for an hour or visit three of them.

The reference implementation prints the band's name after ODR-I in its text
report — the word for the person reading a delivery email, beside the number
a script gates on, which its JSON carries bare.

### A.3 The minimum ODR-S

ODR-I describes the whole programme; the minimum ODR-S (§ 4.5) describes its
most limited three seconds, which is where overcompression lives (§ 5.3). One
published threshold exists for this arithmetic: Ian Shepherd, whose Dynameter
displays the same subtraction as `PSR`, recommends going no lower than 8 LU in
the loudest passage, in any genre — less than that "will often sound crushed".
This document still recommends no floor (§ 6.3); a delivery specification that
wants one has a citable number. The reference implementation ships it as a
built-in delivery target, *Dynamic master* — the one built-in that is a
recommendation rather than a platform's published numbers, and labelled as
such.

The gap between the two readings is a diagnosis of its own. A minimum ODR-S
well below ODR-I means either that the loudest section is limited far harder
than the rest, or that a single transient is holding ODR-I up (§ 5.3). Either
way, the minimum is the honest figure for how hard the master was pushed.

### A.4 Scales that look like this one

The Dynamic Range Database (dr.loudness-war.info) colours its `DR` badges as
a gradient from red at DR7 to green at DR14. Those thresholds do not
transfer: `DR` is a different measurement (§ 8) that reads lower than ODR-I
on the same master, usually by a few LU and by more the more dynamic the
material, and the offset is not a constant. What does transfer is the idea —
one number, coloured between two named endpoints — and the reference
implementation colours a reading against the floor in the user's delivery
target rather than against a fixed opinion of what music should be.

## 9 Revision history

An annex marked *informative* is guidance, not definition, and may be
revised without a version bump; §§ 1–7 change only with one.

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-08-28 | First publication. The readings were published by Open Audio Analyzer as `PSR` / `PLR` and `DR-S` / `DR-I` through 0.14.0 with the same arithmetic; § 4.4 (the gate) and § 4.5 (the minimum) are new with this version. Annex A (informative) was added the day of publication. |
