#!/bin/sh
#
# make_flatpak.sh — build Open Audio Analyzer for Linux and wrap it in a flatpak
# bundle.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/linux/make_flatpak.sh [--skip-build]
# Output: build/packaging/Open Audio Analyzer-<version>-<arch>.flatpak
#
# Needs `flatpak` and `flatpak-builder`, plus the Freedesktop 24.08 runtime and
# SDK. On a machine that has neither:
#
#   flatpak remote-add --if-not-exists --user \
#     flathub https://flathub.org/repo/flathub.flatpakrepo
#   flatpak install --user flathub \
#     org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08
#
# The manifest beside this script explains why Flutter is built outside the
# sandbox rather than as a flatpak-builder module. This script is the part that
# makes that split safe: it stages exactly what the manifest expects, so the
# manifest can never be run against a stale bundle without noticing.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
arch=$(uname -m)
bundle="build/linux/$( [ "$arch" = "aarch64" ] && echo arm64 || echo x64 )/release/bundle"
manifest_dir="packaging/linux/flatpak"
staging="$manifest_dir/staging"
out="build/packaging"
result="$out/Open Audio Analyzer-$version-$arch.flatpak"

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> flutter build linux --release"
  flutter build linux --release
fi

if [ ! -d "$bundle" ]; then
  echo "make_flatpak: $bundle does not exist. Build first." >&2
  exit 1
fi

# --- Stage -----------------------------------------------------------------
#
# flatpak-builder's `dir` source may not reference a path outside the manifest's
# directory, so everything the manifest installs is copied in beside it. Wiped
# first: a staging directory that accumulates is a staging directory that ships
# a file somebody deleted three releases ago.

echo "==> staging"
rm -rf "$staging"
mkdir -p "$staging"

cp -r "$bundle" "$staging/bundle"
cp packaging/linux/oaa.desktop "$staging/"
cp packaging/linux/com.openaudioanalyzer.oaa.metainfo.xml "$staging/"
cp -r packaging/linux/icons "$staging/icons"
cp LICENSE "$staging/"
mkdir -p "$staging/fonts"
cp assets/fonts/*-LICENSE.txt "$staging/fonts/" 2>/dev/null || true

# --- Build -----------------------------------------------------------------

echo "==> flatpak-builder"
mkdir -p "$out"
rm -rf "$out/flatpak-build" "$out/flatpak-repo"

flatpak-builder \
  --user \
  --disable-rofiles-fuse \
  --repo="$out/flatpak-repo" \
  --force-clean \
  "$out/flatpak-build" \
  "$manifest_dir/com.openaudioanalyzer.oaa.yml"

flatpak build-bundle \
  "$out/flatpak-repo" \
  "$result" \
  com.openaudioanalyzer.oaa

rm -rf "$staging"

echo "$result"
echo "Install with: flatpak install --user $result"
