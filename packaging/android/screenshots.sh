#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Play Store screenshots for the Android build.
#
# Writes 2048x1145 PNGs into packaging/android/screenshots/ — a 10-inch
# tablet in landscape, which is the form factor this build is for. Play wants a
# minimum of two screenshots across device types; this takes three.
#
# Into the repository rather than build/, for the reason `ios/screenshots.sh`
# gives: these are what the store is given, nothing in CI can take them, and a
# set kept under `build/packaging/` was one clean away from being gone. They are
# committed and a run overwrites them in place.
#
# ---------------------------------------------------------------------------
# Why the meters are measuring something
#
# The same reason, and the same machinery, as `packaging/ios/screenshots.sh`:
# an emulator has no audio input, so a screenshot taken the obvious way is a
# photograph of the built-in test tone — one spike in the spectrum, a flat
# histogram, and every validator row red. That tells a reader nothing about
# what the application does, and for a metering tool it is worse than nothing:
# a screenshot of invented readings is a lie about the product's one job.
#
# So this drives the shipped path. `plugin/host/`'s fake DAW plays the CC BY
# track through the real VST3, the plugin dials 47822, and the application
# accepts it — the same link a DAW insert uses. Every number in these pictures
# was measured by the engine.
#
# ---------------------------------------------------------------------------
# Four things Android does differently from the iPad, each of which produced a
# wrong picture before it was handled
#
# **An emulator is not on the host's network stack.** This is the big one. An
# iOS simulator app is a macOS process, so the port it binds *is* the host's
# loopback and the fake DAW finds it with nothing configured. An Android
# emulator sits behind its own NAT: the app binds 127.0.0.1:47822 *inside* the
# emulator, and `PluginLink` binds `InternetAddress.loopbackIPv4` rather than
# any-address, so nothing outside can reach it however the routing is arranged.
# `adb forward tcp:47822 tcp:47822` is the bridge — it listens on the host and
# connects to the device's own loopback, which is exactly the shape needed.
#
# **The application must be running before the fake DAW starts.** The DAW dials
# once and exits when the connection drops. Restart the app underneath it and
# the canvas silently falls back to the test tone — the source pill reads TEST
# TONE and 48.0 kHz instead of the plugin and 44.1 kHz, and everything else
# still looks plausible. That is checked below rather than assumed.
#
# **A real 10-inch tablet is too short for this canvas.** At 1280x800 dp — a
# Pixel Tablet — the six readouts along the top row render the words TOO SMALL
# instead of a number, because the default layout wants roughly the iPad Pro's
# 1376x1032 pt. The density is therefore set to 200 rather than the panel's
# own, which buys 1638x1024 dp on the same pixels. Worth knowing as a layout
# finding and not only as a screenshot workaround: the default preset does not
# fit a short tablet.
#
# **The system bars cannot be turned off.** `policy_control=immersive.full`
# was removed in Android 11 and does nothing on 16 — it fails silently, which
# is the worst way for it to fail. Nor can the bars be read off the window:
# Flutter draws edge-to-edge, so the activity's frame is the whole display and
# the bars are composited over it. `dumpsys` does carry an `InsetsFrameProvider`
# per bar, but it lists a set of per-rotation variants (top=156, bottom=70 and
# 166 here) and none of them was the 65 px the panel actually showed.
#
# So the bars are cropped, and the crop is *measured off the picture* — bar
# heights move with the density, the panel and the Android version. The measure
# is the **median** brightness of each row, and that detail is the whole of it:
# both bars carry content, a clock at the top and six launcher icons at the
# bottom, so a mean is dragged about by them and a min/max spread is dominated
# by them outright. The first version of this used spread, cut at the first
# glyph of the clock, and left the entire status bar and taskbar in a picture
# that otherwise looked finished. A median reports the background the glyphs
# sit on, which is the thing that actually changes at a bar's edge.
#
# The script fails rather than writing a picture whose measured crop is not
# plausible, and the sizes are checked against Play's rules at the end. The
# taskbar is the one that matters: it carries Chrome and Phone icons, which is
# other people's branding on our store page.
#
# The capture is 2048x1280 so that the crop still clears Play's floor. Tablet
# screenshots must be between 1080 and 7680 px on a side, with the long side no
# more than twice the short one; 2048x1145 is 1.79:1 with 65 px to spare.
#
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - The Android SDK, with an AVD. Any will do — the display is overridden.
#   - A built fake DAW (see plugin/host/AGENTS.md) and the CC BY track:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#       dart run tool/fetch_test_audio.dart
#   - Nothing else on port 47822 — not the desktop application, not another
#     emulator. The check below says so rather than photographing a tone.

