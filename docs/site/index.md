# Open Audio Analyzer

Open Audio Analyzer is a modular metering suite: a canvas of resizable meter
modules — loudness, true peak, VU, spectrum, spectrogram, oscilloscope, phase
scope, histogram
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

Those numbers are held against the **EBU Tech 3341 and 3342 conformance cases**
on Linux, macOS and Windows on every push, from signals the suite generates
itself. A red conformance run is a red build. The spectrum is held against a
sine of known amplitude on a bin centre in the same way.

The **official vector files** — the EBU Loudness Test Set and the compliance
material of Report ITU-R BS.2217 — are run by hand, because 811 MB nobody may
redistribute cannot be a build step. All 112 cases pass, and running them found
two defects that generated signals could not express.

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

Fourteen module kinds, arranged on a twenty-four by sixteen grid across as many
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
| **Histogram** | Short-term loudness over time, banded up to momentary, against the delivery target. `Smoothing` averages both bands over a centred window of 0.5, 1 or 2 seconds, or draws every 100 ms column as measured. |
| **Loudness Distribution** | How often the programme sat at each loudness, bracketed between the two percentiles LRA is the distance between, with LRA printed on the bracket. `Scale` fits the loudness axis to the programme — every occupied bin, the gated range and the target, rounded out to whole ticks — so a distribution that lives in eight decibels is drawn across the module instead of into a fifth of it; `Full range` draws all sixty published decibels, which is the axis to pick when two of these are being compared side by side. |
| **Spectrum Analyzer** | 512 log-spaced bands from a 4096-point Hann window, zero-padded to a 16384-point transform. Drawn tilted — 0 to 6 dB per octave about 1 kHz, 4.5 by default — so a mix reads as roughly flat and what is left to see is the deviation. |
| **Spectrogram** | The same transform over time, with level as colour. `Colour` chooses which colours. `Skin` is the module's own ground into the accent hue into the warn hue, brightness rising the whole way, which is what makes a one-hue spectrogram legible and is what the module opens on. `Full RGB` is the spectrogram rainbow — indigo, blue, cyan, green, yellow, orange, red, white — which separates far more steps of level than one hue can, at the cost of reading as more precise than the measurement behind it. Both ramps map the **level**, not the frequency: the frequency is already up the y axis, so a hue per row would say nothing the axis does not and would leave the level with only brightness to be read from. `Full RGB` brings its own near-black ground with it, so on a light skin the module stops matching the interface around it. Nothing measured changes either way — switching re-paints the history already on screen without moving a cell. |
| **Oscilloscope** | The waveform itself, a lane per channel or both channels around one centre line. Free-running, with a time base from 5 ms to 5 seconds — triggered on a rising zero crossing below 200 ms so a periodic signal stands still, rolling above it — or locked to the DAW's tempo, where the width is a musical division from 4 bars to 1/32, straight, triplet or dotted, and the window sits on the bar grid so a kick lands in the same place every pass. `Trigger: Transient` replaces both with a sweep: the display waits for the signal to rise through a level you set, draws forward across the width once from that sample, and holds what it caught until the next crossing — which is how you look at the attack of one drum hit rather than at a picture that moves every pass. The threshold and the vertical zoom, 1x to 32x for material that does not reach full scale, are sliders along the bottom of the module; the threshold is drawn across the lane at the height it is set to. `AUTO` beside it hands the threshold to the audio: it follows the loudest transient of the last few seconds, six decibels under the peak so the sweep starts while the attack is still rising, and unchecking the box keeps the number it found. Full-scale samples are drawn in the over colour whatever the zoom is set to. `Colour: Full RGB` colours each column by the **balance** of the audio in it — red is its bass, green its mids, blue its highs, split at 200 Hz and 2 kHz — so a kick is red, a hat is blue, and something with all three in it is white. The balance is taken in decibels relative to the loudest of the three bands rather than in power, which is what stops every piece of music being red, and it comes from the spectrum the engine measured for the same block the column's samples came from. It is then kept *with* the column, so a beat four seconds ago still carries the colour it had rather than being repainted by whatever is playing now. Both channels are drawn through the one palette, so a colour here names a set of frequencies and never a channel; a block whose source published no spectrum keeps the accent, because nothing is known about its balance. |
| **Phase Scope** | The goniometer, from the raw stereo sample stream. |
| **Stereo Cloud** | Stereo position per frequency band. Needs two channels; on a mono source it says so. |

Every loudness display marks the delivery target the same way: whatever stands
above it is drawn in red, cut at the target itself rather than coloured by a
verdict on the whole bar. Red is the one mark for "past the number you set" —
the LUFS Meter's bars, the Super Meter's arcs, the Histogram and the Loudness
Distribution all use it, so a glance at any of them answers the same question
the same way. What it tells you is *how much* of the reading is over, which the
Histogram and the Loudness Distribution show as an area.

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

The two find each other three ways, and the order is the order they cost you.
The tablet lists whatever is publishing on the network. Failing that, the
sending machine shows a **pairing code** — the code button beside PUBLISH in
its status bar, or Settings → Publish — and the tablet reads it with its camera
under Scan a QR code, on the screen it opens with. Failing both, you type the
address Settings → Publish prints. The second and third exist because multicast is the first thing a guest
or venue network blocks, and a feature that only worked on a network you
control would not work in the rooms it is for. Scanning needs a camera, so it
is offered on Android, iPadOS and macOS and not on Windows or Linux. A code
carries an address and nothing else: a display that scans one can still only
watch.

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
