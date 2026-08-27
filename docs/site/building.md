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

Four Flutter plugins are pulled in: `desktop_drop` and `file_selector` to get a
path from a user, `flutter_riverpod` for configuration, and `mobile_scanner`
(MIT) for the host picker's QR scanner. The last is the one with a native half
that is not vendored here, and the one that does not ship everywhere — Android,
iOS and macOS only, which `canScanQrCodes` asks before drawing the row. It
integrates through Swift Package Manager, so there is still no `Podfile` in
this repository and nothing to `pod install`. The QR *encoder* on the other
side of the same feature is written here rather than depended on, in
`packages/oaa_ui/lib/src/qr.dart`.

There is **no podspec, no `build.gradle` and no per-platform `CMakeLists.txt`**
for the application. `packages/oaa_engine/hook/build.dart` compiles the C
through `native_toolchain_c` and bundles it as a code asset. One build
description that works on five platforms beats five that each work on one.

`engine/CMakeLists.txt` describes the *same* compile for consumers that are not
Dart — the plugin, and a CI runner with no Flutter SDK. Two descriptions of one
compile is a real cost, paid deliberately: `plugin/test/sources_match.sh` fails
the build if the two source lists drift apart, so **a new file in `engine/src`
goes in both.**

## Linux dependencies

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
conformance cases, and a red conformance run is a red build.

The official vector files are a separate, manual run — they may not be
redistributed, so they are not a gate:

```sh
cd packages/oaa_engine
OAA_VECTORS=~/ebu-loudness-test-set OAA_VECTORS_ITU=~/bs2217 \
  dart test test/vectors_test.dart
```

The EBU set is at <https://tech.ebu.ch/publications/ebu_loudness_test_set> and
the ITU's at <https://www.itu.int/oth/R1102000001/en>. Either group skips when
its variable is unset. Run this after touching the engine's loudness,
K-weighting or true-peak code.

## Running with a different configuration

Two flags, both useful while working on the interface:

```sh
flutter run -d macos --dart-entrypoint-args --config-dir=/tmp/oaa-scratch
flutter run -d macos --dart-entrypoint-args --open-panel=settings
```

