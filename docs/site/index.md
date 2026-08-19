# Open Audio Analyzer

Open Audio Analyzer is a modular metering suite: a canvas of resizable meter
modules — loudness, true peak, VU, spectrum, spectrogram, phase scope, histogram
— organised into tabs, driven by presets, delivery targets and skins, with
offline file analysis and a companion display that mirrors a tab to a tablet
over Wi-Fi.

It is free software, and it is a free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by process.audio, whose
modular canvas is the best interaction model anybody has found for this problem.
The measurement work, the architecture and the visual language are our own, and
where Open Audio Analyzer cannot honestly match Decibel it says so rather than
approximating.

[Install it](install.html) · [What every number means](metrics.html) ·
[Source on GitHub](https://github.com/JonasGrunau/open_audio_analyzer)

## What it measures

Loudness follows **EBU R 128** and **ITU-R BS.1770-4**: momentary, short-term
and integrated LUFS with the two-stage K-weighting and the gated integration,
loudness range as the difference of the 10th and 95th percentiles of the gated
short-term distribution, and true peak by four-times oversampling rather than
sample peak.

Those numbers are held against the **EBU Tech 3341 and 3342 conformance
vectors** on Linux, macOS and Windows on every push. A red conformance run is a
red build. The spectrum is held against a sine of known amplitude on a bin
centre in the same way.

[The metrics reference](metrics.html) gives the definition, the standard and
the current availability of every quantity Open Audio Analyzer reports.

## What it will not do

**Open Audio Analyzer does not invent a measurement.** A quantity the engine has
not computed is drawn as an em dash, exported as `null`, and written to CSV as
an empty cell. It is never a zero — zero is a legitimate reading for
correlation, for stereo balance and for several dB quantities, so it cannot
double as "no data". A metering tool that fills gaps with plausible numbers is
worse than one that admits them.

## The canvas

Twelve module kinds, arranged on a twenty-four by sixteen grid across as many
tabs as you like.

| | |
| --- | --- |
| **Number Box** | One quantity, large. Any metric. |
| **LUFS Meter** | Momentary, short-term and integrated against a target band. |
| **Digital Meter** | Per-channel peak and RMS with a clip indicator. |
| **Super Meter** | The loudness family as concentric arcs. |
| **VU Meter** | A real second-order movement, not a one-pole approximation. |
| **Alert Meter** | One quantity, its worst case, and whether it passed. |
| **Validator** | Every delivery criterion and a verdict per line. |
| **Histogram** | Short-term loudness over time, banded up to momentary, against the delivery target. |
| **Loudness Distribution** | How often the programme sat at each loudness, with the two percentiles LRA is the distance between. |
| **Spectrum Analyzer** | 512 log-spaced bands from a 4096-point Hann window, zero-padded to a 16384-point transform. |
| **Spectrogram** | The same transform over time. |
| **Phase Scope** | The goniometer, from the raw stereo sample stream. |
| **Stereo Cloud** | Stereo position per frequency band. Needs two channels; on a mono source it says so. |

Modules are added, moved, resized, duplicated and deleted, with undo. A module
that has nowhere to go does not move: placement is a predicate, not a
negotiation, so nothing is ever rearranged that you did not rearrange.

Everything you set up is remembered — the layout, the delivery target, the skin
and the capture device — and reopens with the window.

## Beyond the desktop

**Files.** Drop one on the analysis panel, or run the `oaa` command-line
analyser. Both push the decoded blocks through the same measurement path a
capture device drives, so an offline reading and a live reading of the same
audio are identical rather than close. With `--target`, the CLI's exit code is
the product: a master that misses its delivery spec fails your pipeline instead
of shipping. See [Analysing files](analysing-files.html).

**A tablet.** A second machine on the same network can mirror the canvas,
drawing the same modules with the same painters from measurements arriving over
a socket. The protocol is [documented normatively](wire.html) and is MIT, so a
third-party display does not have to be GPL to speak it.

**A DAW.** A headless VST3 and Audio Unit plugin measures what your host is
playing and streams it — with the transport — to the application. The plugin
measures; the app displays. That split is what stops there being two
implementations of every meter, drifting apart.

## Licensing

Split on purpose. The engine, the domain model and the wire protocol are
**MIT**, because a measurement tool needs to be embeddable and auditable. The
application, the design system and the CLI are **GPL-3.0-or-later**, because a
free clone of a paid product should not be trivially re-closable. The plugin is
**AGPL-3.0-or-later**, because it links JUCE.

MIT is one-way compatible with GPL, so the combination composes cleanly.
