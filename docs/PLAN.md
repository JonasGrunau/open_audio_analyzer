# Open Audio Analyzer — a free, open-source loudness & spectrum analyzer

> **This is the plan as it was approved, kept as the record of intent. It is
> written in the future tense and most of it has happened.** Phases 0–8 are
> done; `README.md`'s Roadmap is the live status and `CHANGELOG.md` is what
> actually shipped.
>
> Where the build and this document disagree, **the build is what exists** — but
> a divergence is a decision somebody made, so it is recorded here rather than
> left to be discovered. The ones that matter:
>
> | This document says | What was built | Why |
> |---|---|---|
> | `plugin/` is GPL-3.0, built on JUCE under its GPL option | **AGPL-3.0-or-later** | JUCE 7 and 8 are AGPLv3-or-commercial; only JUCE 6 offered GPLv3. See `plugin/AGENTS.md`. |
> | VST3 SDK is a second copyleft dependency | MIT, vendored inside JUCE | Steinberg relicensed it. No separate SDK checkout. |
> | LRA histogram at 0.1 LU per bin | **0.01 LU**, 8000 bins | An order of magnitude inside the ±0.1 LU the standard asks for, at the same O(1) cost. |
> | True peak 2× at ≥96 kHz | **4× at every rate** | 2× needs a second filter design to be correct, and 4× is never *less* accurate. See `docs/METRICS.md`. |
> | FFT sizes 1024–8192, A/C/Z weighting | **4096 points, unweighted** | One transform serves the analyser, spectrogram and stereo cloud. Selectable size and weighting are not built. |
> | `engine/test/` C unit tests, `cmake --build engine/build && ctest` | The engine is tested **through FFI** from `packages/oaa_engine/test/` | The tests need no C runner, and one suite that CI already runs beats two. |
> | `tool/conformance.dart` | `packages/oaa_engine/test/conformance_test.dart` | Same job, inside the suite that gates every push. |
> | Cross-check against `libebur128` as an oracle | Not done | The EBU Tech 3341/3342 cases are generated and asserted directly, with sample-rate and block-size independence on top. |
> | BS.2217 WAV vectors in CI | **Run locally, never in CI** — `packages/oaa_engine/test/vectors_test.dart`, over both the EBU set and the ITU's, 112 cases, skipping unless `OAA_VECTORS` / `OAA_VECTORS_ITU` point at a copy | 811 MB that may not be redistributed here, and fetching it in CI would make the one suite that must never be flaky depend on the network. Running it found two defects the generated cases could not express; see `docs/METRICS.md`. |
> | Elapsed & Timecode LUFS modes arrive with the plugin in Phase 7 | **Not built.** The plugin ships and delivers the playhead, the timecode and a discontinuity flag; no module offers the modes. | Tying an integration window to the transport means restarting it when the playhead moves, and that command travels app→plugin: it needs a control frame, and so **wire protocol 2**. |
> | `third_party/stb_vorbis`, `tool/` | Neither exists | Ogg is not decoded; see the README's gaps. |
> | `engine/` has a `CMakeLists.txt` "only for the C test runner and the plugin build" | It exists, for the plugin and for non-Dart consumers | `plugin/test/sources_match.sh` holds it against `hook/build.dart`. |

## Context

