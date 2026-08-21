# Building

Requires Flutter `3.44.5-stable` — pinned in `.tool-versions`, and CI pins the
same — and a C toolchain: Xcode command line tools, MSVC, or gcc/clang.

```sh
git clone https://github.com/JonasGrunau/open_audio_analyzer
cd open_audio_analyzer
flutter pub get
flutter run -d macos          # or windows, linux
flutter run -d <ipad>         # the display build; `flutter devices` names it
```

On iOS the engine is compiled as **Objective-C**, because miniaudio's Core
Audio backend is: it configures an `AVAudioSession` there, and iOS offers no C
way to do that. The build hook handles it — the reason to know is the failure
if it is ever undone, which is several hundred errors inside Apple's own
`Foundation` headers naming no file in Open Audio Analyzer.

There is **no podspec, no `build.gradle` and no per-platform `CMakeLists.txt`**
for the application. `packages/oaa_engine/hook/build.dart` compiles the C
through `native_toolchain_c` and bundles it as a code asset. One build
description that works on five platforms beats five that each work on one.

`engine/CMakeLists.txt` describes the *same* compile for consumers that are not
Dart — the plugin, and a CI runner with no Flutter SDK. Two descriptions of one
compile is a real cost, paid deliberately: `plugin/test/sources_match.sh` fails
the build if the two source lists drift apart, so **a new file in `engine/src`
goes in both.**

### Linux dependencies

```sh
sudo apt-get install clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev libasound2-dev
```

## Tests

All six are the CI gate.

```sh
flutter analyze                       # lints, whole workspace
flutter test                          # widget and golden tests
dart test packages/oaa_core           # domain layer, no toolchain needed
dart test packages/oaa_wire           # the wire protocol, incl. the C++ golden
cd packages/oaa_engine && dart test   # engine, through FFI
cd cli && dart test                   # the `oaa` binary, as a subprocess
```

The engine tests are worth a look even if you never touch the C. A sine of
amplitude *A* has a peak of *A* and an RMS of *A*/√2 — exactly 3.0103 dB lower.
That is arithmetic, not convention, so the built-in test tone doubles as a
reference the meters can be held against on a headless runner with no sound
hardware anywhere near it. The same job runs the **EBU Tech 3341 and 3342**
conformance vectors, and a red conformance run is a red build.

## Running with a different configuration

Two flags, both useful while working on the interface:

```sh
flutter run -d macos --dart-entrypoint-args --config-dir=/tmp/oaa-scratch
flutter run -d macos --dart-entrypoint-args --open-panel=settings
```

`--config-dir` points settings, presets, targets and skins somewhere
disposable, so an experiment cannot eat the configuration you actually use.
`--open-panel` opens one panel once the first frame is up — `settings`,
`presets`, `calibration`, `report` or `shortcuts` — which is how a panel gets
looked at without clicking through to it. It is a debug-build affordance and a
release build says so rather than ignoring it.

On a built macOS bundle, pass them with `open --args`:

```sh
open "build/macos/Build/Products/Debug/Open Audio Analyzer.app" --args --open-panel=shortcuts
```

## The plugin

```sh
cmake -B plugin/build -S plugin -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
```

Products land in `plugin/build/OaaPlugin_artefacts/Release/`. Nothing is copied
into a system plugin folder unless you copy it — a build that installed itself
would mean the DAW you have open is now running a binary you did not knowingly
install. JUCE is fetched and pinned, not vendored, so a fresh clone builds
without checking out a framework by hand.

`plugin/` is the one **AGPL-3.0-or-later** directory, because JUCE 7 and 8 are
AGPL-or-commercial. Nothing there may move into `engine/` or `oaa_core/`, which
are MIT and must stay linkable by people who are not writing free software.

## Installers

One script per platform, under `packaging/`. Each builds the application first
unless told to skip it, and each says plainly whether what it produced can
actually be installed.

```sh
sh  packaging/macos/make_dmg.sh
pwsh packaging/windows/make_msix.ps1
sh  packaging/linux/make_appimage.sh
sh  packaging/linux/make_flatpak.sh
```

Everything lands in `build/packaging/`.

Signing is by environment variable, and every script produces an unsigned
artefact and warns rather than failing when the variables are absent — a fork
has no secrets, and a build that stopped there would be useless to it.

| Variable | For |
| --- | --- |
| `OAA_SIGNING_IDENTITY` | macOS Developer ID, e.g. `Developer ID Application: Name (TEAMID)` |
| `OAA_NOTARY_PROFILE` | A `xcrun notarytool store-credentials` profile |
| `OAA_WINDOWS_CERT` | Path to a `.pfx` |
| `OAA_WINDOWS_CERT_PASS` | Its password |
| `OAA_WINDOWS_PUBLISHER` | The certificate's subject, **exactly** — e.g. `CN=Jonas Grunau` |

Two things that will otherwise cost you an afternoon:

- **A signed but un-notarised dmg is still refused by Gatekeeper.** The
  quarantine flag needs notarisation, not merely a signature. Both variables,
  or neither.
- **`OAA_WINDOWS_PUBLISHER` must equal the certificate subject byte for byte.**
  Not the display name, not a tidied version of it. A mismatch fails at install
  time with `0x800B0100`, which reads as "the signature is invalid" and sends
  people to inspect the certificate rather than a string. `certutil -dump`
  prints the subject.

### The icon

```sh
dart run packaging/icon/make_icons.dart
```

Regenerates every size and shape the six platforms ask for — the four desktop
installers, Android's adaptive icon, and the layered `AppIcon.icon` that macOS
and iOS render for themselves — into the platform directories and `packaging/`. The mark is described once, as geometry,
in that file; `packaging/icon/oaa.svg` is its vector twin and carries the same
numbers, and `assets/brand/` is the same mark without its tile. The outputs are
committed, so a release runner never runs this.

## The documentation site

```sh
dart run tool/docs.dart --out build/docs
```

These pages, from the Markdown in the repository. No second toolchain: the
documents it publishes are normative and held by tests, and a site that can
break on a machine where the code is fine is a site that will.

`keyboard.md` is generated rather than written — it comes from the same table
the application binds, and `test/shortcuts_test.dart` fails if the checked-in
page has drifted:

```sh
UPDATE_DOCS=1 flutter test test/shortcuts_test.dart
```

## Contributing

The two boundaries that carry weight:

- **`engine/` knows nothing about Flutter, and `oaa_core` knows nothing about
  `dart:ffi`.** Four things need the domain vocabulary — the app, the tablet
  display, the CLI and the plugin — and three of them have no engine of their
  own.
- **One `liboaa` serves all three tiers.** That is what makes standalone,
  remote display and plugin tractable as one project rather than three.

And the rule everything else follows from: **never invent a measurement.** A
quantity the engine has not computed is `NaN` with an unavailability flag, and
the interface draws an em dash. If you are tempted to return `0.0` so something
looks right, you are about to ship a number nobody measured.

`CLAUDE.md` and the `AGENTS.md` tree in the repository carry the rest, in more
detail than a documentation page should.
