# packaging/

Everything that turns a build into something a user can install.
GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `icon/make_icons.dart` | The mark, as geometry, rendered to every size the four installers ask for. Writes into the platform directories as well as this one. |
| `icon/bel.svg` | The same mark as a vector, for Linux's `scalable` hicolor directory. **The one deliberate duplicate here** — its numbers are derived from `make_icons.dart` and are annotated as such. |
| `macos/make_dmg.sh` | Build, sign, notarise, disk image. |
| `windows/AppxManifest.xml` | The msix manifest, with two placeholders. |
| `windows/make_msix.ps1` | Build, stage, `makeappx`, `signtool`. |
| `windows/images/` | Generated msix logos. |
| `linux/bel.desktop` | The desktop entry, shared by the AppImage and the flatpak. |
| `linux/dev.belmeter.bel.metainfo.xml` | AppStream metadata. Required by flatpak, read by GNOME Software and KDE Discover. |
| `linux/icons/` | Generated hicolor PNGs. |
| `linux/make_appimage.sh` | Build, AppDir, `appimagetool`. |
| `linux/make_flatpak.sh` | Build, stage, `flatpak-builder`, bundle. |
| `linux/flatpak/dev.belmeter.bel.yml` | The flatpak manifest. Packages a bundle that was already built. |

Output always lands in `build/packaging/`. `.github/workflows/release.yml` runs
all four on a tag and on demand.

## Rules

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

- **`BEL_WINDOWS_PUBLISHER` must equal the certificate's subject byte for
  byte.** A mismatch fails at *install* time with `0x800B0100`, which reads as
  "the signature is invalid" and sends people to inspect the certificate rather
  than a string.

- **The Mac App Store is not a target and this is not a gap.** It requires the
  app sandbox, and a sandboxed Bel has its `HOME` redirected into
  `~/Library/Containers`, which is what put everybody's presets somewhere no
  user goes looking. See the header of `macos/Runner/*.entitlements` and the top
  of `make_dmg.sh` — that second copy is deliberate, because the signing script
  is where somebody is standing when the question occurs to them.

- **The AppImage is built on the oldest supported runner.** glibc is
  forward-compatible and not backward-compatible: one built on a newer
  distribution refuses to start on an older one, with a loader error and nothing
  else. `release.yml` pins `ubuntu-22.04` for that job, and moving it forward
  silently narrows who can run Bel.

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
