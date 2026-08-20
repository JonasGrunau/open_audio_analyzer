# packaging/

Everything that turns a build into something a user can install.
GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `icon/make_icons.dart` | The mark, as geometry, rendered into every container the six platforms ask for — flat PNGs for the desktops, Android's adaptive icon, and one layered `AppIcon.icon` document per Apple platform. Writes into the platform directories as well as this one. |
| `icon/oaa.svg` | The same mark as a vector, with the tile and the gradient, for `README.md`. **The one deliberate duplicate here** — its numbers are derived from `make_icons.dart` and are annotated as such. It is *not* installed into Linux's `scalable` hicolor directory: see the comment in the flatpak manifest. |
| `android/play_store_icon.png` | Generated. 512 px, full bleed, no alpha. The Play Console asks for it by hand at upload; it is not built into the aab. |
| `macos/make_dmg.sh` | Build, sign, notarise, disk image. |
| `windows/AppxManifest.xml` | The msix manifest, with two placeholders. |
| `windows/make_msix.ps1` | Build, stage, `makeappx`, `signtool`. |
| `windows/images/` | Generated msix logos. |
| `linux/oaa.desktop` | The desktop entry, shared by the AppImage and the flatpak. |
| `linux/dev.openaudioanalyzer.oaa.metainfo.xml` | AppStream metadata. Required by flatpak, read by GNOME Software and KDE Discover. |
| `linux/icons/` | Generated hicolor PNGs. |
| `linux/make_appimage.sh` | Build, AppDir, `appimagetool`. |
| `linux/make_flatpak.sh` | Build, stage, `flatpak-builder`, bundle. |
| `linux/flatpak/dev.openaudioanalyzer.oaa.yml` | The flatpak manifest. Packages a bundle that was already built. |

Output always lands in `build/packaging/`. `ci.yml`'s packaging jobs run
all four on a tag and on demand.

## Rules

- **One mark, three shapes, and the phones are the reason.** The desktop
  artwork *is* the rounded tile, with transparent corners, because nothing
  masks it. iOS masks with its own superellipse and **rejects an icon that has
  an alpha channel at all** — ITMS-90717, raised on upload rather than at build
  time, so an icon that is opaque but still four channels wide passes every
  check on this machine and fails months later in front of the store. Its
  artwork is therefore square, full bleed and written as RGB. Android composites
  a background and a foreground and then crops the outer 18dp of a 108dp canvas
  for parallax, so its foreground is the bars alone, inset to the middle 72.
  `_Shape` in `make_icons.dart` names the two shapes this program rasterises;
  Android's layers are VectorDrawables and Apple's are SVGs, all built from the
  same numbers. Adding a platform means asking which of the three shapes it is,
  not adding a fourth set of PNGs.

- **Apple gets a layered document, and that is why there is no `appearances`
  block anywhere here.** macOS 26 and iOS 26 render an icon rather than display
  one: they light the layers themselves and derive the dark and the tinted
  appearance from the same file. A flat PNG is composited already, so there is
  nothing left to light and nothing to re-tint. Crucially `actool` also emits
  the flat renditions an older OS wants — a `.icns` at macOS 10.15, sized PNGs
  at iOS 13 — so `AppIcon.icon` *replaces* the appiconset rather than sitting
  beside it, and two assets both named AppIcon would be a build error. Writing
  dark and tinted PNGs by hand as well would be a second source for pixels
  `actool` already derives, which is the drift this directory exists to prevent.

- **`icon.json`'s `fill` takes a system material, never your own gradient.**
  Handed one, `actool` does not report a bad key — it throws an exception and
  dies with a backtrace out of `IBICAbstractPlatformAdapter`, which reads like a
  broken toolchain rather than a typo. The graphite ground is therefore a layer,
  which is what Apple's own sample icons do with their backgrounds.

- **The mark's bars do not climb in order, and that is load-bearing.** Four
  bars rising left to right is the cellular signal glyph, drawn that way in the
  status bar of every phone this icon sits on, and the shape is what the eye
  reads — not the colour. The valley at the third bar is what makes it a meter.
  `_Mark.tallest` finds the peak instead of assuming it is the last bar, so the
  heights can move without anything else having to.

- **Every script says whether what it produced can actually be installed.**
  Signing needs secrets a fork does not have, so the absence of a certificate
  produces an unsigned artefact and a warning rather than a failure — but the
  warning is specific, because "signed" and "installable" are not the same
  thing on any of the three platforms. A build that implied success would be
  worse than one that failed.

- **A signed but un-notarised dmg is still refused by Gatekeeper.** The
  quarantine flag needs notarisation, not merely a signature. `make_dmg.sh`
  distinguishes all three states in what it prints, because the middle one is
  the surprising one.

- **`OAA_WINDOWS_PUBLISHER` must equal the certificate's subject byte for
  byte.** A mismatch fails at *install* time with `0x800B0100`, which reads as
  "the signature is invalid" and sends people to inspect the certificate rather
  than a string.

- **The Mac App Store is not a target and this is not a gap.** It requires the
  app sandbox, and a sandboxed Open Audio Analyzer has its `HOME` redirected
  into `~/Library/Containers`, which is what put everybody's presets somewhere
  no user goes looking. See the header of `macos/Runner/*.entitlements` and the
  top of `make_dmg.sh` — that second copy is deliberate, because the signing
  script is where somebody is standing when the question occurs to them.

- **The AppImage is built on the oldest supported runner.** glibc is
  forward-compatible and not backward-compatible: one built on a newer
  distribution refuses to start on an older one, with a loader error and nothing
  else. `ci.yml` pins `ubuntu-22.04` for that job, and moving it forward
  silently narrows who can run Open Audio Analyzer.

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
