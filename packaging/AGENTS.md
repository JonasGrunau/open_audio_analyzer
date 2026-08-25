# packaging/

Everything that turns a build into something a user can install.
GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `icon/make_icons.dart` | The mark, read from `assets/brand/oaa-logo.svg` and rendered into every container the six platforms ask for — flat PNGs for the desktops, Android's adaptive icon, and one layered `AppIcon.icon` document per Apple platform. Carries a path rasteriser, because the mark is a stroked cubic path and no longer four rectangles. Writes into the platform directories, into `assets/brand/` and into `website/public/`, as well as this one. |
| `icon/oaa.svg` | Generated. The same mark as a vector, with the tile and the ramp — a byte-identical copy of `assets/brand/oaa-icon.svg`. It was the one hand-maintained duplicate in this repository until 0.10.0, annotated with the numbers it had been transcribed from; it is written now. It is *not* installed into Linux's `scalable` hicolor directory: see the comment in the flatpak manifest. |
| `android/play_store_icon.png` | Generated. 512 px, full bleed, no alpha. The Play Console asks for it by hand at upload; it is not built into the aab. |
| `macos/make_pkg.sh` | Build, sign, three component packages, one distribution, and hand the result to `notarize.sh`. Replaced `make_dmg.sh`: a disk image can carry a plug-in but cannot install one. |
| `macos/pkg/distribution.xml` | The installer's interface — the three rows, which of them is greyed out, and the macOS version gate on the two that are not. |
| `macos/pkg/scripts/postinstall` | Attached to the Audio Unit component only. Kills `AudioComponentRegistrar` so Logic sees the plug-in without a logout. |
| `macos/keychain.sh` | Imports a Developer ID `.p12` into a keychain of its own, for a machine that has none — a CI runner. One `.p12` carries both certificates: Application signs code, Installer signs a pkg, and only the first satisfies the codesigning policy — so the script verifies with the *basic* policy and fails when an identity secret names one the file does not hold. Refuses to run outside CI without `OAA_KEYCHAIN_FORCE`, because it *replaces* the login keychain search list. |
| `macos/notarize.sh` | Submit, wait, staple, verify. Takes a pkg or any number of bundles, and is the only implementation of this — the plugin's macOS bundles go through it too, from `ci.yml`. |
| `ios/make_ipa.sh` | Build and export the iPad build as an App Store IPA. The only script here whose output nobody downloads — see the rule below. Injects manual signing through `ios/Flutter/Release.xcconfig` so the Xcode project stays on automatic signing for whoever develops here. |
| `ios/testflight.sh` | Upload that IPA to App Store Connect. Split from the build because `ci.yml` runs it *after* the release is published. |
| `ios/screenshots.sh` | The App Store screenshots, six of them, into `build/packaging/screenshots/`. Runs the application on a 13-inch iPad simulator and drives it with the **fake DAW**: a simulator app binds the host's loopback, so `plugin/host/` plays a real track through the real plugin into the port the app listens on and every reading in the pictures is one the engine took. Its header documents the three things the tooling cannot do — rotate, tap, or keep an orientation across a reboot — and what stands in for each. |
| `ios/app-store.md` | The listing text: name, subtitle, keywords, description, and the rest of the submission. Kept here so it moves with the build it describes; nothing reads it. |
| `windows/oaa.iss` | The Inno Setup script: the components, the VST3 destination, the uninstaller. Compiled by the script below, never opened in the IDE — the paths it needs are staged first. |
| `windows/make_installer.ps1` | Build, stage, `signtool`, `iscc`, `signtool` again. Replaced `make_msix.ps1`: an msix cannot write the shared VST3 directory, so it could not carry the plug-in. |
| `linux/oaa.desktop` | The desktop entry, shared by the AppImage and the flatpak. |
| `linux/com.openaudioanalyzer.oaa.metainfo.xml` | AppStream metadata. Required by flatpak, read by GNOME Software and KDE Discover. |
| `linux/icons/` | Generated hicolor PNGs. |
| `linux/make_appimage.sh` | Build, AppDir, `appimagetool`. Application only — an AppImage never installs anything. |
| `linux/make_installer.sh` | Build, stage the bundle and the VST3, tar. The only Linux artefact that carries the plug-in. |
| `linux/install.sh` | Ships *inside* that tarball and is what asks the question. Also the uninstaller, kept beside what it installed. |
| `linux/make_flatpak.sh` | Build, stage, `flatpak-builder`, bundle. |
| `linux/flatpak/com.openaudioanalyzer.oaa.yml` | The flatpak manifest. Packages a bundle that was already built. |

