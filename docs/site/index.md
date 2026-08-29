# Open Audio Analyzer

Open Audio Analyzer is a canvas of meter modules you arrange yourself —
loudness, true peak, VU, spectrum, spectrogram, oscilloscope, phase scope,
histogram — across as many tabs as you want, saved as presets, measured against
delivery targets and coloured by skins. It analyses files as well as live audio,
and it mirrors a tab to a tablet over Wi-Fi.

It is free software, and where it cannot honestly measure something it says so:
a dash rather than an approximation.

[Install it](install.html) · [What every number means](metrics.html) ·
[Source on GitHub](https://github.com/JonasGrunau/open_audio_analyzer)

## What it measures

Loudness follows **EBU R 128** and **ITU-R BS.1770-4**: momentary, short-term
and integrated LUFS, loudness range, and true peak by oversampling rather than
sample peak.

Those numbers are held against the **EBU Tech 3341 and 3342 conformance cases**
on Linux, macOS and Windows before any change ships, and against the official
EBU and ITU vector files by hand, where all 112 cases pass. Running that set
found two defects that generated signals could not express.

Dynamics are **Open Dynamic Range** — `ODR-S` over the last three seconds and
`ODR-I` over the programme, true peak against loudness — a measure this
project defines itself, to the operand, because no standard body defines one.
[The ODR specification](odr.html) is the definition and its conformance cases;
[the metrics reference](metrics.html) gives the definition, the standard and
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
| **Number Box** | One quantity, large. Any metric, with a low wash of its verdict colour rising from the foot of the panel — and no wash at all where the reading is a dash, because a light is a verdict and nobody measured anything. |
| **LUFS Meter** | Momentary, short-term and integrated against a target band. |
| **Digital Meter** | Per-channel peak and RMS with a clip indicator. |
| **Super Meter** | Loudness from the left and Open Dynamic Range continuing from its tip to the true peak, on one half-gauge — the dark rest of a ring is its true-peak headroom. LUFS-S and ODR-S over LUFS-I, ODR-I and true peak in the centre. |
| **VU Meter** | A needle, with the ballistics of the real thing. |
| **Alert Meter** | One quantity and the worst it reached, which is the number the module prints — big, under the metric's own name, held until the engine is reset. The panel's own light is that same verdict at a hundred times the area — a wash off the left edge in the latched state's colour, so a red module across the room is one whose worst moment went over the line, and the digits on it are that moment. A module that has caught nothing is not lit at all. A quantity the engine already accumulates over the programme — LUFS-I, LRA, TP Max, Peak Max, ODR-I — is **read rather than latched**: the engine is doing the holding, and the extremum of a converging estimator is a property of how it converged rather than of the audio. `Delta` prints how far that worst case is from the target rather than the reading itself, signed, in the unit of the difference — `dB` from a true-peak ceiling and `LU` from a loudness target, never the metric's own — and is offered only where the active target actually draws that line: loudness, true peak and LRA always, the two ODR floors only under a target that states them, because a distance from a floor nobody stated is a number nobody measured. |
| **Validator** | Every delivery criterion and a verdict per line — three, plus one for each dynamics floor the target sets. The ODR-S line judges the lowest reading since the last reset. `Checks` picks which of them this module judges: the rows are ticked and unticked in a menu that stays open, and a criterion switched off leaves the verdict as well as the table — so one Validator can watch loudness while another beside it watches dynamics, and neither reports a failure nobody in the room cares about. A module with every check switched off says NOTHING CHECKED, because a table that compared nothing has not passed. |
| **Histogram** | Short-term loudness over elapsed time, banded up to momentary — the band tinted by how far over target it stands — with the whole recording in an overview strip along the floor. That strip is the control: **drag the frame on it** and the plot scrolls back through the programme, **scroll, pinch or wheel over it** and the frame resizes, which is the plot's zoom. Dragging the frame back against the right-hand edge re-attaches it to the newest reading. `Smoothing` averages both bands over a centred window of 0.5, 1 or 2 seconds, or draws every 50 ms column as measured. |
| **Loudness Distribution** | How often the programme sat at each loudness, bracketed between the two percentiles LRA is the distance between, with LRA printed on the bracket. `Scale` fits the loudness axis to the programme — every occupied bin, the gated range and the target, rounded out to whole ticks — so a distribution that lives in eight decibels is drawn across the module instead of into a fifth of it; `Full range` draws all sixty published decibels, which is the axis to pick when two of these are being compared side by side. |
| **Spectrum Analyzer** | 512 bands, spaced the way you hear. Drawn tilted — 0 to 6 dB per octave about 1 kHz, 4.5 by default — so a mix reads as roughly flat and what is left to see is the deviation. `Source` chooses which signal the bands are measured on: `All` channels, or the front pair's `Left`, `Right`, `Mid` or `Side`, each with its own peak hold. `Range` chooses how far below full scale the plot reaches — 60, 90 or 120 dB, 90 by default, the values Pro-Q uses — and the plot prints it in its corner beside the tilt. Click or tap the plot for a **cursor** — a line at that frequency, with the frequency, the level there, its peak hold and the level in dB(A) beside it; drag it, or tap the line — or click anywhere away from the module — to dismiss it. |
| **Spectrogram** | Frequency against time, with level as colour. `Source` is the analyser's — `All`, `Left`, `Right`, `Mid` or `Side` — and changing it clears the record, because a picture that is one signal on its left half and another on its right is a measurement nobody took. `Colour` chooses which colours. `Skin` is the module's own colours — its ground rising through the accent into the warning colour — and is what it opens on. `Full RGB` is the spectrogram rainbow — indigo, blue, cyan, green, yellow, orange, red, white — which separates far more steps of level than one hue can, at the cost of reading as more precise than the measurement behind it, and it brings its own near-black ground, so on a light skin the module stops matching the interface around it. Both ramps map the **level**, not the frequency; the frequency is already up the y axis. Nothing measured changes either way — switching re-paints the history already on screen without moving a cell. |
| **Oscilloscope** | The waveform itself, a lane per channel or both channels around one centre line. Free-running, with a time base from 5 ms to 5 seconds — triggered on a rising zero crossing below 200 ms so a periodic signal stands still, rolling above it — or locked to the DAW's tempo, where the width is a musical division from 4 bars to 1/32, straight, triplet or dotted, and the window sits on the bar grid so a kick lands in the same place every pass. `Trigger: Transient` replaces both with a sweep: the display waits for the signal to rise through a level you set, draws forward across the width once from that sample, and holds what it caught until the next crossing — which is how you look at the attack of one drum hit rather than at a picture that moves every pass. The threshold and the vertical zoom, 1x to 32x for material that does not reach full scale, are sliders along the bottom of the module; the threshold is drawn across the lane at the height it is set to, and the time base is printed at the right-hand end of the same row. With both channels around one centre line, the `L R` legend at the left of that row says which of them is drawn in front — the one named first, in the brighter ink — and clicking it swaps the pair, which is how you read the channel that is currently underneath. `AUTO` beside it hands the threshold to the audio: it follows the loudest transient of the last few seconds, six decibels under the peak so the sweep starts while the attack is still rising, and unchecking the box keeps the number it found. Full-scale samples are drawn in the over colour whatever the zoom is set to. `Colour: Full RGB` colours each column by the **balance** of the audio in it — red is its bass, green its mids, blue its highs, split at 200 Hz and 2 kHz — so a kick is red, a hat is blue, and something with all three in it is white. The colour is kept *with* the column, so a beat four seconds ago still carries the colour it had rather than being repainted by whatever is playing now. Both channels are drawn through the one palette, so a colour here names a set of frequencies and never a channel. |
| **Phase Scope** | The goniometer, from the raw stereo sample stream, its axes lettered, with balance and correlation as markers on its frame — correlation turning to the warning colour below zero, where a mix is losing itself in mono. Needs two channels; on a mono source it says so. |
| **Stereo Cloud** | Stereo position per frequency band over the last two seconds, as marks that are brighter and larger the louder the band and fade with age, placed at the pan pot's angle so a source sits where it was panned. Needs two channels; on a mono source it says so. |

Every loudness display marks the delivery target the same way: whatever stands
above it is drawn in red, cut at the target itself rather than coloured by a
verdict on the whole bar. Red is the one mark for "past the number you set" —
the LUFS Meter's bars, the Histogram and the Loudness Distribution all use it,
so a glance at any of them answers the same question the same way. What it
tells you is *how much* of the reading is over, which the Histogram and the
Loudness Distribution show as an area. The Super Meter marks the target with a
red tick on each ring and leaves its arcs their own colour past it: the verdict
there is the numbers in the centre, and how far past the tick an arc reaches is
the miss.

Modules are added, moved, resized, duplicated and deleted, with undo. A module
that has nowhere to go does not move, and nothing is ever rearranged that you
did not rearrange yourself.

Everything you set up is remembered — the layout, the delivery target, the skin
and the capture device — and reopens with the window.

## Beyond the desktop

**Files.** Drop one on the analysis panel, or run the `oaa` command-line
analyser. Both measure the same way live audio is measured, so a reading off a
file and a reading off the desk are identical rather than close. With
`--target`, the CLI's exit code is the product: a master that misses its
delivery spec fails your pipeline instead of shipping. See
[Analysing files](analysing-files.html).

**A tablet.** A second machine on the same network draws the same modules from
the same measurements, arriving over a socket. The protocol is
[documented normatively](wire.html), which is what lets a display nobody here
wrote speak it: a specification is not a program, and there are already three
implementations of this one that were not written against each other.

The two find each other three ways, cheapest first. The tablet lists whatever is
publishing on the network. Failing that, the sending machine shows a **pairing
code** — the code button beside PUBLISH in its menu bar, or Settings → Publish —
and the tablet reads it with its camera under Scan a QR code, on the screen it
opens with. Failing both, you type the address Settings → Publish prints. The
second and third exist because multicast is the first thing a guest or venue
network blocks. Scanning needs a camera, so it is offered on Android, iPadOS and
macOS and not on Windows or Linux. A code carries an address and nothing else: a
display that scans one can still only watch.

**A DAW.** A headless VST3 and Audio Unit plugin measures what your host is
playing and streams it, with the transport, to the application. The plugin
measures and the app draws, which is what stops there being two implementations
of every meter to drift apart. A connected plugin is an entry in the app's
source picker, named after the host it is running in, so it is chosen and left
the way an audio interface is — and the first one to connect chooses itself,
because inserting it is what choosing it means.

## Licensing

**GPL-3.0-or-later**, all of it, because a free clone of a paid product should
not be re-closable — and that argument covers the engine and the wire protocol
as much as the application. The plugin is **AGPL-3.0-or-later**, because it
links JUCE. The engine, the domain model and the wire protocol were MIT through
0.13.0.

This is not a licence against commercial use, and no free-software licence is.
You may sell copies, charge for support, and ship Open Audio Analyzer inside
something you sell. What copyleft forbids is a proprietary fork: a modified
version you distribute has to carry its source under the same terms.
