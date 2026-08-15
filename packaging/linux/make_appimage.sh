#!/bin/sh
#
# make_appimage.sh — build Bel for Linux and wrap it in an AppImage.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/linux/make_appimage.sh [--skip-build]
# Output: build/packaging/Bel-<version>-<arch>.AppImage
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
# Flutter's Linux embedder links GTK 3, and bundling GTK inside an AppImage is
# a well-known way to produce something that crashes on a host whose GTK theme
# engine or GIO modules do not match the bundled ones. Bel takes the usual trade
# for a GTK application: GTK is expected from the host, everything else travels.
# Every desktop Linux that can run a Flutter application already has it.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
arch=$(uname -m)
bundle="build/linux/$( [ "$arch" = "aarch64" ] && echo arm64 || echo x64 )/release/bundle"
out="build/packaging"
appdir="build/packaging/Bel.AppDir"
image="$out/Bel-$version-$arch.AppImage"

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
install -Dm644 packaging/linux/bel.desktop \
  "$appdir/usr/share/applications/dev.belmeter.bel.desktop"
ln -sf usr/share/applications/dev.belmeter.bel.desktop \
  "$appdir/dev.belmeter.bel.desktop"

for size in 16 32 48 64 128 256 512; do
  install -Dm644 "packaging/linux/icons/${size}x${size}/dev.belmeter.bel.png" \
    "$appdir/usr/share/icons/hicolor/${size}x${size}/apps/dev.belmeter.bel.png"
done
cp packaging/linux/icons/256x256/dev.belmeter.bel.png "$appdir/dev.belmeter.bel.png"
ln -sf dev.belmeter.bel.png "$appdir/.DirIcon"

install -Dm644 packaging/linux/dev.belmeter.bel.metainfo.xml \
  "$appdir/usr/share/metainfo/dev.belmeter.bel.metainfo.xml"

# The licences travel with the binary. Both bundled font families are SIL OFL
# 1.1 and their licence files must ship with anything they are embedded in.
install -Dm644 LICENSE "$appdir/usr/share/doc/bel/LICENSE"
for licence in assets/fonts/*-LICENSE.txt; do
  [ -e "$licence" ] && install -Dm644 "$licence" "$appdir/usr/share/doc/bel/$(basename "$licence")"
done

# AppRun. `exec` rather than a wrapper that lingers, and $APPDIR resolved from
# $0 rather than from the environment: an AppImage run through a launcher that
# does not set APPDIR would otherwise load the host's libraries.
cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$here/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "$here/usr/bin/bel" "$@"
APPRUN
chmod +x "$appdir/AppRun"

# --- Pack ------------------------------------------------------------------

echo "==> appimagetool"
mkdir -p "$out"
# ARCH is read by appimagetool and is not inferred from the AppDir.
ARCH="$arch" "$tool" "$appdir" "$image"
rm -rf "$appdir"

echo "$image"
