#!/bin/sh
#
# make_installer.sh — build Open Audio Analyzer for Linux and wrap it, the
# VST3 and an installer script in a tarball.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/linux/make_installer.sh [--skip-build] [--plugins <dir>]
# Output: build/packaging/Open Audio Analyzer-<version>-linux-<arch>.tar.gz
#
# <dir> holds VST3/, which is the layout both of
# plugin/build/OaaPlugin_artefacts/Release and of the oaa-plugin-Linux.tar.gz
# that ci.yml's plugin job uploads. Defaults to the first.
#
# ---------------------------------------------------------------------------
# The third Linux artefact, and why there are three
#
# The AppImage is for the machine in the live room with no flatpak runtime and
# no root. The flatpak is for a desktop that has one — it sandboxes, it
# updates, it appears in GNOME Software. Neither can install a plug-in, for
# reasons that are structural and are written out at the top of install.sh.
#
# This is the one for somebody who wants the plug-in in their DAW. It is also
# the only Linux artefact that asks a question.
#
# ---------------------------------------------------------------------------
# glibc, again
#
# The same constraint the AppImage has, and now it binds two payloads instead
# of one. A tarball built on Ubuntu 24.04 gives Debian 12 an application that
# will not start *and* a VST3 the DAW will not load, and neither says why. So
# this is built on the oldest runner in ci.yml, and — the half that was
# missing until this landed — so is the plugin job that produces the VST3 it
# packs. Those two runners have to be the same one, or the tarball has a
# floor its own halves disagree about.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
arch=$(uname -m)
bundle="build/linux/$( [ "$arch" = "aarch64" ] && echo arm64 || echo x64 )/release/bundle"
plugins="plugin/build/OaaPlugin_artefacts/Release"
out="build/packaging"
name="Open Audio Analyzer-$version-linux-$arch"
stage="$out/$name"
tarball="$out/$name.tar.gz"
skip_build=

while [ $# -gt 0 ]; do
  case $1 in
    --skip-build) skip_build=1 ;;
    --plugins)    shift; plugins=${1:?--plugins needs a directory} ;;
    *) echo "make_installer: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$skip_build" ]; then
  echo "==> flutter build linux --release"
  flutter build linux --release
fi

vst3="$plugins/VST3/Open Audio Analyzer.vst3"

if [ ! -d "$bundle" ]; then
  echo "make_installer: $bundle does not exist. Build first, or drop --skip-build." >&2
  exit 1
fi

# Required, not optional. A tarball that quietly ships without its plug-in is
# indistinguishable from one that has it until somebody opens a DAW, and the
# download page cannot tell them apart at all.
if [ ! -d "$vst3" ]; then
  echo "make_installer: $vst3 does not exist." >&2
  echo "  The plug-in is the point of this tarball. Build it with:" >&2
  echo "    cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release" >&2
  echo "    cmake --build plugin/build" >&2
  echo "  or point --plugins at an unpacked oaa-plugin-Linux.tar.gz." >&2
  exit 1
fi

mkdir -p "$out"
rm -rf "$stage" "$tarball"
mkdir -p "$stage/app" "$stage/vst3" \
         "$stage/share/applications" "$stage/share/metainfo"

cp -R "$bundle/." "$stage/app/"
cp -R "$vst3" "$stage/vst3/"
cp packaging/linux/install.sh "$stage/install.sh"
chmod +x "$stage/install.sh"

cp packaging/linux/oaa.desktop "$stage/share/applications/com.openaudioanalyzer.oaa.desktop"
cp packaging/linux/com.openaudioanalyzer.oaa.metainfo.xml "$stage/share/metainfo/"

for icon in packaging/linux/icons/*/com.openaudioanalyzer.oaa.png; do
  [ -e "$icon" ] || continue
  size=$(basename "$(dirname "$icon")")
  mkdir -p "$stage/share/icons/hicolor/$size/apps"
  cp "$icon" "$stage/share/icons/hicolor/$size/apps/"
done

# --- Licences --------------------------------------------------------------
#
# Generated rather than held, so it cannot go stale against LICENSE. The
# tarball carries binaries under two licences and the plug-in's is the stricter
# of them; a notice naming only the application's would be wrong about the
# bundle this format exists to install. It named three through 0.13.0, when the
# engine and the domain packages stopped being MIT.

{
  cat <<'NOTICE'
Open Audio Analyzer

This archive carries binaries under more than one licence:

  The application and its engine     GPL-3.0-or-later
  The VST3 plug-in                   AGPL-3.0-or-later, because it links JUCE
  The bundled fonts                  SIL OFL 1.1

Corresponding Source for every binary here is the tagged commit at
https://github.com/JonasGrunau/open_audio_analyzer, which also carries the
full text of each licence above.

The GNU General Public License, version 3, follows.

---------------------------------------------------------------------------

NOTICE
  cat LICENSE
} >"$stage/LICENSE.txt"

cat >"$stage/README.txt" <<'README'
Open Audio Analyzer

    ./install.sh

installs the application into ~/.local and asks whether to install the VST3
plug-in into ~/.vst3 as well. Neither needs root.

    ./install.sh --no-vst3        application only, no question asked
    sudo ./install.sh --system    /opt and /usr/lib/vst3, for every user
    ./install.sh --uninstall      removes what it installed

The plug-in measures what your DAW plays and streams it to the application
over 127.0.0.1, so both have to be on this machine and the application has to
be running. Your DAW scans for plug-ins at launch.
README

echo "==> tar $tarball"
# -C so the archive holds one top-level directory named after the release
# rather than the path it was built from.
tar -czf "$tarball" -C "$out" "$name"
rm -rf "$stage"

echo "$tarball"
