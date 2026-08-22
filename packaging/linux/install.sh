#!/bin/sh
#
# install.sh — install Open Audio Analyzer, and optionally its VST3, from the
# unpacked tarball this script sits in.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  ./install.sh [--system] [--vst3|--no-vst3] [--prefix <dir>] [--uninstall]
#
# ---------------------------------------------------------------------------
# Why this exists when there is already an AppImage and a flatpak
#
# Neither of them can install a plug-in, and the reasons are structural rather
# than missing work.
#
# An AppImage never installs anything. It is a squashfs mounted read-only for
# the life of one process; there is no install step to put a checkbox on.
#
# A flatpak *could* be granted --filesystem=~/.vst3 and write a bundle there,
# and the bundle would be useless: it is built against the runtime's glibc and
# its Qt/GTK stack, and the thing that loads it is a DAW running on the host,
# outside the sandbox, against the host's. A plug-in that loads in no host is
# not an installed plug-in.
#
# So the third Linux artefact is a tarball, and this is its installer.
#
# ---------------------------------------------------------------------------
# Why not a .deb, which is what people ask for
#
# Debian's honest equivalent of a default-ticked checkbox is `Recommends:` on
# a separate -vst3 package: apt pulls it in by default and
# --no-install-recommends declines it. That only works when both packages come
# from a *repository*. Installing a downloaded file with `apt install ./x.deb`
# resolves recommends against the configured repositories, where this package
# does not exist, so the plug-in half would simply never be found — the
# checkbox would be permanently unticked and nothing would say why.
#
# Publishing an apt repository is the fix and it is a different piece of work.
# Until then a prompt is the thing that actually asks the question.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

system=
want_vst3=
prefix=
uninstall=

while [ $# -gt 0 ]; do
  case $1 in
    --system)    system=1 ;;
    --vst3)      want_vst3=yes ;;
    --no-vst3)   want_vst3=no ;;
    --prefix)    shift; prefix=${1:?--prefix needs a directory} ;;
    --uninstall) uninstall=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "install: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$system" ]; then
  : "${prefix:=/opt/open-audio-analyzer}"
  bindir=/usr/local/bin
  datadir=/usr/share
  vst3dir=/usr/lib/vst3
  if [ "$(id -u)" -ne 0 ]; then
    echo "install: --system writes to $prefix, $bindir, $datadir and $vst3dir." >&2
    echo "  Run it with sudo, or drop --system for a home-directory install" >&2
    echo "  that needs no root and that your DAW will still find." >&2
    exit 1
  fi
else
  : "${prefix:=$HOME/.local/share/open-audio-analyzer}"
  bindir=$HOME/.local/bin
  datadir=$HOME/.local/share
  # ~/.vst3 is in the VST3 specification's search path, so every host looks
  # there without being told. It is also the only plug-in directory a user
  # with no root can write, which is most people on a machine they do not own.
  vst3dir=$HOME/.vst3
fi

desktop=$datadir/applications/com.openaudioanalyzer.oaa.desktop
metainfo=$datadir/metainfo/com.openaudioanalyzer.oaa.metainfo.xml
vst3="$vst3dir/Open Audio Analyzer.vst3"

# --- Uninstall -------------------------------------------------------------

