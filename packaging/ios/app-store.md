# App Store listing

The text of the iPad listing, kept here so that it moves with the build it
describes. Nothing reads this file: it is copied into App Store Connect by
hand, once per listing change. Every claim in it is checkable against
`README.md` or `docs/METRICS.md` — a store page that overstates a metering
tool is the same defect as a meter that reads high.

Field limits are Apple's, counted as characters and stated beside each field so
that an edit does not have to be measured twice.

---

## Name — 30 max

```
Open Audio Analyzer
```

19 characters. `CFBundleDisplayName` is **Audio Analyzer**, which is what the
home screen shows; the two differ on purpose — the store name is the product,
the icon label is what fits under an icon (see the note in
`packaging/AGENTS.md`).

## Subtitle — 30 max

```
LUFS, true peak and spectrum
```

28 characters.

## Promotional text — 170 max

Editable without a new build, so this is where a release announcement goes.

```
Loudness and true peak are held against the EBU R 128 conformance cases on every commit. Free, open source, no account — and it doubles as a second screen for the desktop app.
```

175 characters — over the limit. Use this one:

```
Loudness and true peak are held against the EBU R 128 conformance cases on every commit. Free, open source, no account, and a second screen for the desktop app.
```

160 characters.

## Keywords — 100 max, comma separated, no spaces

Words already in the name and subtitle are indexed, so `audio`, `analyzer`,
`lufs`, `spectrum` and `true peak` would be wasted here — except that `lufs`
and `spectrum` are worth their characters as exact-match singles and are kept.

```
lufs,loudness,meter,metering,spectrum,mastering,true peak,r128,ebu,dbtp,vu,rms,broadcast,podcast
```

96 characters.

## Description — 4000 max

```
Open Audio Analyzer is a free and open-source loudness and spectrum analyzer: a canvas of meter modules you arrange yourself, driven by presets, delivery targets and skins.

FOURTEEN MODULES, AND EVERY ONE MEASURES SOMETHING

• LUFS Meter — momentary and short-term loudness as bars, integrated as a line
• Super Meter — momentary, short-term and integrated as three concentric arcs
• Digital Meter — sample peak and RMS, per channel, up to 7.1
• VU Meter — a needle on the movement the engine models, with its 0 VU reference printed on the face
• Number Box — any single measurement, large
• Alert Meter — one measurement watched, with the worst it has been latched
• Validator — the delivery decision, as a table
• Histogram — loudness against time: how the programme moved, and when it was over target
• Loudness Distribution — how much of the programme sat at each loudness, bracketed between the percentiles the range spans
• Spectrum Analyzer — level against frequency, log-spaced and tilted so a mix reads roughly flat, with peak hold
• Spectrogram — frequency against time, level as colour
• Oscilloscope — the waveform itself: triggered at scope speeds, rolling, or locked to a DAW's bar grid
• Phase Scope — a goniometer, rotated so mono stands upright
• Stereo Cloud — where each frequency sits in the stereo image, accumulated over time

MEASUREMENT YOU CAN CHECK

Momentary, short-term and integrated loudness, loudness range, true peak, sample peak, peak-to-loudness ratio and correlation — computed to ITU-R BS.1770-4 and EBU R 128. K-weighting coefficients are derived at the actual sample rate rather than read from a 48 kHz table, gating is R 128's 400 ms blocks at 75% overlap, and true peak is oversampled per BS.1770-4 Annex 2.

Loudness and true peak are held against the EBU Tech 3341 and 3342 conformance cases, and the spectrum against a sine of known amplitude, on every commit. The whole engine is public, so what a number means is something you can read rather than trust.

Anything this build cannot measure reads as an em dash, never as a zero: zero is a legitimate reading for correlation and for several decibel quantities, and a tool that fills a gap with a plausible number is worse than one that admits it.

DELIVERY TARGETS, AND A VERDICT

Six built in — −14 LUFS streaming, a loud streaming preset at −11, podcast at −16, EBU R 128, ATSC A/85 and CD — or write your own. The Validator turns integrated loudness, true peak and loudness range into one answer: ready to deliver, or not, and which line failed and by how much.

A SECOND SCREEN FOR THE STUDIO

Turn on PUBLISH in the desktop application — macOS, Windows or Linux — and this iPad draws that machine's meters over your own Wi-Fi: the same modules, the same painters, the same numbers, because both ends run the same code. It finds the machine by itself, reads a pairing code off its screen, or takes an address you type, because a venue's network blocks the first one.

On the desktop, a headless VST3 and Audio Unit plugin meters what your DAW is playing and streams it to the app, so what arrives on the iPad can be the mix as the DAW hears it, with the transport position beside it.

ON THE IPAD ITSELF

Meter the input iPadOS is routing, or open a file and read the report: integrated loudness, range, true peak, and the same delivery verdict.

MADE YOURS

Arrange modules on a grid and keep tabs of them. Save presets. Edit all thirteen colour roles of a skin in the app, each with its contrast ratio printed beside it. What you set up is remembered, as plain JSON you can read.

FREE, AND ACTUALLY FREE

No account, no subscription, no adverts, no analytics and no telemetry. The only network traffic is the meters you ask it to draw from another machine on your own network. Audio is measured and discarded — never recorded, stored or sent anywhere.

Licensed GPL-3.0-or-later, engine included. Source, documentation and the desktop downloads: open-audio-analyzer.com
```