set -eu

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
AVD="${OAA_AVD:-}"
PKG=com.openaudioanalyzer.oaa
TRACK=test_audio/citizens-apathy.flac
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
OUT=packaging/android/screenshots
APK=build/app/outputs/flutter-apk/app-release.apk

# 1280x2048 at density 200 is 1024x1638 dp. See the header for both numbers.
SIZE=1280x2048
DENSITY=200

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "${DAW_PID:-}" ] && kill "$DAW_PID" 2>/dev/null || true
  "$ADB" forward --remove-all 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[ -x "$ADB" ] || die "No adb at $ADB. Set ANDROID_SDK_ROOT."
[ -f "$TRACK" ] || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW — build the plugin first, see the header."

# An `adb` on this port is *our own* forward, left by a run that did not reach
# its trap — killed, or interrupted. Clearing it is right; refusing to start
# because of it would make every interrupted run poison the next one, which is
# exactly what happened the first time this script was run twice.
if lsof -nP -iTCP:47822 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1 !~ /^adb/' | grep -q .; then
  die "Something already holds 47822 — the desktop application, or another emulator.
  Quit it: the plugin would stream there instead and these pictures would be of
  somebody else's canvas, or of a test tone."
fi
[ -x "$ADB" ] && "$ADB" forward --remove-all >/dev/null 2>&1 || true

# --- A device ---------------------------------------------------------------

