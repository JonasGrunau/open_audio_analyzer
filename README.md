# Bel

A free and open-source loudness and spectrum analyzer, for desktop and tablets.

Bel is a modular metering suite: a canvas of resizable meter modules — loudness,
true peak, VU, spectrum, spectrogram, phase scope, histogram — organised into
tabs, driven by presets, delivery targets and skins, with offline file analysis
and a companion display that mirrors a tab to a tablet over Wi-Fi.

It is a free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by process.audio, whose
modular canvas is the best interaction model anybody has found for this problem.
The measurement work, the architecture and the visual language are our own, and
where Bel cannot honestly match Decibel it says so rather than approximating.

> **Status: Phase 8 complete. Every phase in [docs/PLAN.md](docs/PLAN.md) has
> shipped.**
> **All thirteen modules exist and measure something.** Bel opens on a working
> meter bridge — loudness, super, digital, VU, validator, histogram, alert —
> with the analyser, spectrogram, phase scope and stereo cloud on a second tab,
> and the canvas is arrangeable: add, move, resize, duplicate, delete, tabs,
> undo. Loudness and true peak are verified against the EBU Tech 3341/3342
> cases, and the spectrum against a sine of known amplitude on a bin centre, on
> Linux, macOS and Windows on every push. See [Roadmap](#roadmap), and
> [docs/PLAN.md](docs/PLAN.md) for the plan as it was approved.
>
> What you set up is remembered — the layout, the delivery target, the skin and
> the capture device — and reopens with the window. Settings, presets, your own
> delivery targets and your own skins are plain JSON files in a documented
> directory; see [Configuration](#configuration).
>
> Files are analysed offline by the app and by the [`bel` CLI](#analysing-files),
> a tablet [mirrors the canvas](#roadmap) over Wi-Fi, and a headless
> [VST3 / AU plugin](#in-a-daw) meters what your DAW is playing. There is a dmg,
> an msix, an AppImage and a flatpak — see [Installing](#installing) — and a
> [documentation site](https://jonasgrunau.github.io/open_music_analyzer/).
>
> What is *not* built is listed under
> [Known gaps](#known-gaps-stated-plainly), and the list is honest rather than
> short.

---

## Why it is built this way

A meter that stutters is not a meter. Everything below follows from one rule:

> **Measurements never cross an isolate boundary, never allocate per frame, and
> never rebuild a widget.**

Three tiers, and the boundary between each is deliberate:

| Tier | Thread | Job |
|---|---|---|
| **Capture** | audio callback, realtime-safe | Copy input into a lock-free ring. No malloc, no locks, no syscalls. |
| **Analysis** | dedicated, high priority | Run the DSP graph. Publish results into a seqlock-protected snapshot. |
| **Display** | Flutter UI thread | One FFI call per frame, then paint. |

### The per-frame path

Once per frame, [`MeterClock`](lib/src/clock/meter_clock.dart) makes a single
`@Native(isLeaf: true)` call to `bel_snapshot_acquire` — an atomic load, a
memcpy, and a second atomic load, with no VM state transition. Then every
painter reads `Float32List` views that were **built once at startup** over
native memory that never moves.

The widget tree is not involved at any point. Painters are constructed with
`CustomPainter(repaint: clock)`, which re-rasters them *without rebuilding the
widget*. A frame costs one FFI call plus N `paint()` calls, and allocates
nothing.

Three consequences worth naming, because they are what usually goes wrong:

- **One clock, not thirteen.** Independent tickers drift, and two meters showing
  the same quantity could then disagree within a single frame. On a measurement
  tool that is a correctness bug, not a cosmetic one.
- **Text is cached by formatted string.** A value changes continuously; the
  string rounded to one decimal changes about ten times a second. Laying out a
  `ui.Paragraph` on the other fifty frames is pure waste, so
  [`ReadoutPainter`](packages/bel_ui/lib/src/readout.dart) rebuilds only when
  the string actually differs.
- **The reader retries, never the writer.** The snapshot is a seqlock precisely
  because it is wait-free for the analysis thread. A mutex would let a
  descheduled UI thread stall the thread that must never stall — and when that
  thread falls behind, the ring overruns and signal is lost for good.

### Rendering, per module

| Module | Technique |
|---|---|
| Number box, LUFS, Alert, Validator | Cached `ui.Paragraph`, rebuilt on string change only |
| Digital meter | Batched `drawRect`, one reused `Paint` |
| VU meter | Dial face pre-rendered once to a `ui.Image`; only the needle repaints |
| Spectrum analyzer | `drawRawPoints` over the native `Float32List` — C writes screen-space x,y directly |
| Phase scope | The last forty frames of samples in a ring, one `drawRawPoints` each at its age's brightness — the trail is the frames, not a faded picture |
| Stereo cloud | A decayed accumulator per two-pixel cell, emitted as points sorted into brightness buckets |
| Spectrogram | Run-length columns kept as data and redrawn every published frame, one `drawRawPoints` per palette step |
| Histogram | Ten columns a second into a fixed ring of loudness values, redrawn whole every frame as three `drawRawPoints`. Kept as measurements, not pixels, so it survives a resize |
| Loudness distribution | The engine's 120 published bins as one `drawRawPoints`, clipped twice so the bars either side of the target take different colours |

---

## Measurement

Correctness is the entire product, so every metric is pinned to a published
spec rather than to intuition.

| Quantity | Definition |
|---|---|
| K-weighting | ITU-R BS.1770-4 stage-1 shelf + stage-2 RLB, coefficients computed from the analog prototype **at the actual sample rate** — not hardcoded 48 kHz tables |
| Gating | EBU R128: 400 ms blocks at 75% overlap, absolute gate −70 LUFS, relative gate −10 LU |
| Momentary / Short-term | 400 ms / 3 s |
| LRA | Gated at −20 LU relative, 10th–95th percentile, via a 0.01 LU-bin histogram storing exact energy sums (O(1) per update, constant memory) |
| True peak | BS.1770-4 Annex 2, 4× oversampling with the specified 48-tap polyphase FIR, at every sample rate |
| Spectrum | 4096-point Hann window at a 1024-sample hop, zero-padded to a 16384-point transform and mapped onto 512 log-spaced bands with **peak-per-bin** so narrow peaks survive; bands too narrow to hold a bin read between two. Window-compensated: a full-scale sine reads 0.0 dBFS on a bin centre and within 0.3 dB off it |
| Correlation | Running Pearson over a sliding window |

Every one of these is measured today and checked in CI, the spectrum included:
a full-scale sine on a bin centre reads 0.0 dBFS on every push.
`BEL_FLAG_SPECTRUM_UNAVAILABLE` stays in the ABI and consumers must keep
checking it, because a future source that cannot produce a spectrum needs a way
to say so — but this build never sets it.

### On dynamics, and on honesty

Decibel reports a dynamics figure called *TrueDyn*. It is proprietary and
undocumented, so any claim to match it would be a guess presented as a
measurement. Bel does not implement it.

Instead Bel reports `DR-S` and `DR-I`, defined as `TruePeak − LUFS-S` and
`TruePeakMax − LUFS-I`, published in [docs/METRICS.md](docs/METRICS.md) and
reproducible from the definition by anybody who wants to check.

The same principle runs through the code. A quantity this build does not
measure is **NaN**, never zero — zero is a legitimate reading for correlation,
balance and several dB quantities, so it cannot double as "no data" — and the
UI renders it as an em dash. No quantity in the spec table above is unmeasured
in this build, so in practice a dash means a reading that is not yet *defined*:
momentary loudness needs 400 ms of signal, short-term needs 3 s, and integrated
needs one gating block above the absolute gate. Each shows a dash until it
means something. A remote display that has lost its host shows them too — a
frozen meter is indistinguishable from a quiet passage.

### The correctness gate

CI runs the **EBU Tech 3341 and 3342** cases on Linux, macOS and Windows on
every push, and fails the build if any reading is outside the standard's stated
tolerance. A loudness meter that has never been run against the reference cases
is a number generator.

The signals are **generated, not downloaded** — every case is a sine at a stated
level or a sequence of them, so the suite needs no fixtures, no network and no
WAV decoder, and each expected value is derived from the standard in a comment
rather than copied from somebody's output. Two extra properties are asserted
that the standard does not state but no correct implementation can violate:

- **Sample rate independence** — the same tone reads the same at 44.1, 48, 88.2,
  96 and 192 kHz. This catches the tempting shortcut of using the 48 kHz
  coefficient table BS.1770-4 prints instead of designing the filter at the
  stream's rate: it passes every 48 kHz test there is, and is wrong by a
  fraction of a dB on the most common delivery rate in music.
- **Block size independence** — ten seconds pushed in one call, in 512-frame
  device blocks, and in 377-frame chunks agree to 0.001 LU.

A third property is asserted now that there is a decoder: **decoding does not
change a reading.** A generated signal analysed directly, and the same signal
written to a WAV, decoded and analysed again, produce identical numbers to the
bit. That is the property offline analysis rests on, so it is asserted rather
than assumed.

The official **BS.2217 WAV vectors are still not used**, and the obstacle is no
longer technical. The EBU and ITU test material is not licensed for
redistribution here, and fetching it in CI would put a network dependency in
front of the one suite that must never be flaky. Running them locally against
`bel` is worthwhile and is a one-liner; they are not a gate. See
[docs/METRICS.md](docs/METRICS.md#conformance).

---

## Layout

Bel's canvas is a **24-column snapping grid** rather than Decibel's free pixel
positioning. 24 divides by 2, 3, 4, 6, 8 and 12, so halves, thirds and quarters
are all exact — a 12-column grid cannot express thirds and quarters at once,
which is the first thing anybody wants when arranging meters.

**The row count is fixed too, at 16.** The obvious alternative — square cells
and a canvas that scrolls — keeps module aspect ratios identical everywhere, and
is wrong: on a 32" display a cell becomes 160 px, a six-row meter becomes 960 px
tall, and a layout built on a laptop now needs scrolling. A meter bridge you
have to scroll is not a meter bridge. So both axes are fixed and cells are
whatever shape the window makes them, which costs nothing because every painter
has to handle arbitrary aspect anyway — nothing stops you resizing a phase scope
to 8×2.

The practical win is that a preset stores grid cells, so it is
screen-independent by construction. Decibel stores fractions of the window and
reconstitutes them per display; Bel opens the same layout on a 32" monitor and
an 11" tablet with nobody writing responsive code.

The interactions: **drag a module's title bar** to move it, **drag the corner
grip** to resize, **alt-drag** to duplicate, **right-click or long-press empty
canvas**
to add a module there, **right-click a module** for its options, and
**right-click or long-press a tab** to rename, duplicate or delete it. Buttons
for add, undo and redo sit in the tab strip as well, because tablets have
neither a right mouse button nor `⌘Z`.

Nothing in Bel is a double click. A double-tap recogniser holds Flutter's
gesture arena for 300 ms before it gives up, and every button underneath one
waits that long to fire — which is a third of a second of an application that
feels broken, in exchange for a gesture a long press does better on both a
mouse and a tablet.

### Keyboard

Press `?` or `F1`, or the `?` in the status bar. Bel draws its own chrome and so
has no menu bar, which is the usual place a desktop user reads a shortcut off —
without that sheet the shortcuts would be undiscoverable by design.

`⌫` deletes the selection, arrow keys nudge it a cell and `⇧`+arrows resize it,
`⌘Z` / `⌘⇧Z` undo and redo, `⌘D` duplicates, `1`–`9` switch tabs, `⌘R` restarts
the measurement, `⌘O` analyses a file. The full list is on the
[documentation site](https://jonasgrunau.github.io/open_music_analyzer/keyboard.html),
and it is not written twice: the page, the in-app sheet and the bindings
themselves all come from one table in `lib/src/app/shortcuts.dart`, and a test
fails if the page has drifted from it.

Three details that are decisions rather than defaults:

- **`Ctrl` and `⌘` are both accepted on every platform.** Asking the OS which
  one was meant is how a Mac driving an external PC keyboard ends up with no
  undo. Only the printed label is platform-specific.
- **A chord with no `Ctrl` or `⌘` stands aside while a text field has focus**,
  so a tab named `Mix 2` does not jump you to the second tab halfway through.
- **A nudge with nowhere to go does nothing**, rather than clamping. Clamping
  means the tenth press of `→` moves the module and the eleventh does not, with
  no way to feel where the edge was. It is the same rule a drag follows.

**Modules do not overlap, and a drop that would overlap is refused.** The two
alternatives are worse: allowing overlap turns a meter bridge into a stack of
half-hidden panels and needs a z-order, and pushing neighbours aside — what most
dashboard grids do — means a drag near an edge can rearrange a layout you spent
ten minutes on, irreversibly. Bel shows the target cells while the pointer is
down — bright when the drop is legal, red when it is not — and an illegal drop
simply does not happen. Nothing moves that you did not move.

While the pointer is down the canvas becomes the placement grid: the cells are
ruled inside a border that sits one gutter outside the modules, and every module
except the one being carried is dimmed. A drop target is easy to place against
ruled cells and hard to find among a dozen meters that are all still moving.
The meters do not stop — dimming is a wash painted over them, not a pause, and
it is a wash rather than a blur because a full-screen blur would be re-computed
every frame over exactly the readings that are still arriving.

A module resized below its minimum shows `TOO SMALL` instead of an unreadable
smear — a spectrum analyser in two cells is not a small spectrum analyser. A
module kind that has no painter yet says `NOT BUILT YET` rather than showing an
empty panel, which would read as a meter that is broken.

**Presets, Calibrations and Skins** are three independent axes, as in Decibel,
including the `from preset` indirection. Null means *follow the preset*; a
concrete id means the user pinned that choice and browsing presets must leave it
alone. Without that distinction, either presets cannot carry a target or an
explicit choice gets silently overwritten.

Delivery targets ship as **data**, not code, so the set can be corrected and
extended without a release. Six are built in: **Streaming (−14 LUFS)** — which
is Spotify, Apple Music, YouTube, Amazon and Tidal, all of which normalise to
about the same place, so one target with their names in its note beats five
identical entries — plus **Spotify Loud**, **Podcast (−16 LUFS)**,
**EBU R 128**, **ATSC A/85** and **CD / no normalisation**. Anything else is a
JSON file you write; see [Configuration](#configuration).

---

## Configuration

Everything Bel remembers is a JSON file you can open, edit, copy between
machines or keep in version control.

| | |
|---|---|
| **macOS** | `~/Library/Application Support/Bel` |
| **Windows** | `%APPDATA%\Bel` |
| **Linux** | `$XDG_CONFIG_HOME/bel`, or `~/.config/bel` |
| **iPadOS** | `Library/Application Support/Bel` inside the app's own container |

The iPad row is the one you cannot open in a file manager, because iOS gives an
app a private container and no way out of it. Settings → Session prints the
path; a display persists its layout, its skin and the host it last connected to,
and nothing else on the device can read them. **An Android tablet persists
nothing** and says so at launch: its container is not derivable without a
platform channel Bel does not have.

`BEL_CONFIG_DIR` overrides the three desktop rows — for a portable install, or
for keeping Bel's configuration alongside your dotfiles — and
`--config-dir=<path>` on the command line beats the variable in turn, which is
the one that works on macOS where an environment cannot be handed to an
application bundle. Settings → Session prints the directory actually in use and
lets you select it, which beats retyping any of the above.

**The macOS app is deliberately not sandboxed**, and that is what makes the
first row true. A sandboxed app's `HOME` is redirected into
`~/Library/Containers/dev.belmeter.bel/Data`, which would put your presets
somewhere you would never find them and stop either override from pointing
anywhere outside it — defeating the point of keeping configuration in files you
can edit, mail and version. The trade is that Bel cannot ship on the Mac App
Store, which it was never going to; notarisation for the dmg does not require
the sandbox. See `macos/Runner/Release.entitlements`, which says so at the top.

```
settings.json          the frame rate, source, target, skin
session.json           the canvas as you left it, saved as you work
presets/*.json         one file per saved layout
calibrations/*.json    one file per delivery target you wrote
skins/*.json           one file per skin
```

**One file per preset rather than one library file**, deliberately: it means a
preset can be sent to somebody or dropped in from a forum post, and that one
corrupt file costs one preset instead of all of them. Every write goes to a
temporary file and is renamed over the target, so an interrupted save leaves the
previous version intact rather than a half-written one. A file that fails to
parse is named in the interface and left alone — Bel never rewrites something it
could not read.

The path this does *not* take is `path_provider`. That function needs a Flutter
binding, so it throws in the two places Bel most needs these paths — the `bel`
CLI and a unit test — and on macOS it returns a sandbox container keyed by
bundle identifier, which moves your entire configuration the first time a build
is signed differently.

### Writing a skin

A skin names as many of thirteen colour **roles** as it likes and inherits the
rest, so changing one colour is a three-line file:

```json
{
  "id": "my-skin",
  "name": "My Skin",
  "colors": { "accent": "#FF9E00" }
}
```

The roles are `background`, `panel`, `panel_raised`, `hairline`,
`hairline_strong`, `text_primary`, `text_muted`, `text_faint`, `accent`, `warn`,
`over`, `meter_track` and `meter_fill`. Values take `#RGB`, `#RRGGBB` or
`#AARRGGBB`. Add `"light": true` for a palette that is dark ink on a light
ground.

They are *semantic* roles rather than literal colours — `over` is "the colour
that means over a limit", used for nothing else — which is what lets a skin
apply to a module written after it. Settings → Appearance → **Duplicate for
editing** writes the palette you are looking at out in full as a starting point,
and **Reload from disk** picks up your edits without a restart.

A delivery target is the same idea:

```json
{
  "id": "house-standard",
  "name": "House standard",
  "lufs_target": -12.0,
  "lufs_tolerance": 0.5,
  "true_peak_max": -1.0,
  "lra_max": 14.0,
  "vu_reference": -18.0
}
```

A file whose `id` matches one Bel ships with **replaces** it everywhere,
including in presets that already name it — so if you disagree with our reading
of a published spec, your number wins. Delete the file and the original comes
back.

---

## Design

**Precision Instrument.** Graphite black, one signal hue, hairline borders, no
shadows and no gradients. Depth comes from background steps, because
measurement gear is machined panels sitting flush, not floating cards.

```
bg      #0B0C0E     accent  #35E0C4   in spec
panel   #121417     warn    #F2B01E
hairline#1F2328     over    #FF4D4D
text    #E6E8EB / #8A9199 / #565E67
```

Two rules are enforced rather than merely encouraged:

1. **Every spatial value comes from `Space`** — `2, 4, 8, 12, 16, 24, 32, 48,
   64`. No widget writes a raw number for padding, margin or gap. Thirteen
   modules built over as many weeks drift apart one `EdgeInsets.all(11)` at a
   time, and the result reads as amateur long before anybody can say which
   value is wrong.
2. **Every number is monospaced with tabular figures.** With proportional
   digits a readout's width changes as its digits change, so it jitters while
   you watch it. It is the single most obvious tell of a meter written by
   somebody who does not use meters.

**Inter** (labels and prose) and **JetBrains Mono** (every number) are bundled
rather than requested from the system, in the three and two weights the type
scale actually names. Falling through to the platform's own faces means digit
width, tracking and cap height all differ between macOS, Windows and Linux, and
a layout tuned on one is subtly wrong on the other two. Both are SIL OFL 1.1 and
their licences ship in `assets/fonts/`.

Every one of the thirteen modules is [`ModuleFrame`](packages/bel_ui/lib/src/module_frame.dart)
plus a painter. That is the whole reuse strategy: a module that also owns its
own border and title treatment is a module that will drift from the other
eleven.

---

## Repository layout

```
engine/            C11 DSP core. Knows nothing about Dart or Flutter.        MIT
packages/
  bel_engine/      FFI bindings + the build hook that compiles engine/.      MIT
  bel_core/        Domain model. Pure Dart — no Flutter, no dart:ffi.        MIT
  bel_wire/        The remote-display protocol. Pure Dart, no I/O.           MIT
  bel_ui/          Design tokens and the primitives modules are built from.  GPL
lib/               The application.                                          GPL
assets/fonts/      Inter and JetBrains Mono, with their licences.        SIL OFL
cli/               The `bel` command-line analyser.                          GPL
plugin/            Headless VST3 + AU plugin.                              AGPL
docs/              PLAN.md, METRICS.md, WIRE.md.
```

`plugin/` is the one **AGPL** directory. JUCE 7 and 8 are AGPLv3-or-commercial
— only JUCE 6 offered GPLv3 — and Bel takes the AGPLv3 option, which is
available because everything here is free software already. It changes the
licence of the plugin binary alone: the engine stays MIT, and the app stays GPL
because it never links JUCE. It talks to the plugin over a socket, which is not
linking. GPLv3 section 13 expressly permits the combination. Steinberg's VST3
SDK, meanwhile, is now MIT and vendored inside JUCE, so there is no second
copyleft dependency and no SDK to check out.

Two boundaries carry weight:

- **`engine/` knows nothing about Flutter, and `bel_core` knows nothing about
  `dart:ffi`.** Four things need the domain vocabulary — the app, the tablet
  display, the CLI and the plugin — and three of them have no engine of their
  own. The tablet reads measurements off a socket. The moment `bel_core`
  imports `bel_engine`, all three drag in a native library they never call.
- **One `libbel` serves all three tiers.** That is what makes standalone,
  remote display and plugin tractable as one project rather than three.

### Licensing

Deliberately split, and set on day one because it is nearly free now and
expensive once outside contributors arrive:

- **`engine/`, `packages/bel_engine`, `packages/bel_core`, `packages/bel_wire`
  — MIT.** A metering engine's value is that anyone can embed and audit it, and
  a measurement tool needs that scrutiny more than most software. The wire
  protocol is on this side of the line for the same reason: a third-party
  display should not have to be GPL to speak it.
- **`packages/bel_ui`, `lib/`, `cli/` — GPL-3.0-or-later.** A free clone of a
  paid product should not be trivially re-closable.
- **`plugin/` — AGPL-3.0-or-later**, because it links JUCE. See above.

MIT is one-way compatible with GPL, so the combination composes cleanly.

---

## Installing

Every release publishes four installers and a standalone CLI binary on the
[releases page](https://github.com/JonasGrunau/open_music_analyzer/releases).
Full instructions, including the loopback-device workaround for system audio,
are on the [documentation
site](https://jonasgrunau.github.io/open_music_analyzer/install.html).

| Platform | Artefact | |
|---|---|---|
| macOS 11+ | `Bel-<version>-macos-<arch>.dmg` | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Bel-<version>-windows-x64.msix` | |
| Linux | `Bel-<version>-<arch>.AppImage` | One file, no root, GTK from the host. |
| Linux | `Bel-<version>-<arch>.flatpak` | Sandboxed, carries its own runtime. |
| Any | `bel` / `bel.exe` | The analyser. No Flutter runtime. |

**There is no Mac App Store build and there will not be one.** The store
requires the app sandbox, and a sandboxed application has its home directory
redirected into `~/Library/Containers` — which put every preset, skin and
delivery target somewhere no user goes looking and no override could escape.
Bel is distributed directly, signed with a Developer ID and notarised. See
`macos/Runner/*.entitlements`, which carries the reasoning, and
`packaging/macos/make_dmg.sh`, which repeats it where somebody signing a build
will be standing.

The scripts that build these live in [`packaging/`](packaging/AGENTS.md), one
per platform, and `.github/workflows/release.yml` runs all four on a tag and on
demand. Each produces an unsigned artefact and says so rather than failing when
the signing secrets are absent — a fork has none, and a build that stopped there
would be useless to it.

---

## Building

Requires Flutter `3.44.5-stable` (pinned in `.tool-versions`) and a C toolchain
— Xcode command line tools, MSVC, or gcc/clang.

```sh
flutter pub get
flutter run -d macos          # or windows, linux
flutter run -d <ipad>         # the display build; `flutter devices` names it
```

On iOS the engine is compiled as **Objective-C**, because miniaudio's Core
Audio backend is: it configures an `AVAudioSession` there, and iOS offers no C
way to do that. `hook/build.dart` handles it. This is worth knowing only
because of how it fails if it is ever undone — several hundred errors inside
Apple's own `Foundation` headers, not one of which names a file in Bel.

The app needs **no podspec, no `build.gradle` and no per-platform
`CMakeLists.txt`**. `packages/bel_engine/hook/build.dart` compiles the C
through `native_toolchain_c` and bundles it as a code asset, which has been the
recommended way to ship native code with Flutter since 3.38. One build
description that works on five platforms beats five that each work on one.

`engine/CMakeLists.txt` describes the *same* compile for consumers that are not
Dart — the plugin, and a CI runner with no Flutter SDK. Two descriptions of one
compile is a real cost, paid deliberately: `plugin/test/sources_match.sh` fails
the build if the source lists drift apart, so **a new file in `engine/src` goes
in both.**

### Tests

```sh
flutter analyze                       # lints, whole workspace
flutter test                          # widget and golden tests
dart test packages/bel_core           # domain layer, no toolchain needed
dart test packages/bel_wire           # the wire protocol, incl. the C++ golden
cd packages/bel_engine && dart test   # engine, through FFI
cd cli && dart test                   # the `bel` binary, as a subprocess
sh plugin/test/sources_match.sh       # the engine's two build lists agree
dart run tool/docs.dart               # the documentation site still builds
```

The engine tests are worth a look even if you never touch the C. A sine of
amplitude *A* has a peak of *A* and an RMS of *A*/√2 — exactly 3.0103 dB lower.
That is arithmetic, not convention, so the built-in test tone doubles as a
reference the meters can be held against on a headless CI runner with no sound
hardware anywhere near it.

---

## Analysing files

Drop a file on the analysis panel, or run the CLI. Both decode the file and push
the blocks through the *same* `bel_analyse` a capture device drives — there is
no second DSP path — so an offline reading and a live reading of the same audio
are identical rather than merely close. A test asserts exactly that, on the same
samples analysed both ways.

Nothing resamples or remixes: a file is measured at its own sample rate and
channel count, because a converter in front of a measurement changes the
measurement. WAV, AIFF, RF64, Wave64, FLAC and MP3.

```sh
bel master.wav                                 # human-readable report
bel --target streaming-14 master.wav           # …and a delivery verdict
bel --format json --timeline master.wav        # every measurement, for scripts
bel --format csv -o loudness.csv master.wav    # the loudness timeline
bel --list-targets                             # what you can measure against
```

**The exit code is the point.** With `--target`, a file that misses its delivery
spec exits `2`, an unreadable file exits `1`, and all-clear exits `0` — so a
release pipeline can fail a build on a master that is 2 LU too loud instead of
shipping it:

```sh
bel --target streaming-14 master.wav || exit 1
```

Reports export as text, JSON and CSV. A quantity nobody measured is an em dash,
a `null` and an empty cell respectively — never a zero, which is a legitimate
reading for correlation and several dB quantities and so cannot double as
"no data".

The app adds a fourth: **a PNG report card**, for the message where somebody
asks whether the master is ready. It is drawn as a fixed layout rather than
captured from the panel, so it does not inherit a scroll position or a window
width and two people exporting the same report get the same picture. The CLI
does not render it — a pipeline reads the text, JSON or CSV.

---

## In a DAW

Bel installs as a **VST3** and an **Audio Unit** that draws nothing.

Insert it on a track, a bus or the master, and the desktop app meters what your
DAW is playing — through the same engine, on the same canvas, with the same
painters as a live input. The plugin measures and streams; the app displays.
That split is not a compromise around Flutter's inability to be a plugin GUI, it
is what stops there being two implementations of every meter drifting apart from
each other.

```sh
cmake -B plugin/build -S plugin -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
```

Products land in `plugin/build/BelPlugin_artefacts/Release/`. Nothing is copied
into a system plugin folder unless you copy it — a build that installed itself
would mean the DAW you have open is now running a binary you did not knowingly
install. JUCE is fetched and pinned, not vendored, so a fresh clone builds
without checking out a framework by hand.

The plugin connects to the app on `127.0.0.1:47822` and keeps retrying, so it
does not matter which of the two you start first. Its window is a status panel —
connected or not, sample rate, channel count, and whether the host is giving it
a playhead — and nothing else. Several inserts can be connected at once; the
most recently added is the one on screen, because adding it is the act of
choosing it.

**What the DAW adds that a live input cannot.** The host's transport comes
across with the audio: play and record state, the playhead in seconds, samples
and quarter-notes, tempo, time signature, loop points, and SMPTE timecode with
its frame rate — plus a flag when the playhead *jumps*, because an integrated
reading taken across a relocate is the average of two passes of the same music
and looks entirely reasonable.

The **Elapsed** and **Timecode** LUFS modes are what that measurement is for,
and they are **not built yet** — no module offers them today. Tying an
integration window to the transport means restarting it when the transport
moves, which is a command travelling from the app back to the plugin, and this
version of the protocol only runs one way.

Hosts differ enormously in what they actually report, and Bel does not paper
over it: every transport value carries a flag saying whether the host supplied
it, and one that did not arrive reads as an em dash. A tempo that arrives as
zero is indistinguishable from a real one, and "bar 1, beat 1, 00:00:00:00" is a
perfectly plausible thing to show somebody while their session is parked at bar
57.

---

## Roadmap

| Phase | | Status |
|---|---|---|
| 0 | Skeleton, engine spike, the render path, design tokens | ✅ done |
| 1 | K-weighting, M/S/I, LRA, true peak, **EBU conformance in CI**, device capture | ✅ done |
| 2 | The 24×16 canvas: add, move, resize, duplicate, tabs, undo; bundled type | ✅ done |
| 3 | The twelve modules, the FFT, the scope and the loudness distribution | ✅ done |
| 4 | Presets, calibrations, skins, audio settings, persistence | ✅ done |
| 5 | Offline file analysis, report panel, exports, `bel` CLI | ✅ done |
| 6 | Remote display: mDNS discovery, wire protocol, tablet mode | ✅ done² |
| 7 | VST3 and Audio Unit plugin, DAW transport and timecode | ✅ done¹ |
| 8 | Keyboard shortcuts, docs site, packaging (dmg / msix / AppImage / flatpak) | ✅ done³ |

¹ The plugin, the transport and the timecode ship. The **Elapsed and Timecode
LUFS modes do not** — see below.

² The display ships. **Discovery does not work on Android** and tab-per-display
targeting is not built — both below.

³ All four installers build and are published on a tag. **None of them is signed
in this repository** — signing needs certificates that are not ours to commit,
so a release built from a fork is unsigned and every script says so. See
[Installing](#installing).

### Known gaps, stated plainly

- **The Elapsed and Timecode LUFS modes are not built.** The plugin delivers
  everything they need — the playhead, the timecode, and a flag when the
  transport jumps — and no module offers the modes yet. Tying an integration
  window to the transport means restarting it when somebody drags the playhead,
  and that command travels from the app *to* the plugin: it needs a control
  frame, which needs **wire protocol 2**. Continuous and System are unaffected,
  and the remote display neither needs one nor will get one — the plugin port is
  loopback, where the things that can connect are already running as you, while
  the display port is on the LAN and stays read-only until somebody designs
  authentication. Silently restarting an integration mid-programme is wrong in a
  way nothing on screen reveals, which is not a capability to put on an
  unauthenticated port.
- **Capturing your own system's output needs a virtual device on macOS and
  Linux.** This is the biggest gap versus Decibel, which ships a signed
  monitoring driver.
  - **Windows** — nothing to do. WASAPI loopback captures whatever is playing.
  - **macOS** — install [BlackHole](https://existential.audio/blackhole/) (free)
    or Loopback, route your output through it, and it appears in Bel's source
    menu like any other input. ScreenCaptureKit is a later evaluation.
  - **Linux** — a PulseAudio or PipeWire monitor source already appears in the
    list.

  Metering a hardware input needs none of this — any interface shows up
  directly.
- **Offline analysis does not read Ogg Vorbis, Opus, AAC or ALAC.** WAV, AIFF,
  RF64, Wave64, FLAC and MP3 cover the formats a master is delivered *as*, which
  is what a delivery check is for. The missing ones are what a master is
  distributed as after transcoding — worth having eventually, and the decoder is
  one function per format, but no measurement is silently wrong in the meantime:
  an unsupported file is refused rather than half-read.
- **A file is measured whole, from the start.** There is no region selection and
  no seeking during analysis, because an integrated loudness taken over a file
  that was seeked through is a measurement of a programme nobody played.
- **The remote display has no authentication and no encryption.** Anyone who can
  reach the port can read the measurements and the layout — not the audio, which
  never goes on the wire. That is why publishing is **off until you switch it
  on**, and why the link is one-directional: a display cannot reset, retarget or
  reconfigure the machine it is watching. Do not switch it on at a venue whose
  Wi-Fi you do not control.
- **Finding hosts automatically does not work on Android.** Receiving multicast
  there needs a `WifiManager.MulticastLock`, which is a platform call Dart
  cannot make and Bel has no native plugin for. An Android tablet browses
  nothing and has to be given an address, and its screen says exactly that
  rather than showing an empty list that reads as "no hosts are running". macOS,
  Windows, Linux and iPadOS discover normally — iPadOS through the system's own
  Bonjour responder, because Apple does not let an app hold a multicast socket
  without an entitlement it grants per developer on request. Typing an address
  is supported everywhere and always will be, because multicast is also the
  first thing a guest network blocks.
- **Publishing is never remembered, on purpose.** The display's name, port and
  update rate persist like every other setting; whether to publish does not, and
  starts off at every launch. There is no password on that port, and a
  remembered "yes" means a laptop carried to a café starts advertising itself
  without anybody deciding to.
- **A remote display shows every tab, not a chosen one.** `TabSpec` carries a
  `displayTargetId` and nothing honours it yet: assigning tabs to a particular
  screen means the host has to be able to tell two displays apart, and in a
  protocol where the display says nothing at all, it cannot. Either the display
  identifies itself — which is a client→host frame, so **wire protocol 2** — or
  the host keys assignments by address, which breaks on DHCP. Until then the
  display shows the whole preset and the viewer picks the tab.
- **An Android tablet remembers nothing between launches.** Every other
  platform resolves a configuration directory; Android is the one whose
  container Bel cannot find without a platform call — `HOME` is unset and the
  temporary directory an iPad's container is derived from is `/data/local/tmp`
  there, which belongs to no app. The display works, and says at launch that
  nothing is being saved. Fixing it means a channel to `getFilesDir()`.
- **Tablets are display-first.** FFI works fine on iPadOS and Android, but audio
  *input* selection differs sharply per platform. The tablet build's primary
  role is the remote display.
- **Flutter cannot be a VST3/AU plugin GUI.** The plugin is a headless C++
  wrapper around the same `libbel`, streaming measurements and DAW transport to
  the app over a local socket. It ships as **VST3 and Audio Unit** — the two
  formats that reach every DAW people actually master in, Ableton Live
  included. AAX is out of scope: it needs Avid's SDK and a registered developer
  account, neither of which a free project can promise.
- **A light skin does not lighten the window frame on Windows or Linux.**
  Everything Bel paints follows the skin; the window frame belongs to the
  operating system, and Flutter has no supported desktop API for it. macOS no
  longer has a title bar at all — the status bar runs to the top edge and the
  window buttons sit inside it — but that took platform code in the runner, and
  the other two each need their own.
- **Native assets are young.** Recommended since Flutter 3.38, but the fallback
  if a platform misbehaves is the legacy `plugin_ffi` template plus CMake.

---

## Contributing

Read [CLAUDE.md](CLAUDE.md) first — it is short, and it is where the rules that
are not obvious from the code live. Each directory has an `AGENTS.md`
explaining what belongs in it and why.

The house style for comments is *why, not what*, usually naming the failure mode
that forced the design. If a comment could be deleted without losing
information, delete it.

## License

GPL-3.0-or-later for the application; MIT for the engine and domain model. See
[Licensing](#licensing) above and the `LICENSE` file in each tier.
