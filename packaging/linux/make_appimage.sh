#!/bin/sh
#
# make_appimage.sh — build Open Audio Analyzer for Linux and wrap it in an
# AppImage.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/linux/make_appimage.sh [--skip-build]
# Output: build/packaging/Open.Audio.Analyzer-<version>-<arch>.AppImage
#         and its .zsync, when zsyncmake is installed
#
# ---------------------------------------------------------------------------
# What an AppImage is for here, given there is also a flatpak
#
# They answer different questions. The flatpak is for a user on a desktop that
# has one — it sandboxes, it updates, it appears in GNOME Software. The AppImage
# is for the machine in the live room that is two releases behind, has no
# flatpak runtime, and where nobody is going to be given root. It is one file,
# it is chmod +x, and it runs.
#
# The one thing it cannot do is carry glibc. An AppImage built on Ubuntu 24.04
# will not start on Debian 12 — the loader reports a version mismatch and
# nothing else. So the release workflow builds it on the **oldest** runner
# available, and that is not a detail to optimise away later.
#
# ---------------------------------------------------------------------------
# GTK is not bundled
#
# Flutter's Linux embedder links GTK 3, and bundling GTK inside an AppImage is a
# well-known way to produce something that crashes on a host whose GTK theme
# engine or GIO modules do not match the bundled ones. Open Audio Analyzer takes
# the usual trade for a GTK application: GTK is expected from the host,
# everything else travels. Every desktop Linux that can run a Flutter
# application already has it.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
arch=$(uname -m)
bundle="build/linux/$( [ "$arch" = "aarch64" ] && echo arm64 || echo x64 )/release/bundle"
out="build/packaging"
appdir="build/packaging/Open Audio Analyzer.AppDir"
# Dots, not spaces, and the only artefact named that way on disk — see
# "Update information" below.
image="$out/Open.Audio.Analyzer-$version-$arch.AppImage"

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> flutter build linux --release"
  flutter build linux --release
fi

if [ ! -d "$bundle" ]; then
  echo "make_appimage: $bundle does not exist. Build first." >&2
  exit 1
fi

# --- appimagetool ----------------------------------------------------------

tool=$(command -v appimagetool || true)
if [ -z "$tool" ]; then
  tool="$out/appimagetool"
  if [ ! -x "$tool" ]; then
    echo "==> fetching appimagetool"
    mkdir -p "$out"
    curl -fsSL -o "$tool" \
      "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$arch.AppImage"
    chmod +x "$tool"
  fi
fi

# --- AppDir ----------------------------------------------------------------

rm -rf "$appdir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/lib" "$appdir/usr/share/metainfo"