## What's New — 4000 max

For 0.10.0. Written for somebody deciding whether to update.

```
• A skin editor. All thirteen colour roles, with a picker on each and the contrast ratio of every one printed beside it — and the canvas repaints as you drag, including on a tablet mirroring the session.
• The Spectrogram and the Oscilloscope can be drawn in full colour. On the Spectrogram that colours the level; on the Oscilloscope it colours the balance of bass, mids and highs, so a kick is red and a hat is blue. Off by default in both, and nothing measured changes at either setting.
• The VU Meter marks where the needle reached, and prints both its deflection and which dBFS level reads as 0 VU.
• Delivery targets can be reset to the built-in six.
```

---

## The rest of the submission

| Field | Value |
|---|---|
| Primary category | Music |
| Secondary category | Utilities |
| Age rating | 4+ |
| Price | Free |
| Devices | iPad only — `TARGETED_DEVICE_FAMILY = 2`, so no iPhone screenshots are required |
| Screenshots | Three, 13-inch iPad, landscape, 2752 × 2064, committed in `packaging/ios/screenshots/`. Retaken with `sh packaging/ios/screenshots.sh` |
| Support URL | https://open-audio-analyzer.com/docs |
| Marketing URL | https://open-audio-analyzer.com |
| Privacy policy URL | https://open-audio-analyzer.com/privacy — mandatory. See below |
| Copyright | The year and the author |
| Encryption | Declared in `ios/Runner/Info.plist` — `ITSAppUsesNonExemptEncryption` is false, so App Store Connect does not ask |
| App privacy | **No data collected.** No account, no analytics, no third-party SDK. The microphone is used to measure and is never recorded or transmitted; the local network carries measurements between two copies of this application only |

**The privacy policy URL is <https://open-audio-analyzer.com/privacy>**, which
App Store Connect requires and will not accept a listing without. It is written
in `docs/site/privacy.md` and served by `website/src/pages/privacy.astro` — the
document lives beside the code so that a change to what the application does
with a microphone, a camera or a socket is a change to the page in the same
commit. It came out longer than the three sentences this note once predicted,
because a metering tool asks for three permissions and each one is worth
accounting for separately — and because the display link has no encryption and
no authentication, which is the one thing on that page a reader should be told
rather than left to discover.

The **App privacy** row above is the summary; the page is the long form, and the
two must not drift. Its *Apple's App Privacy answers* section is written as the
same table App Store Connect asks you to fill in, so the answers can be copied
across rather than re-derived.

### Screenshot captions

App Store Connect does not caption screenshots; these are the order and the
argument each one makes, so a later regeneration keeps the sequence.

| File | What it argues |
|---|---|
| `01-loudness.png` | This is a meter bridge, and it is measuring real music right now |
| `02-spectrum.png` | Frequency, time and the stereo image, on a second tab |
| `03-loudness-daylight.png` | The same bridge, at the same second of the same track, in the light skin |

All three are the canvas and nothing else, because the script that takes them
posts no pointer event: the tab is a key and the skin is a settings file, and
neither can open a panel. The delivery-target, module-library and
remote-display pictures that used to follow were reached by clicks at
coordinates read off a finished screenshot, which drifted twice and pressed the
wrong controls without anything failing. A panel comes back into the set the
day there is a launch option that opens it in a release build; `--open-panel`
is debug-only, and a store screenshot is of the build that ships.

The settings panel would be the obvious candidate and is not one even then: on
an iPad it explains System Output in terms of macOS 14.2, VB-Cable and
PulseAudio, its delivery target row names five streaming services, and Name and
port shows whatever the device is called. All three are worth fixing in the
application; none of them is worth publishing first.