if ! "$ADB" shell true >/dev/null 2>&1; then
  [ -n "$AVD" ] || AVD=$("$EMULATOR" -list-avds 2>/dev/null | head -1)
  [ -n "$AVD" ] || die "No AVD. Create one in Android Studio, or set OAA_AVD."
  say "==> booting $AVD"
  "$EMULATOR" -avd "$AVD" -no-snapshot -no-boot-anim -gpu auto >/tmp/oaa-emulator.log 2>&1 &
  i=0
  while [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; do
    i=$((i + 1)); [ "$i" -gt 60 ] && die "The emulator did not boot; see /tmp/oaa-emulator.log"
    sleep 5
  done
fi
say "==> device: $("$ADB" devices | sed -n 2p | cut -f1)"

# --- The display ------------------------------------------------------------

"$ADB" shell wm size "$SIZE" >/dev/null
"$ADB" shell wm density "$DENSITY" >/dev/null
"$ADB" shell settings put system accelerometer_rotation 0 >/dev/null
"$ADB" shell settings put system user_rotation 1 >/dev/null
sleep 3
say "==> display: $SIZE at $DENSITY dpi, landscape"

# --- The application, then the plugin, in that order -------------------------

[ -f "$APK" ] || die "No $APK. Run: flutter build apk --release
  A release build, deliberately: a debug one paints a DEBUG ribbon across the
  corner of every screenshot."

say "==> installing"
# The reason is printed, not swallowed. The one that actually happens is a
# full /data — an emulator that has had this 70 MB apk installed a dozen times
# runs out, and `install failed` on its own sends you looking at the apk.
if ! out=$("$ADB" install -r -d "$APK" 2>&1); then
  printf '%s\n' "$out" | tail -3 >&2
  "$ADB" shell df /data 2>/dev/null | tail -1 >&2
  die "install failed — if /data is near full, run: $ADB uninstall $PKG"
fi

"$ADB" shell am force-stop "$PKG" >/dev/null
sleep 2
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 14

# 47822 is BACE hex, and /proc/net/tcp is the only place to see it from here.
"$ADB" shell "cat /proc/net/tcp" 2>/dev/null | grep -qi '0100007F:BACE' \
  || die "The application is not listening on 47822 inside the emulator."

"$ADB" forward --remove-all >/dev/null 2>&1 || true
"$ADB" forward tcp:47822 tcp:47822 >/dev/null
say "==> forwarded host 47822 into the emulator"

say "==> starting the fake DAW"
"$FAKE_DAW" --track="$TRACK" --headless --speed=1 --seconds=420 --play >/tmp/oaa-daw.log 2>&1 &
DAW_PID=$!
sleep 12
kill -0 "$DAW_PID" 2>/dev/null || die "The fake DAW exited immediately — see /tmp/oaa-daw.log"
lsof -nP -iTCP:47822 -sTCP:ESTABLISHED >/dev/null 2>&1 \
  || die "The plugin never connected. Without it the canvas meters its test tone."

say "==> letting the meters fill"
sleep 25

# --- The pictures -----------------------------------------------------------

mkdir -p "$OUT"

crop() { # crop <file>
  python3 - "$1" <<'PY'
import sys
from PIL import Image

path = sys.argv[1]
im = Image.open(path)
w, h = im.size
# Measured on a greyscale copy, cropped and written from the original. Doing
# both on one converted image writes greyscale screenshots — which is not
# obviously wrong on the spectrum tab, and is very wrong on the loudness one.
px = im.convert("L").load()


def median(y):
    """The background level of one row.

    The **median** and not the mean, and this is the whole trick. Both bars
    carry content — a clock and status glyphs at the top, six launcher icons at
    the bottom — so a mean is dragged around by them and a min/max spread is
    dominated by them outright. The first attempt used spread and cut at the
    clock, leaving the entire status bar in the picture. A median ignores
    sparse glyphs and reports the background they sit on, which is the thing
    that actually changes at a bar's edge.
    """
    vals = sorted(px[x, y] for x in range(0, w, 4))
    return vals[len(vals) // 2]


# The status bar's background is the panel's own black; the application's
# chrome above the canvas is a lighter grey. The first row that differs from
# row zero is where the application starts.
base = median(0)
top = 0
for y in range(0, h // 4):
    if abs(median(y) - base) > 3:
        top = y
        break

# The taskbar is near-white. The last dark row is the application's last.
bottom = h
for y in range(h - 1, h // 2, -1):
    if median(y) < 100:
        bottom = y + 1
        break

height = bottom - top
if height < 1080 or top > h // 4 or bottom < h // 2:
    sys.exit(
        f"{path}: measured a crop of {w}x{height} (rows {top}..{bottom}), which is "
        "not plausible. The bars moved; do not ship this."
    )

im.crop((0, top, w, bottom)).save(path)
print(f"    {w}x{height}  (cropped rows {top}..{bottom})")
PY
}

shot() { # shot <name>
  sleep 4
  "$ADB" exec-out screencap -p > "$OUT/$1.png"
  say "  $1.png"
  crop "$OUT/$1.png"
}

# Tap targets are in the rotated display's own pixels — what `input tap`
# takes. Note they are *uncropped* coordinates: a target read off a finished
# screenshot is short by the status bar's height and lands above what it aimed
# at.
tap() { "$ADB" shell input tap "$1" "$2" >/dev/null; sleep 3; }

shot 01-loudness

tap 358 143          # the SPECTRUM tab
shot 02-spectrum

tap 245 143          # back to LOUDNESS
tap 1838 90          # SETTINGS, which opens over the canvas
shot 03-settings

say ""
say "==> $OUT"
ls -1 "$OUT"/*.png | sed 's/^/    /'
say ""
say "Play wants at least two, between 1080 and 7680 px a side, long side no more"
say "than twice the short one. What was written:"
python3 - "$OUT" <<'PY'
import sys, glob, os
from PIL import Image
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.png"))):
    w, h = Image.open(f).size
    lo, hi = min(w, h), max(w, h)
    ok = 1080 <= lo and hi <= 7680 and hi <= 2 * lo
    bad += 0 if ok else 1
    print(f"    {os.path.basename(f):26} {w}x{h}  {hi/lo:.2f}:1  {'ok' if ok else 'REJECTED BY PLAY'}")
sys.exit(1 if bad else 0)
PY