cp -r "$bundle"/* "$appdir/usr/bin/"

# The desktop file and the icon are needed twice: once where the standard says
# they live, and once at the root of the AppDir, which is where appimagetool
# looks. Symlinks rather than copies so there is one of each to edit.
#
# **`SingleMainWindow` is renamed on the way in, and only here.** It is a
# Desktop Entry 1.5 key, and desktop-file-utils learned it in 0.27; Ubuntu 22.04
# ships 0.26, which rejects it as an unknown key without an `X-` prefix. That is
# the validator AppImageHub's catalog test runs, and it refused 0.15.0 on this
# line and nothing else. So the AppImage carries GNOME's older name for the same
# hint — gnome-shell reads both — and the flatpak, which a current runtime
# validates, keeps the standard one.
desktop="$appdir/usr/share/applications/com.openaudioanalyzer.oaa.desktop"
mkdir -p "$(dirname "$desktop")"
sed 's/^SingleMainWindow=/X-GNOME-SingleWindow=/' packaging/linux/oaa.desktop >"$desktop"
chmod 644 "$desktop"
ln -sf usr/share/applications/com.openaudioanalyzer.oaa.desktop \
  "$appdir/com.openaudioanalyzer.oaa.desktop"

# The catalog's validator, run here so that a key it does not know fails the
# release instead of the catalog. `ci.yml` installs it on the same 22.04 the
# catalog tests on; a machine without it only builds.
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop"
else
  echo "make_appimage: desktop-file-validate not found, desktop entry not validated" >&2
fi

for size in 16 32 48 64 128 256 512; do
  install -Dm644 "packaging/linux/icons/${size}x${size}/com.openaudioanalyzer.oaa.png" \
    "$appdir/usr/share/icons/hicolor/${size}x${size}/apps/com.openaudioanalyzer.oaa.png"
done
cp packaging/linux/icons/256x256/com.openaudioanalyzer.oaa.png "$appdir/com.openaudioanalyzer.oaa.png"
ln -sf com.openaudioanalyzer.oaa.png "$appdir/.DirIcon"

install -Dm644 packaging/linux/com.openaudioanalyzer.oaa.metainfo.xml \
  "$appdir/usr/share/metainfo/com.openaudioanalyzer.oaa.metainfo.xml"

# The licences travel with the binary. Both bundled font families are SIL OFL
# 1.1 and their licence files must ship with anything they are embedded in.
install -Dm644 LICENSE "$appdir/usr/share/doc/oaa/LICENSE"
for licence in assets/fonts/*-LICENSE.txt; do
  [ -e "$licence" ] && install -Dm644 "$licence" "$appdir/usr/share/doc/oaa/$(basename "$licence")"
done

# AppRun. `exec` rather than a wrapper that lingers, and $APPDIR resolved from
# $0 rather than from the environment: an AppImage run through a launcher that
# does not set APPDIR would otherwise load the host's libraries.
cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$here/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "$here/usr/bin/open-audio-analyzer" "$@"
APPRUN
chmod +x "$appdir/AppRun"

# --- Update information ----------------------------------------------------
#
# What lets AppImageUpdate, and anything built on it, replace this file with the
# next release: a string embedded in the image saying where to look, and a
# .zsync published beside it saying which blocks changed. appimagetool writes
# both, and the .zsync only if `zsyncmake` is on the PATH — without it the
# string is embedded anyway, naming a file no release will carry, and nothing
# fails. So the string goes in only when the file can come out with it, and on
# CI, where releases are built, a missing zsyncmake is an error rather than an
# AppImage that cannot update.
#
# **The name has dots instead of spaces, and only this one does.** The .zsync
# records the AppImage's file name, and the updater fetches that name from
# beside it. Every other script here writes spaces and lets GitHub turn them
# into dots on upload (packaging/AGENTS.md), so a .zsync naming the spaced file
# would send every update to a 404. Written dotted, the name the build produces
# is the name the release page serves.

repo=${GITHUB_REPOSITORY:-JonasGrunau/open_audio_analyzer}
update=""
if command -v zsyncmake >/dev/null 2>&1; then
  update="gh-releases-zsync|${repo%%/*}|${repo#*/}|latest|Open.Audio.Analyzer-*-$arch.AppImage.zsync"
elif [ -n "${CI:-}" ]; then
  echo "make_appimage: zsyncmake not found; the AppImage would carry no update information" >&2
  exit 1
else
  echo "make_appimage: zsyncmake not found, building without update information" >&2
fi

# --- Pack ------------------------------------------------------------------

echo "==> appimagetool"
mkdir -p "$out"
# ARCH is read by appimagetool and is not inferred from the AppDir.
if [ -n "$update" ]; then
  zsync="$(basename "$image").zsync"
  rm -f "$zsync" "$out/$zsync"
  ARCH="$arch" "$tool" -u "$update" "$appdir" "$image"
  # zsyncmake writes into the working directory rather than beside its input.
  [ -f "$zsync" ] && mv "$zsync" "$out/"
  if [ ! -f "$out/$zsync" ]; then
    echo "make_appimage: appimagetool wrote no $zsync" >&2
    exit 1
  fi
else
  ARCH="$arch" "$tool" "$appdir" "$image"
fi
rm -rf "$appdir"

echo "$image"