`--config-dir` points settings, presets, targets and skins somewhere
disposable, so an experiment cannot eat the configuration you actually use.
`--open-panel` opens one panel once the first frame is up — `settings`,
`calibration`, `theme`, `report` or `shortcuts` — which is how a panel gets
looked at without clicking through to it. There is no `presets`: presets are
documents now, opened and saved through the platform's own dialogs from the File
menu, and a native panel is not something a screenshot run can drive. It is a debug-build affordance and a
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
install. [Install](install.html#in-a-daw) says which folder that is on each
platform. JUCE is fetched and pinned, not vendored, so a fresh clone builds
without checking out a framework by hand.

On macOS each bundle is signed once it is fully built, then verified with
`codesign --verify --strict`, which fails the build rather than producing a
bundle a DAW would refuse. Signing is ad-hoc; `-DOAA_CODESIGN_IDENTITY=<id>`
uses a Developer ID instead, and adds the hardened runtime and a secure
timestamp, both of which notarisation requires and neither of which is a
default. A bundle you built yourself carries no quarantine flag, so nothing has
to be stripped from it.

The bundles are built for **arm64 and x86_64, targeting macOS 14.2**. Both are
CMake variables whose defaults are the machine doing the build, which is how
every release up to 0.5.0 shipped an arm64-only plugin that also refused to load
on any macOS older than the runner's. Pass
`-DCMAKE_OSX_ARCHITECTURES=arm64` for a build you will only ever load on the
machine that made it — it halves the compile.

`plugin/` is the one **AGPL-3.0-or-later** directory, because JUCE 7 and 8 are
AGPL-or-commercial. Nothing there may move into `engine/` or `oaa_core/`, which
are MIT and must stay linkable by people who are not writing free software.

## Installers

One script per artefact, under `packaging/`. Each builds the application first
unless told to skip it, and each says plainly whether what it produced can
actually be installed.

```sh
sh   packaging/macos/make_pkg.sh          # carries the VST3 and the AU
pwsh packaging/windows/make_installer.ps1 # carries the VST3
sh   packaging/linux/make_installer.sh    # carries the VST3
sh   packaging/linux/make_appimage.sh     # application only
sh   packaging/linux/make_flatpak.sh      # application only
sh   packaging/ios/make_ipa.sh            # the iPad build, for TestFlight
sh   packaging/ios/testflight.sh          # and the upload, separately
sh   packaging/android/make_aab.sh        # the Android bundle, for Play
sh   packaging/android/play_store.sh      # and that upload, separately
```

Everything lands in `build/packaging/`.

**The first three need the plugin bundles and refuse to run without them**, on
the grounds that an installer quietly missing the thing it exists to install
looks exactly like one that has it. Build them first, or point the script at an
unpacked release archive:

```sh
cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
sh packaging/macos/make_pkg.sh                      # finds plugin/build itself
sh packaging/macos/make_pkg.sh --plugins ./unpacked # or an oaa-plugin-*.tar.gz
```

In CI they take the second route: the `macos-pkg`, `windows-installer` and
`linux-tarball` jobs `needs: plugin` and unpack the bundles that job already
signed and notarised, rather than building a second copy of the same code.

Signing is by environment variable, and every script produces an unsigned
artefact and warns rather than failing when the variables are absent — a fork
has no secrets, and a build that stopped there would be useless to it. **The
IPA is the one exception**, because there is no unsigned form of it: an App
Store export either has a distribution signature or does not exist, so
`make_ipa.sh` produces nothing at all and says so. **The Android bundle is the
near-miss**: it builds perfectly well with no upload key, because Gradle falls
back to the debug key so that `flutter run --release` keeps working — so
`make_aab.sh` builds it, reads back which certificate actually signed it, and
discards the bundle rather than offering something Play will reject by
fingerprint.

| Variable | For |
| --- | --- |
| `OAA_SIGNING_IDENTITY` | macOS Developer ID, e.g. `Developer ID Application: Name (TEAMID)`. Signs code — the app, the VST3 and the Audio Unit. It does **not** sign the package that carries them; that is the identity below |
| `OAA_INSTALLER_IDENTITY` | The *other* macOS Developer ID, e.g. `Developer ID Installer: Name (TEAMID)`. A distinct certificate from the one above and not interchangeable with it — that one signs code, this one signs a `.pkg` and nothing else. `keychain.sh` fails when this names an identity the `.p12` does not contain, rather than letting the run reach `productbuild` and stop there |
| `OAA_NOTARY_PROFILE` | A `xcrun notarytool store-credentials` profile. Your own machine only — it lives in *that machine's* keychain, so a CI runner given this name finds nothing |
| `OAA_NOTARY_APPLE_ID`, `OAA_NOTARY_TEAM_ID`, `OAA_NOTARY_PASSWORD` | The same credentials in a form a runner can be handed. The password is an [app-specific password](https://support.apple.com/en-us/102654), not the Apple ID's own |
| `OAA_SIGNING_CERTIFICATE`, `OAA_SIGNING_CERTIFICATE_PASSWORD` | base64 of a `.p12` and its export password, for a machine whose keychain is empty. One file holds **every** Developer ID identity the release signs with — select them all in Keychain Access → My Certificates and Export Items in a single pass, because a second secret would be a second thing to rotate. `packaging/macos/keychain.sh` imports it; on your own Mac use Keychain Access and skip both |
| `OAA_IOS_CERTIFICATE`, `OAA_IOS_CERTIFICATE_PASSWORD` | base64 of a `.p12` holding an **Apple Distribution** certificate, and its export password. A different certificate type from the Developer ID above and not interchangeable with it — one signs a Mac app for direct download, the other signs an iOS app for the store. `keychain.sh` imports either |
| `OAA_IOS_PROFILE` | base64 of an **App Store** `.mobileprovision` for `com.openaudioanalyzer.oaa`. A development or ad-hoc profile exports an IPA that builds, signs and verifies cleanly and is refused at the end of the upload, so `make_ipa.sh` checks the profile before it builds |
| `OAA_IOS_TEAM_ID`, `OAA_IOS_SIGNING_IDENTITY` | Optional. They default to the team in the Xcode project and to `Apple Distribution`, which matches whichever such certificate the keychain holds. Set the team when the profile was created under a different one from the project's — `make_ipa.sh` compares the two before it builds, because a mismatch presents as Xcode finding no profile at all. Neither takes quotes: the value is written into an xcconfig verbatim, where a stray `"` is part of the setting |
| `OAA_ASC_KEY_ID`, `OAA_ASC_ISSUER_ID`, `OAA_ASC_KEY` | An App Store Connect **API key** — its id, the issuer uuid, and base64 of the `.p8`. Needed by `testflight.sh`, which uploads with it and then writes the release notes with it, and by nothing else. The key needs the **App Manager** role or both are refused with a permissions error that names no role |
| `OAA_ASC_NOTES_WAIT` | Optional. Seconds to wait for App Store Connect to finish processing the build, `900` by default. A build is not a resource until it has processed, and What to Test belongs to the build — so writing it means waiting for it to appear. `0` is one look rather than none, which is what a build named by hand wants. A timeout is not an error: the upload stands and only the note is missing |
| `OAA_BUILD_NUMBER` | Optional. `CFBundleVersion` for the iPad build; unset, `pubspec.yaml`'s `+N` is used. CI passes the workflow run counter, because App Store Connect refuses a build number it has already accepted for the same version string |
| `OAA_ANDROID_KEYSTORE`, `OAA_ANDROID_KEYSTORE_PASSWORD`, `OAA_ANDROID_KEY_ALIAS` | base64 of the Android **upload key** — a PKCS#12 or JKS keystore — its password, and the alias of the key pair inside it. Not the app signing key: Play App Signing is mandatory for apps created since 2021, so Google holds that one and re-signs what you upload. An upload key can be reset if you lose it, which is the point of the split |
| `OAA_ANDROID_KEY_PASSWORD` | Optional. Defaults to the keystore password, which is what `keytool` gives you if you press return at its second prompt |
| `OAA_ANDROID_KEY_PROPERTIES` | Optional. Path to a Flutter-style `key.properties` instead of the three secrets above; `android/key.properties` is the default and is git-ignored. `make_aab.sh` writes one under `$RUNNER_TEMP` so that no credential lands in the checkout |
| `OAA_PLAY_SERVICE_ACCOUNT` | A Google service account's JSON key, base64 or raw — `play_store.sh` takes either. It needs the **Release manager** role granted in the Play Console under Users and permissions; a Google Cloud IAM role is a different thing and is not enough on its own |
| `OAA_PLAY_TRACK`, `OAA_PLAY_STATUS` | Optional. `internal` and `completed` unset; this repository's track is set to `alpha`, which is Play's name for the closed test. In CI these are repository *variables* rather than secrets, because a track is a routing decision and not a credential — readable and changeable on the settings page without editing a workflow |
| `OAA_WINDOWS_CERT` | Path to a `.pfx`. Your own machine — a runner has no file to point at |
| `OAA_WINDOWS_CERT_BASE64` | base64 of that same `.pfx`, which is the form CI can be handed. Used in preference to the path when both are set |
| `OAA_WINDOWS_CERT_PASS` | The export password, for either form |

Five things that will otherwise cost you an afternoon:

- **A signed but un-notarised download is still refused by Gatekeeper.** The
  quarantine flag needs notarisation, not merely a signature. This is true of
  the plugin bundles as well as the pkg, and the plugin's version of the
  refusal is worse: a modal with nothing in System Settings to override it,
  because "Open Anyway" is only offered for a blocked launch and loading a
  plugin is a library load. An identity and notarisation credentials, or
  neither.
- **An App Store rejection arrives after the release is published.** The iOS
  path has no equivalent of `codesign --verify`: `flutter build ipa` exits 0 on
  an export that fell back to automatic signing, and App Store Connect is the
  first thing that says no — during an upload that `ci.yml` deliberately runs
  *after* the release exists. `make_ipa.sh` therefore checks what it can before
  and after the build: the profile's bundle id, that it provisions no devices
  and allows no debugging, and then the signing authority read back off the
  finished archive. Run it once by hand, or with `workflow_dispatch`, before
  trusting a tag to it — a dispatch builds and signs the IPA and does not
  upload, which is the useful half of the check.
- **Google Play will not let you undo anything.** A version code it has
  accepted can never be reused, and never lowered — so a failed release that
  had already uploaded burns the number the retry wanted. That is why `ci.yml`
  runs `play-store` *after* `publish`, and why the version code comes from the
  workflow's run counter rather than `pubspec.yaml`'s `+N`, which is
  maintained by hand and collides on a re-run of a tag. Two more things the API
  simply cannot do: create the app — the package name has to exist in the
  Console first, made by a person — and publish to a track before the Console's
  own checklist (store listing, content rating, data safety, target audience)
  is complete.
- **A pkg needs a `Developer ID Installer` certificate, which is not the one
  that signs code.** `productbuild --sign` given a `Developer ID Application`
  identity fails with "no identity found", naming a certificate that is in the
  keychain and is merely the wrong type. Both live in one `.p12`, and
  `keychain.sh` now fails if an identity a job names is not in it — an
  installer certificate never appears in
  `security find-identity -p codesigning`, so the import used to look correct
  while being half missing.
- **Signing the Windows installer does not remove SmartScreen.** An ordinary
  OV certificate still produces "Windows protected your PC" until the file
  accumulates download reputation, which takes weeks and resets whenever the
  certificate does; only EV carries reputation from the first download. Current
  releases are unsigned and warn, which is a state a user can click through —
  unlike the macOS plugin refusal, which they cannot.

### The icon

```sh
dart run packaging/icon/make_icons.dart
```

Regenerates every size and shape the six platforms ask for — the five desktop
downloads, Android's adaptive icon, and the layered `AppIcon.icon` that macOS
and iOS render for themselves — into the platform directories, `packaging/`,
`assets/brand/` and `website/public/`.

The mark is *read*, not described: `assets/brand/oaa-logo.svg` is the drawing,
and everything else — the icon with its tile, the mark on its own, the ramp on
its own, the favicon the site serves — is written from it. Redraw that one file
and run this; nothing is brought across by hand. The outputs are committed, so
a release runner never runs this.

The Play Store's own icon comes out of the same run, as
`packaging/android/play_store_icon.png`. It is the only icon here written full
bleed *and* with an alpha channel: Play rounds it in its own interface, so
rounding it first would round it twice, and Play asks for 32 bits where Apple
rejects any icon that has an alpha channel at all.

### The store graphics

```sh
sh packaging/android/make_store_graphics.sh
```

Renders the Play Store feature graphic — the wide card at the top of the store
listing, which the German Play Console calls the *Vorstellungsgrafik* — into
`packaging/android/` and `assets/brand/`. It needs Chrome or Chromium on the
machine and nothing else.

It is a second route to a generated asset, and the one asset that justifies
one: the card has the product's name set on it, and the rasteriser in
`make_icons.dart` fills paths rather than setting type. So the card is a page —
`packaging/android/feature_graphic.html`, laid out in the application's own two
faces and painted in the palette's own values — and the script screenshots it.
Edit the page, run the script, commit both PNGs.

Play states this asset as 1024 × 500 and a 24-bit PNG with no alpha, and the
Console enforces both by hand at upload time, months of listing work in. So the
script reads the dimensions, the bit depth and the colour type back off the
finished file and fails on them rather than handing over something the Console
will refuse.

## The website, and these pages

```sh
cd website
npm ci
npm run build            # the site, into website/dist
npm run deploy           # the same, plus the live analyzer, to Cloudflare
```

These pages are part of the site: `/docs` renders the Markdown in the
repository where it is written, rather than a copy of it. A document that the
manifest names and the disk does not fails this build, which is what keeps a
renamed page from quietly disappearing.

CI builds the site on every event and deploys it on a push to `main`, so
`npm run deploy` by hand is for a change you want live before it lands.

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