if [ -n "$uninstall" ]; then
  # The installed copy lives inside $prefix, and the next line deletes
  # $prefix. Linux keeps the inode alive for an open file, so this usually
  # survives — "usually" being the shell's chunked reads and the reason not to
  # rely on it. Re-exec from a copy first and the question does not arise.
  case $0 in
    "$prefix"/*)
      tmp=$(mktemp "${TMPDIR:-/tmp}/oaa-uninstall.XXXXXX")
      cat "$0" >"$tmp"
      chmod +x "$tmp"
      OAA_UNINSTALL_REEXEC=1 exec "$tmp" --uninstall --prefix "$prefix" \
        ${system:+--system}
      ;;
  esac

  echo "==> removing $prefix"
  rm -rf "$prefix"
  rm -f "$bindir/open-audio-analyzer" "$desktop" "$metainfo"
  find "$datadir/icons/hicolor" -name 'com.openaudioanalyzer.oaa.png' -delete 2>/dev/null || true
  if [ -d "$vst3" ]; then
    echo "==> removing $vst3"
    rm -rf "$vst3"
  fi
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$datadir/applications" 2>/dev/null || true
  echo "==> done. Your presets and settings in ~/.config are untouched."
  exit 0
fi

[ -d "$here/app" ] || { echo "install: $here/app is missing; this tarball is incomplete." >&2; exit 1; }

# --- The question ----------------------------------------------------------
#
# Default yes, which is what the flag-free path has to be: somebody who
# downloaded a metering plug-in's installer wants the plug-in. A pipe or a CI
# job has no terminal to answer with, so it gets the default rather than a
# prompt that would hang it forever.

if [ -z "$want_vst3" ]; then
  if [ -d "$here/vst3" ] && [ -t 0 ]; then
    printf 'Install the VST3 plug-in into %s as well? [Y/n] ' "$vst3dir"
    read -r reply || reply=
    case $reply in
      [Nn]*) want_vst3=no ;;
      *)     want_vst3=yes ;;
    esac
  else
    want_vst3=yes
  fi
fi

[ -d "$here/vst3" ] || want_vst3=no

# --- The application -------------------------------------------------------

echo "==> $prefix"
rm -rf "$prefix"
mkdir -p "$prefix"
cp -R "$here/app/." "$prefix/"
chmod +x "$prefix/open-audio-analyzer"

mkdir -p "$bindir"
ln -sf "$prefix/open-audio-analyzer" "$bindir/open-audio-analyzer"

# The uninstaller is this script, kept beside what it removes. Copied from the
# tarball rather than from "$0", which may already be the temp re-exec below.
cp "$here/install.sh" "$prefix/install.sh"
chmod +x "$prefix/install.sh"

mkdir -p "$(dirname "$desktop")" "$(dirname "$metainfo")"
# Exec is rewritten to the absolute path rather than left as the bare binary
# name. ~/.local/bin is on PATH for a login shell on most distributions and on
# none of them reliably for the process that launches a .desktop entry, and an
# entry whose Exec cannot be resolved does not fail visibly — the icon is
# there and clicking it does nothing.
sed -e "s|^Exec=open-audio-analyzer|Exec=$prefix/open-audio-analyzer|" \
    -e "s|^TryExec=open-audio-analyzer|TryExec=$prefix/open-audio-analyzer|" \
    "$here/share/applications/com.openaudioanalyzer.oaa.desktop" >"$desktop"
cp "$here/share/metainfo/com.openaudioanalyzer.oaa.metainfo.xml" "$metainfo"

for icon in "$here"/share/icons/hicolor/*/apps/com.openaudioanalyzer.oaa.png; do
  [ -e "$icon" ] || continue
  size=$(basename "$(dirname "$(dirname "$icon")")")
  mkdir -p "$datadir/icons/hicolor/$size/apps"
  cp "$icon" "$datadir/icons/hicolor/$size/apps/"
done

command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$datadir/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
  gtk-update-icon-cache -qtf "$datadir/icons/hicolor" 2>/dev/null || true

# --- The plug-in -----------------------------------------------------------

if [ "$want_vst3" = yes ]; then
  echo "==> $vst3"
  mkdir -p "$vst3dir"
  rm -rf "$vst3"
  cp -R "$here/vst3/Open Audio Analyzer.vst3" "$vst3dir/"
else
  echo "==> VST3 not installed. Re-run with --vst3 to add it later."
fi

# --- What to expect --------------------------------------------------------

echo
echo "Installed."
echo "  Application  $prefix/open-audio-analyzer"
[ "$want_vst3" = yes ] && echo "  VST3         $vst3"
echo "  Uninstall    $prefix/install.sh --uninstall${system:+ --system}"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo
     echo "Note: $bindir is not on your PATH, so typing open-audio-analyzer"
     echo "      will not find it. The desktop entry works regardless." ;;
esac

if [ "$want_vst3" = yes ]; then
  echo
  echo "Your DAW scans for VST3 plug-ins at launch. One copied in while it is"
  echo "open will not appear until it is restarted or told to rescan."
fi