[Decibel](https://process.audio/de/products/decibel/manual) by process.audio is a commercial
modular metering suite: a resizable canvas of meter modules (LUFS, True Peak, VU, spectrum,
spectrogram, phase scope, histogram…), organised into tabs, driven by presets, calibrations and
skins, with offline file analysis and a Wi-Fi companion display for tablets.

We want a free and open-source equivalent, built in Flutter so one codebase covers macOS,
Windows, Linux and tablets. Phone and web are explicitly out of scope. The hard requirement is
**latency-free, perfectly smooth rendering** — a meter that stutters is not a meter — which
drives essentially every architectural decision below.

Product name: **Open Audio Analyzer** — descriptive rather than clever, so the
name says what the thing is and nothing else has to be explained. Repo, binary
and packages follow it: `open_audio_analyzer`, `oaa`, `oaa_*`.

The repo is currently empty (one commit, no files). Everything below is greenfield.

### Decisions already made

| | |
|---|---|
| **Scope** | All three tiers: standalone app → LAN remote display → headless DAW plugin. Phased so each ships alone. |
| **License** | Dual. `engine/` + `packages/oaa_core` → **MIT**. App, UI, plugin, CLI → **GPL-3.0-or-later**. Rationale: the DSP engine is worth embedding everywhere and needs outside scrutiny; the finished product should not be re-closable. MIT→GPL is one-way compatible, so this composes cleanly. |
| **Visual language** | "Precision Instrument" — graphite black `#0B0C0E`, panel `#121417`, 1px hairline `#1F2328`, single accent `#35E0C4`, warn `#F2B01E`, over `#FF4D4D`. Inter + Google Sans Code (tabular figures). No shadows, no gradients, flat. |
| **State** | Riverpod for UI/config. **Meter data never enters it** — see the performance thesis. |
| **Flutter** | Pin `3.44.5-stable` in `.tool-versions` (matches `gather-v2-app`). |
| **Native** | `flutter create --template=package_ffi` + `hook/build.dart` + `native_toolchain_c`. Recommended since Flutter 3.38; no `CMakeLists.txt`/podspec/gradle per platform. |

---

## The performance thesis

Everything turns on one rule: **audio data never crosses an isolate boundary, never allocates
per frame, and never rebuilds a widget.** Three tiers:

1. **Audio thread (C, realtime-safe).** miniaudio callback. No malloc, no locks, no syscalls.
   Copies input into a lock-free SPSC ring buffer and returns. Microseconds.
2. **Analysis thread (C, high priority, not realtime).** Drains the ring, runs the whole DSP
   graph, publishes results into a **seqlock-protected snapshot struct** in shared memory.
3. **UI thread (Dart).** One `Ticker`. Per frame: a single `@Native(isLeaf: true)` call
   (`oaa_snapshot_acquire`, ~2–5 ns, no safepoint transition) then every painter reads
   `Float32List` views **created once at startup** via `Pointer.asTypedList()` over that native
   memory. Zero copies into the Dart heap, zero allocation per frame.

The widget tree is not involved. Painters use `CustomPainter(repaint: meterClock)`, which
repaints **without rebuilding**. Frame cost = 1 FFI call + N `paint()` calls.

A single `MeterClock` owns the only `Ticker`; modules never own one. The FPS setting
(30/60/120) throttles by skipping notifications.

### Rendering technique per module

Most Flutter audio UIs die here. Specifics, all inside `RepaintBoundary`:

| Module | Technique |
|---|---|
| Number box, LUFS, Alert, Validator | `ui.Paragraph` **cached per distinct formatted string**. Values change ~10 Hz, not 60 — re-layout only when the string actually changes. |
| Digital meter | Batched `drawRect`, one reused `Paint`. |
| VU meter | Dial face pre-rendered **once** to a `ui.Image` via `Picture.toImageSync()`; only the needle repaints. |
| Spectrum analyzer | `drawRawPoints(PointMode.polygon, …)` over the native-memory `Float32List`. C writes **screen-space x,y pairs directly** (log-frequency x positions recomputed only on resize). Zero conversion in Dart. |
| Phase scope | `drawRawPoints(PointMode.points, …)` onto a persistent afterglow layer: `Picture.toImageSync()` ping-pong — draw previous image at reduced opacity, then new points. All GPU-side, no CPU readback. |
| Stereo cloud | `drawVertices(Vertices.raw(...))` — takes `Float32List` positions + `Int32List` colors straight through. |
| Spectrogram | Persistent scroll target: each frame blit the previous image offset by N px, then one new 1×H column. Never re-uploads the full texture. |
| Histogram | Two layers: a **committed** `ui.Image` for everything off the live tail (rebuilt only on zoom/scroll) + the live tail per frame. 4 h at 10 Hz is 144k points — never re-path all of it. |

**Every row above that keeps a picture between frames did not survive contact with the
engine, and neither did the disposal rule that was supposed to make them safe.** An image
from `Picture.toImageSync()` retains the display list that drew it for its whole life, so
feeding each frame's image into the next frame's picture retains every frame back to the
first, and disposing the handle releases none of it. It ran the application to 266 GB and
then killed the raster thread. The spectrogram, the phase scope, the stereo cloud and the
histogram keep their history as data and redraw it — see
`lib/src/modules/spectrogram.dart` and the rule in `CLAUDE.md`.

The histogram row is wrong twice over. Redrawing all of it *is* what ships, and it is
cheap because the display is bounded by the module's width rather than by the length of
the session: at one 100 ms column per pixel, a 1200-px module is 1200 points and two
minutes, and the ring behind it holds 4096 columns however small the module is. There is
no zoom and no scroll, so there was never a committed layer to rebuild.

---

## Repository structure

```
open_audio_analyzer/
├── README.md                  # the real design document (gather-v2-app register)
├── CLAUDE.md                  # agent instructions
├── AGENTS.md                  # + one per directory, gather-style
├── LICENSE                    # GPL-3.0-or-later (the app)
├── engine/LICENSE             # MIT
├── .tool-versions             # flutter 3.44.5-stable
├── engine/                    # C11 DSP core — knows nothing about Dart or Flutter
│   ├── include/oaa/oaa.h      # the entire public C ABI, one header
│   ├── src/{ring,seqlock,kweight,loudness,lra,truepeak,rms,vu,fft,phase,cloud,
│   │        spectro,histogram,snapshot,graph,device,decode}.c
│   ├── third_party/{miniaudio,pffft,dr_libs,stb_vorbis}
│   ├── test/                  # C unit tests + EBU conformance vectors
│   └── CMakeLists.txt         # only for the C test runner and the plugin build
├── packages/
│   ├── oaa_engine/            # FFI package; hook/build.dart, ffigen.yaml, typed snapshot facade
│   ├── oaa_core/              # pure Dart domain — no dart:ffi, no Flutter
│   └── oaa_ui/                # design system: tokens, primitives, painter bases
├── lib/src/{app,clock,modules,canvas,panels,data}/
├── cli/                       # `oaa analyze file.wav --json`
├── plugin/                    # headless VST3 + AU plugin (Phase 7)
├── tool/                      # icons, conformance runner, release scripts
└── .github/workflows/
```

**The load-bearing boundary:** `engine/` has no knowledge of Flutter; `oaa_core` has no
knowledge of `dart:ffi`. That is the clean-architecture line that actually matters here — it is
also what makes "all three tiers" tractable, because *the same `liboaa` serves all of them.*

---

## The DSP, specified against standards

Correctness is the whole product. Every metric is pinned to a spec, not vibes.

- **K-weighting** — ITU-R BS.1770-4 stage-1 shelf + stage-2 RLB high-pass. Coefficients
  **computed from the analog prototype at the actual sample rate**, not hardcoded 48 kHz tables,
  so 44.1/48/88.2/96/192 k are all correct.
- **Gating** — EBU R128: 400 ms blocks at 75 % overlap, absolute gate −70 LUFS, relative gate
  −10 LU. Momentary 400 ms, short-term 3 s.
- **LRA** — gated at −20 LU relative, 10th–95th percentile of the short-term distribution, via a
  0.1 LU-bin **histogram** (O(1) per update, not a sorted list).
- **True Peak** — BS.1770-4 Annex 2: 4× oversampling with the specified 48-tap polyphase FIR
  (12 taps/phase); 2× at ≥96 kHz.
- **RMS, Peak, crest factor, PLR, PSR.**
- **Dynamics** — Decibel's "TrueDyn" is proprietary and undocumented. We do **not** claim
  parity. We ship `DR-S` / `DR-I` = `TruePeakMax − LUFS-S/I`, formula published in our manual and
  reproducible. Honesty over a fake-compatible number.
- **FFT** — pffft; Hann window; sizes 1024–8192; log-frequency band mapping using
  **peak-per-bin** (not average, so narrow peaks survive); A/C/Z weighting; slow/med/fast
  release ballistics; infinite peak hold.
- **Correlation** — running Pearson over a sliding window, sum-based, O(1) per sample.

The graph is **sample-rate agnostic** and **channel-count agnostic up to 7.1** (the Digital
Meter requires it).

### The correctness gate

CI asserts the engine against the **EBU R128 / ITU BS.2217 conformance test set** (known
LUFS-I / LRA / TP values) within ±0.1 LU, and cross-checks against `libebur128` (MIT) as an
oracle in the C test suite. This single test is what separates a real meter from a toy; it
lands in Phase 1, not "later".

---

## Feature mapping — Decibel → Open Audio Analyzer

| Decibel | Open Audio Analyzer | Note |
|---|---|---|
| Modules: LUFS, Super, Digital, VU, Spectrum, Spectrogram, Phase Scope, Stereo Cloud, Histogram, Number Box, Alert, Validator | all twelve | VU keeps Vintage/Modern/"Destroyed" variants and mono/stereo/mid/side |
| Free-pixel canvas, corner resize | **24-column snapping grid**, cell-based | Our twist: deterministic, responsive tablet↔desktop for free. Keeps shift-to-fill, alt-drag duplicate, right-click menu, click-empty-to-add |
| Tabs (per preset, keyboard switchable) | same | |
| Presets store layout + tabs + display assignment, relative sizing | same, but grid coords make screen-independence free | Decibel special-cases this; we get it structurally |
| Calibration (VU ref, TP max, LUFS-I target + tolerance, LRA max) | same, plus a **curated target library as JSON data** | Spotify/Apple/YouTube/Tidal/Amazon, EBU R128, ATSC A/85, podcast, club/CD — community-editable, not compiled in |
| Skins | token-based JSON skins | users author them without a build |
| LUFS modes: Continuous / System / Elapsed / Timecode | same | Elapsed & Timecode arrive with the plugin (Phase 7) |
| Offline drag-and-drop analysis | same, same DSP code path at max speed | identical numbers to realtime — that *is* the correctness argument |
| Export `.txt` report | `.txt` **+ JSON + CSV + rendered report card**, plus a `oaa analyze --json` CLI | scriptable in a release pipeline; a genuine win over the original, nearly free once the engine is a C lib |
| Companion display, connect by typing an IP | remote display via **mDNS discovery** (`_oaa._tcp`) | strictly better UX than typing IPs |
| Standalone / VST3 / AU / AAX | standalone + **VST3** + **Audio Unit** | Flutter cannot be a plugin GUI. The plugin is headless C++ around the same `liboaa`, streaming snapshots + DAW transport to the app. AAX is out of scope — it needs Avid's SDK and a registered account |
| 30/60 fps option | 30/60/120 | |

---

## Design system (`packages/oaa_ui`)

- **Spacing** `2, 4, 8, 12, 16, 24, 32, 48, 64` exposed as `Space.*`. **No raw numbers in widget
  code** — enforced as a review rule in `CLAUDE.md`.
- **Radii** `0, 2, 4, 8`. **Borders** 1px hairline only. **Elevation: none** — depth comes from
  background steps and hairlines, which is how professional audio tools read.
- **Type** Inter (UI) + Google Sans Code for every numeric readout, with
  `FontFeature.tabularFigures()` — non-negotiable; jittering digits look amateur.
- **Reused primitives** (the "reuse components" requirement is met structurally): `ModuleFrame`
  (title bar, burger menu, resize affordance, min-size placeholder), `Readout`, `ScaleAxis`,
  `TargetMarker`, `OptionSheet`, `PanelScaffold`, `SegmentedControl`, `MeterPainterBase`.
  Every one of the twelve modules is `ModuleFrame` + a painter; module-specific code is the
  painter and its options schema, nothing else.

---

## Documentation deliverables

`gather-v2-app` has no `CLAUDE.md` — its equivalent is `AGENTS.md`, with one per directory. We
produce both, in the same register: long "why, not what" file-header comments stating the
failure mode that forced each design.

- `CLAUDE.md` — spacing rule, the no-allocation-per-frame rule, the engine/Flutter boundary,
  the dual-license boundary, test gates.
- `AGENTS.md` at root + `engine/`, `engine/src/`, `packages/`, each package, `lib/`,
  `lib/src/modules/`, `test/`, `tool/`, `.github/`.
- `README.md` — the real design document: architecture, the performance thesis, the DSP spec
  table, licensing split, build instructions, the honest list of gaps vs Decibel.

---

## Phasing

Each phase is independently shippable.

- **Phase 0 — Skeleton + spike (proves the thesis).** Repo scaffolding, both LICENSEs, README,
  CLAUDE.md/AGENTS.md tree, CI, `gh repo create JonasGrunau/open_audio_analyzer --public --push`.
  Flutter app shell + `oaa_engine` package_ffi compiling one C file; a C sine generator writing
  a snapshot; one Number Box painting it via the Ticker path.
  **Gate: profile-mode frame time < 2 ms including the FFI read.** If `hook/build.dart` native
  assets misbehave on any desktop target, we find out here — fallback is legacy `plugin_ffi` +
  CMake, and finding out in Phase 0 costs a day instead of a month.
- **Phase 1 — Engine core.** miniaudio capture, ring buffer, seqlock snapshot, K-weighting,
  M/S/I, LRA, true peak, RMS, VU ballistics, crest. C tests **+ EBU conformance in CI**.
- **Phase 2 — Design system + canvas.** `oaa_ui` tokens and primitives; grid canvas with
  add/move/resize/duplicate/delete; tabs.
- **Phase 3 — The twelve modules,** in dependency order: Number Box → LUFS → Digital → Alert →
  Validator → Super → Histogram → VU → Spectrum → Phase Scope → Spectrogram → Stereo Cloud.

  Nine of them draw something the engine did not compute, so the phase splits in two. **3a**
  adds the measurements — pffft and a 4096-point Hann STFT at a 1024 hop mapped onto the 512
  log bands the ABI already declared, per-band stereo position, the raw stereo sample stream
  for the goniometer, the short-term loudness distribution with the percentiles LRA is the
  difference of, and a real second-order VU movement replacing the one-pole placeholder — each
  with the test that holds it against arithmetic. **3b** is the eleven painters. Building the
  measurement first is what stops a module inventing a number to draw.
- **Phase 4 — Presets, Calibration, Skins, audio settings, persistence.**
- **Phase 5 — Offline analysis, report panel, exports, `oaa` CLI.**
- **Phase 6 — Remote display:** mDNS discovery, binary snapshot wire format, tablet mode
  rendering the same `ModuleSpec` tree with the same painters.
- **Phase 7 — VST3 and Audio Unit plugin**, DAW transport → Elapsed/Timecode modes.

  Built with **JUCE under its GPL-3.0 option**, which produces both formats — plus a
  standalone target — from one headless C++ source set wrapped around `liboaa`. The
  alternative is writing against Steinberg's VST3 SDK and Apple's AudioUnit API
  separately, which is two substantial implementations of boilerplate that a framework
  exists to absorb, for a plugin whose actual job is thirty lines: take the DAW's buffer,
  push it into `oaa_engine_push`, and stream snapshots and transport position to the app
  over a local socket.

  **The licensing is coherent but it is a one-way door for `plugin/` only.**
  JUCE and the VST3 SDK are both dual-licensed — proprietary, or GPL-3.0. Open
  Audio Analyzer takes the GPL-3.0 path, which is available *because* the
  application and plugin are already GPL-3.0-or-later. The combined plugin
  binary is therefore GPL-3.0, and nobody can ship a closed-source fork of it
  without buying both licences. `engine/` stays MIT and is not touched by this:
  the plugin links it, it does not link the plugin.

  CLAP was the earlier choice and is dropped. Its SDK is MIT and technically the nicest
  of the three, but **Ableton Live does not host CLAP**, and a metering plugin that
  cannot be inserted in Live is a metering plugin most people cannot use. VST3 plus AU
  reaches Live, Logic, Pro Tools (via VST3 on the systems that allow it), Reaper, Studio
  One, Bitwig, Cubase and Digital Performer.
- **Phase 8 — Polish:** keyboard shortcuts, docs site, packaging (dmg / msix / AppImage / flatpak).
  The dmg and the msix were later replaced by an installer package and an Inno
  Setup installer, and a Linux tarball was added beside the AppImage and the
  flatpak, because not one of those four original formats can install a
  plug-in — see `packaging/AGENTS.md`. Five desktop downloads shipped rather
  than four, and three of them carry the VST3.

---

## Risks, stated honestly

1. ~~**macOS system-audio capture is the biggest gap vs Decibel.** Decibel ships its own signed
   monitoring driver; we realistically cannot early on. v1 documents BlackHole/loopback devices;
   ScreenCaptureKit (macOS 13+) is evaluated in a later phase.~~ **Closed, and not the way this
   predicted.** No driver was written and ScreenCaptureKit was not used. Core Audio process taps
   (macOS 14.2, `AudioHardwareCreateProcessTap`) capture what is being sent to an output device in
   that device's own format, with no driver, no installer, no root and no rerouting — so the
   speakers keep working while the meters read. It ships as one extra entry in the device list,
   `OAA_DEVICE_ID_SYSTEM_OUTPUT`; see `engine/src/oaa_tap.h`. What is left is macOS below 14.2,
   where BlackHole is still the answer and the README says so.
2. **Native assets (`hook/build.dart`) are young.** Recommended since Flutter 3.38, but verify on
   all three desktop targets in Phase 0 before anything is built on top.
3. **Tablets are display-first.** FFI works fine on iPadOS/Android, but audio *input* selection
   differs sharply per platform; the tablet build's primary role is the Phase 6 remote display.
4. ~~**GPU texture lifetime** in the `toImageSync()` persistence layers — disposal is mandatory
   on resize and teardown.~~ **Wrong, and the way it was wrong crashed the application.** The
   hazard is not the texture, it is the display list the image keeps alive: a ping-pong retains
   every frame it has ever drawn, and disposal cannot release it. Accumulating into a GPU
   surface is not possible from `dart:ui`; these modules redraw from data.
5. `cmake` and `ninja` are **not installed** on this machine. Needed for the C test runner and
   Phase 7; `brew install cmake ninja` in Phase 1.

---

## Verification

- `flutter analyze && flutter test` — lints and widget/golden tests.
- `dart test packages/oaa_core` — domain layer, no widget tree needed.
- `cmake --build engine/build && ctest` — DSP unit tests.
- **`tool/conformance.dart`** — runs the EBU R128 / BS.2217 vectors through the engine, asserts
  ±0.1 LU. Red conformance = red CI = no release.
- Golden tests per module painter at fixed snapshot values.
- **Perf gate:** a benchmark asserting frame build + raster stays in budget with 12 modules
  live; verified with `flutter run --profile` and the DevTools timeline.
- Manual: play a known-loudness reference file through the app and through `oaa analyze`, and
  confirm the two agree — realtime and offline share the DSP path, so divergence is a bug.

---

## First actions on approval

1. Scaffold the repo, both LICENSE files, README, CLAUDE.md and the AGENTS.md tree.
2. `gh repo create JonasGrunau/open_audio_analyzer --public --source=. --push`.
3. Phase 0 spike, and hold it against the < 2 ms gate before going further.