Output always lands in `build/packaging/`. `ci.yml`'s packaging jobs run all
five desktop artefacts, and the IPA, on a tag and on demand; only the upload
waits for the release.

**The name on disk is not the name a user downloads.** Every script here writes
`Open Audio Analyzer-<version>-…`, with spaces, and nothing renames it —
GitHub substitutes a dot for each space when the file is attached to a release,
so the asset is `Open.Audio.Analyzer-<version>-macos.pkg`. That dotted form is
what `README.md`'s Installing table and `docs/site/install.md` quote, because it
is what the download link says; the spaced form is what a `find` in the publish
step has to survive, which is why that step reads its asset list NUL-delimited.
The two are the same file, and a change to either half of the name has to be
made in both places.

Three of the five carry the plug-in and install it behind a checkbox — the
`pkg`, the Windows `.exe` and the Linux tarball. They therefore cannot be
built from the application alone, and their `ci.yml` jobs — `macos-pkg`,
`windows-installer` and `linux-tarball` — `needs: plugin` and unpack the
bundles that job already signed and notarised. The AppImage and the
flatpak are the application on its own, because neither format can install a
plug-in into a host DAW's search path; see the header of `linux/install.sh`.

## Rules

- **The IPA is the one artefact here that a user cannot install, and that is
  what it is for.** An App Store signature provisions no devices: the file
  cannot be sideloaded, handed to a tester, or re-signed by whoever downloaded
  it. It exists to be uploaded, so `ci.yml` keeps it off the release's asset
  list — publishing an installer that installs nothing is worse than publishing
  nothing. Every other script in this directory produces a file somebody opens.

- **An App Store IPA has no unsigned form**, so `make_ipa.sh` is the one script
  here that breaks the rule below it: with no credentials it produces *nothing*
  and says so, rather than an unsigned artefact. There is no unsigned IPA to
  produce — an archive that fails to export is not a lesser version of one that
  did.

- **Manual signing is injected through `ios/Flutter/Release.xcconfig`, never
  into the Xcode project.** The Runner target stays on automatic signing so that
  `flutter run -d <ipad>` keeps working for a person with their own Apple ID. A
  runner has none, and automatic signing there reaches out to *create* a
  distribution certificate — an account caps how many may exist, so a workflow
  doing it every release either fails on the cap or consumes it, and neither
  failure names the cause. The xcconfig is the Release configuration's base
  configuration, so Xcode reads it when it archives and
  `xcodebuild -showBuildSettings` reports it, which is where `flutter build ipa`
  looks; Debug is untouched.

  **A key the target sets itself is not read from there at all**, and that is
  how `OAA_IOS_TEAM_ID` came to be decorative for a release. The Runner target's
  Release configuration carried its own `DEVELOPMENT_TEAM`, and a setting in a
  target's `buildSettings` outranks the same key arriving from its
  `baseConfigurationReference`. `CODE_SIGN_STYLE` and
  `PROVISIONING_PROFILE_SPECIFIER` are absent from that configuration and took
  effect, so the archive was manually signed against the right profile name and
  the *project's* team — and Xcode reported
  `No profile for team 'X' matching 'Y' found` with the correct profile
  installed, valid, and for a team nothing was looking under. The line is gone
  from the Release configuration; Debug and Profile keep theirs, which is what
  `flutter run` uses. Opening Signing & Capabilities in Xcode is enough to write
  it back, which is why `make_ipa.sh` now holds the profile's own team against
  the one it is about to write rather than trusting the xcconfig to win.

- **There is no hand-written `ExportOptions.plist`, deliberately.** Xcode 15.4
  renamed the export methods — `app-store` became `app-store-connect` — and a
  plist naming the wrong one for the Xcode on the runner fails the export.
  `flutter build ipa --export-method app-store` asks Xcode its version and
  writes whichever string it wants, and fills in the provisioning profile's UUID
  as well. It only does that when `CODE_SIGN_STYLE=Manual`,
  `PROVISIONING_PROFILE_SPECIFIER` and `DEVELOPMENT_TEAM` are all visible in the
  build settings; when they are not it falls back to a plist holding nothing but
  the method, exports with automatic signing, and logs that at trace level.
  `make_ipa.sh` reads the authority off the archive afterwards for exactly that
  reason — the fallback is not an error and does not fail the build.

