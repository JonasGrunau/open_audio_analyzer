#!/bin/sh
#
# make_appimage.sh — build Open Audio Analyzer for Linux and wrap it in an
# AppImage.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/linux/make_appimage.sh [--skip-build]
# Output: build/packaging/Open Audio Analyzer-<version>-<arch>.AppImage
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
image="$out/Open Audio Analyzer-$version-$arch.AppImage"

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
install -Dm644 packaging/linux/oaa.desktop \
  "$appdir/usr/share/applications/com.openaudioanalyzer.oaa.desktop"
ln -sf usr/share/applications/com.openaudioanalyzer.oaa.desktop \
  "$appdir/com.openaudioanalyzer.oaa.desktop"

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

# --- Pack ------------------------------------------------------------------

echo "==> appimagetool"
mkdir -p "$out"
# ARCH is read by appimagetool and is not inferred from the AppDir.
ARCH="$arch" "$tool" "$appdir" "$image"
rm -rf "$appdir"

echo "$image"
