#!/bin/sh
#
# make_store_graphics.sh — render the Play Store feature graphic.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/android/make_store_graphics.sh
#
# Writes packaging/android/play_store_feature_graphic.png and the twin of it in
# assets/brand/, both committed. Run it after editing feature_graphic.html, or
# after any change to the palette or the two faces it is set in.
#
# ---------------------------------------------------------------------------
# What this does *not* do, and where that lives instead
#
# The **app icon** is not rendered here. `packaging/icon/make_icons.dart` draws
# every icon this repository ships from `assets/brand/oaa-logo.svg`, and the
# Play icon is one line in it like the other sixty — the whole point of that
# program is that no icon is exported by a second route. Change the mark, run
# that, and `play_store_icon.png` moves with the Dock icon and the launcher
# icon rather than a year behind them.
#
# The feature graphic is not an icon: it is a card with the product's name set
# on it, which the rasteriser in `make_icons.dart` cannot do — it fills paths,
# and a name is a font. So this is the second route, it is deliberately for the
# one asset that needs type, and it renders a page in a browser the way
# `website/scripts/og.html` does. The two assets are still generated, still
# committed, and still have exactly one source each.
#
# ---------------------------------------------------------------------------
# Why the checks at the bottom are the point of the script
#
# Google states the feature graphic as **1024 x 500** and **24 bit PNG with no
# alpha**, and the Play Console enforces both at upload — months of listing
# work in, in a browser, by hand. A headless Chrome screenshot happens to
# satisfy them today; nothing guarantees the next Chrome does, and an alpha
# channel is invisible in every viewer on this machine. So the IHDR is read
# back off the finished file and the script fails on it rather than handing
# over an asset that the Console will refuse. This is the same shape as the
# `codesign --verify` in `plugin/CMakeLists.txt` and the profile check in
# `ios/make_ipa.sh`: produce the artefact, then prove it is the artefact.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
page="$root/packaging/android/feature_graphic.html"
out="$root/build/packaging/play_store_feature_graphic.png"

width=1024
height=500

# ---------------------------------------------------------------------------
# Chrome
#
# Named rather than searched for on a PATH: this runs by hand, on a person's
# machine, and "which Chrome did it use" is a question a person can answer only
# if the script says. The Linux names are there because the website's own
# `npm run og` has the macOS one hard-coded and that has already cost somebody
# an afternoon.

chrome=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "$(command -v google-chrome 2>/dev/null || true)" \
  "$(command -v google-chrome-stable 2>/dev/null || true)" \
  "$(command -v chromium 2>/dev/null || true)" \
  "$(command -v chromium-browser 2>/dev/null || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    chrome=$candidate
    break
  fi
done

if [ -z "$chrome" ]; then
  echo "make_store_graphics.sh: no Chrome or Chromium found." >&2
  echo "  The feature graphic is a page, and a page needs a browser to render." >&2
  echo "  Install Google Chrome, or point this script at a Chromium build." >&2
  exit 1
fi

echo "Rendering with: $chrome"
mkdir -p "$(dirname "$out")"
rm -f "$out"

# --allow-file-access-from-files lets the page reach ../../assets/fonts/ over
# file://. Without it the card renders in whatever Chrome falls back to, which
# is a card in the wrong typeface and no error anywhere.
"$chrome" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --allow-file-access-from-files \
  --window-size="$width,$height" \
  --virtual-time-budget=6000 \
  --screenshot="$out" \
  "file://$page" 2>/dev/null || true

if [ ! -f "$out" ]; then
  echo "make_store_graphics.sh: Chrome wrote no file." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read the IHDR back. Bytes 16..25 of a PNG are width, height, bit depth and
# colour type, in that order; colour type 2 is RGB and 6 is RGBA.

ihdr=$(od -An -tu1 -j16 -N10 "$out" | tr -s ' ' | sed 's/^ //')
got_w=$(echo "$ihdr" | cut -d' ' -f1-4 | tr ' ' '\n' | awk '{ n = n * 256 + $1 } END { print n }')
got_h=$(echo "$ihdr" | cut -d' ' -f5-8 | tr ' ' '\n' | awk '{ n = n * 256 + $1 } END { print n }')
depth=$(echo "$ihdr" | cut -d' ' -f9)
colour=$(echo "$ihdr" | cut -d' ' -f10)

fail=0
if [ "$got_w" != "$width" ] || [ "$got_h" != "$height" ]; then
  echo "make_store_graphics.sh: rendered ${got_w}x${got_h}, Play wants ${width}x${height}." >&2
  fail=1
fi
if [ "$colour" != "2" ]; then
  echo "make_store_graphics.sh: PNG colour type $colour; Play wants 2 (24 bit, no alpha)." >&2
  echo "  Chrome writes an alpha channel when the page has a transparent" >&2
  echo "  background. Give <body> an opaque colour." >&2
  fail=1
fi
if [ "$depth" != "8" ]; then
  echo "make_store_graphics.sh: PNG bit depth $depth; Play wants 8." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# 15 MB is Play's cap. A flat card is three orders of magnitude under it, so
# this only ever fires if the composition grew a photograph.
bytes=$(wc -c < "$out" | tr -d ' ')
if [ "$bytes" -gt 15728640 ]; then
  echo "make_store_graphics.sh: $bytes bytes; Play's cap is 15 MB." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Install. Two destinations, byte identical, for the reason written beside the
# Play icon in `packaging/icon/make_icons.dart`: one is where somebody filling
# in the store listing looks, the other is where this repository keeps the
# artwork it publishes.

cp "$out" "$root/packaging/android/play_store_feature_graphic.png"
cp "$out" "$root/assets/brand/play-store-feature-graphic.png"

printf '  %7d  packaging/android/play_store_feature_graphic.png\n' "$bytes"
printf '  %7d  assets/brand/play-store-feature-graphic.png\n' "$bytes"
echo "Done. ${got_w}x${got_h}, 8 bit, colour type $colour (no alpha)."