- **The profile is installed into both provisioning-profile directories.**
  Xcode 16 and Flutter 3.44 read
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles`; everything before
  them read `~/Library/MobileDevice/Provisioning Profiles`. Installing into one
  works on exactly one side of that boundary, and getting it wrong presents as
  the silent automatic-signing fallback above rather than as a missing file.

- **A rejection from App Store Connect arrives after the release is published**,
  which is why `make_ipa.sh` checks the profile itself: the bundle id it names,
  that it provisions no devices, that it does not allow debugging, and that the
  team it was issued to is the team the build is configured for. A
  development or ad-hoc profile exports an IPA that builds, signs and verifies
  cleanly and is refused at the end of the upload. `ITMS-90717` — the icon alpha
  channel described below — is the same shape of failure and was found the same
  way: months later, in front of the store.

- **One mark, three shapes, and the phones are the reason.** The desktop
  artwork *is* the rounded tile, with transparent corners, because nothing
  masks it. iOS masks with its own superellipse and **rejects an icon that has
  an alpha channel at all** — ITMS-90717, raised on upload rather than at build
  time, so an icon that is opaque but still four channels wide passes every
  check on this machine and fails months later in front of the store. Its
  artwork is therefore square, full bleed and written as RGB. Android composites
  a background and a foreground and then crops the outer 18dp of a 108dp canvas
  for parallax, so its foreground is the wave alone, scaled into the middle 72.
  `_Shape` in `make_icons.dart` names the two shapes this program rasterises;
  Android's layers are VectorDrawables and Apple's are SVGs, all built from the
  same path. Adding a platform means asking which of the three shapes it is,
  not adding a fourth set of PNGs.

- **Apple gets a layered document, and that is why there is no `appearances`
  block anywhere here.** macOS 26 and iOS 26 render an icon rather than display
  one: they light the layers themselves and derive the dark and the tinted
  appearance from the same file. A flat PNG is composited already, so there is
  nothing left to light and nothing to re-tint. Crucially `actool` also emits
  the flat renditions an older OS wants — a `.icns` at macOS 10.15, sized PNGs
  at iOS 15 — so `AppIcon.icon` *replaces* the appiconset rather than sitting
  beside it, and two assets both named AppIcon would be a build error. Writing
  dark and tinted PNGs by hand as well would be a second source for pixels
  `actool` already derives, which is the drift this directory exists to prevent.

- **`icon.json`'s `fill` takes a system material, never your own gradient.**
  Handed one, `actool` does not report a bad key — it throws an exception and
  dies with a backtrace out of `IBICAbstractPlatformAdapter`, which reads like a
  broken toolchain rather than a typo. The ramp is therefore a layer, which is
  what Apple's own sample icons do with their backgrounds.

- **The mark does not survive 16 px any more, and the four bars did.** They
  were two pixels wide with a one-pixel cap and still read as four bars at four
  heights with one of them in trouble; a wave with nine excursions across twelve
  pixels reads as a smudge, and no stroke width fixes it — thickening closes the
  gaps and makes a blob. `_Tile.strokeFloorPx` holds the line at one device
  pixel so that it is at least *white* rather than a grey smear, which is the
  most that can be done, and the sizes that decide this icon are now 32 and up.
  The 16 px entries in the .ico and the hicolor tree are still written, because
  Windows and the flatpak ask for them; what they carry is the ramp and a
  silhouette. **Do not "fix" this by drawing a second, simpler mark for small
  sizes** — two marks are two identities, and the one people see first is
  whichever they happen to meet first.

- **The corner is a superellipse, not a circular arc.** `_Tile.squircle` is the
  exponent and `_Tile.corner` the radius, and the numbers are Apple's icon grid:
  the edge stays straight for longer and then turns harder than a rounded
  rectangle does. `_tileCoverage` evaluates the real curve, because a scanline
  of it is one interval; `_tilePath` fits six cubics per corner for the
  consumers that want a path, to 0.085% of the side. Neither Apple platform sees
  either — both mask the icon with their own curve — so this is for Windows,
  Linux, Android's legacy launcher and the image in the README.

- **Every script says whether what it produced can actually be installed.**
  Signing needs secrets a fork does not have, so the absence of a certificate
  produces an unsigned artefact and a warning rather than a failure — but the
  warning is specific, because "signed" and "installable" are not the same
  thing on any of the three platforms. A build that implied success would be
  worse than one that failed.

- **A signed but un-notarised package is still refused by Gatekeeper.** The
  quarantine flag needs notarisation, not merely a signature. `make_pkg.sh`
  distinguishes all three states in what it prints, because the middle one is
  the surprising one.

- **A pkg is signed by a `Developer ID Installer` certificate, which is not
  the one that signs code.** `productbuild --sign` handed a `Developer ID
  Application` identity fails with "no identity found", naming a certificate
  that is in the keychain and is simply the wrong type. Both travel in one
  `.p12`; `keychain.sh` verifies that each identity a job names is actually
  in it, because an installer certificate does not satisfy the codesigning
  policy and so never appears in `security find-identity -p codesigning`.

- **`pkgbuild` makes every bundle relocatable unless told not to.** The
  Installer then asks Spotlight where that bundle identifier already lives and
  writes the payload *there* — so a stale copy of the app in `~/Downloads`
  receives the update and `/Applications` keeps the old one, and the install
  reports success. `make_pkg.sh` turns the flag off through a component
  plist. Verified: without it the app component carries
  `<relocate><bundle id="com.openaudioanalyzer.oaa"/></relocate>`.

- **A notarisation secret that a runner cannot use looks exactly like one it
  can.** `OAA_NOTARY_PROFILE` names a profile in a *machine's* keychain, so
  `ci.yml` read that secret for three releases, found nothing behind it, took
  the un-notarised branch and published. Same shape of failure as the missing
  certificate import next to it: the name of a credential is not the
  credential. `notarize.sh` accepts the runner-shaped form as well and says
  which one it used.

- **An Authenticode signature does not remove SmartScreen.** A standard OV
  certificate still produces "Windows protected your PC" until the installer
  has accumulated download reputation, which takes weeks and resets when the
  certificate is replaced. Only EV carries reputation from the first download.
  So an unsigned installer and a freshly-signed one look identical to the
  first person who runs either — which is why shipping unsigned is a
  defensible state here and shipping an unsigned *pkg* is not. The warning is
  overridable by the user in both directions; macOS's plug-in refusal is not.

- **`OAA_WINDOWS_CERT` names a file and a runner has no file.** Same shape as
  `OAA_NOTARY_PROFILE` above. `make_installer.ps1` takes
  `OAA_WINDOWS_CERT_BASE64` as well and writes it out, which is the form CI
  can be given.

- **The Mac App Store is not a target and this is not a gap.** It requires the
  app sandbox, and a sandboxed Open Audio Analyzer has its `HOME` redirected
  into `~/Library/Containers`, which is what put everybody's presets somewhere
  no user goes looking. See the header of `macos/Runner/*.entitlements` and the
  top of `make_pkg.sh` — that second copy is deliberate, because the signing
  script is where somebody is standing when the question occurs to them.

- **Every Linux binary is built on the oldest supported runner.** glibc is
  forward-compatible and not backward-compatible: one built on a newer
  distribution refuses to start on an older one, with a loader error and nothing
  else. `ci.yml` pins `ubuntu-22.04` for the AppImage, the tarball **and the
  plugin job's Linux leg** — that last one ran on `ubuntu-latest` for six
  releases, so the Linux application and the Linux VST3 shipped with different
  floors and only one of them was chosen. A plug-in the loader refuses is not
  even a loader error: it is a plug-in absent from the DAW's browser, which is
  what installing it in the wrong folder also looks like. Moving any of the
  three forward silently narrows who can run Open Audio Analyzer.

- **The flatpak does not build Flutter.** `flatpak-builder` runs with no
  network, which is the point of it; Flutter's build resolves pub packages and
  downloads engine artefacts. Every attempt to reconcile the two produces either
  a manifest with network access — not a reproducible build, only a slower one —
  or a hand-mirrored pub cache that goes stale. So the manifest packages a
  bundle built outside it, and `make_flatpak.sh` is what makes that split safe.

- **The icons are generated and committed.** Thirty-odd files across four
  containers, exported by hand, drift: somebody changes the mark, updates the
  four sizes they were looking at, and the Start menu stays a year behind the
  Dock. A release runner never runs `make_icons.dart`; it reads what is
  committed.

- **Licences travel with the binary.** Every script copies `LICENSE` and both
  font licences into the package. Inter and Google Sans Code are SIL OFL 1.1 and
  their licence files must ship with anything they are embedded in.
