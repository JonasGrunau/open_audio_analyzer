#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# A photograph of the whole desktop application, metering real audio.
#
# Writes build/packaging/screenshots/desktop.png — the window as a person sees
# it, chrome and all: the status bar naming the plugin as the source, the
# transport clock, the delivery target, the tab strip, and the canvas of modules
# under them. `website/scripts/render-flow.mjs` picks it up as the middle plate
# of the front page's signal path.
#
# ---------------------------------------------------------------------------
# Why this is not a headless render
#
# The website already has one picture of the canvas — `public/analyzer-still.webp`,
# shot out of `tools/analyzer-demo` through a headless Chrome — and it is a
# picture of the *modules*, not of the application. It has no title bar, no
# status bar, no tab strip and no ATTACH button, because the demo is eight
# modules on a `GridGeometry` and nothing else. It is the right picture for the
# hero, where the subject is the meters. It is the wrong one for a section whose
# whole claim is "this is the program on your desk", and it was the picture that
# section shipped with until somebody looked at it and said so.
#
# So this drives the real signed application, on a real window server, and
# photographs the window. There is no way to do that without a machine.
#
# ---------------------------------------------------------------------------
# What it needs, and what each refusal looks like
#
#   - **Screen Recording**, granted to whichever terminal runs this. Without it
#     `screencapture` returns a frame that is entirely black and exits 0 — see
#     CLAUDE.md. `CGPreflightScreenCaptureAccess` is checked up front so that a
#     denial reads as a denial rather than as a broken app.
#   - **Accessibility**, same terminal. The window is placed and sized through
#     System Events, because the application restores whatever geometry it was
#     last left at and a screenshot whose size depends on that is not a
#     screenshot anybody can reproduce.
#   - The release build: `flutter build macos --release`. **Check what it says
#     it is** — a stale bundle photographs an old version convincingly, and the
#     one this replaced was four minor versions behind.
#   - The fake DAW and the VST3, which is the full plugin build:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#   - `test_audio/citizens-apathy.flac`: `dart run tool/fetch_test_audio.dart`.
#   - Port 47822 free. The application binds it and the plugin dials it; a copy
#     of either already running takes the link and this photographs a canvas
#     reading dashes.
#
# Usage: sh packaging/macos/screenshot.sh
set -eu

APP="build/macos/Build/Products/Release/Open Audio Analyzer.app"
OUT="build/packaging/screenshots"
TRACK="test_audio/citizens-apathy.flac"
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
WORK="$(mktemp -d)"

# The window, in points. Wide enough that the default canvas' four columns of
# modules each get room to draw their scales, and 16:10 so the plate it becomes
# sits beside the other two without one of them towering over the rest.
WIN_W=1560
WIN_H=980

# How much programme to let through before the shutter.
#
# **This number is paired with the one in packaging/ios/screenshots.sh** and is
# not free to move on its own. Both pictures end up side by side in the
# website's signal-path section, under a paragraph that says the meter across
# the room cannot disagree with the one under your hand — and the first version
# of them was shot at 44 seconds here and 76 there, so the desktop read −17.0
# LUFS-I and the iPad read −15.2 directly beneath that sentence.
#
# They do not have to be simultaneous, and they cannot be: the plugin dials one
# address and only one application can hold 47822. They have to be at the same
# *transport position*, which is enough, because the engine is deterministic —
# the same audio from the same start is the same reading. That script waits 6
# seconds for the link and then 70 more; this one has about two seconds of
# window lookup and capture after the wait. Hence 74.
SETTLE=74

cleanup() {
  [ -n "${DAW_PID:-}" ] && kill "$DAW_PID" 2>/dev/null || true
  osascript -e 'tell application "Open Audio Analyzer" to quit' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ -d "$APP" ]      || die "No release build at $APP. Run: flutter build macos --release"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW. Build the plugin first — see the header."
[ -f "$TRACK" ]    || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"

if lsof -nP -iTCP:47822 >/dev/null 2>&1; then
  die "Something is already on port 47822. Close the application and any fake DAW first."
fi

# ---------------------------------------------------------------------------
# The one helper that is not shell
#
# The window id, from the public window list. `kCGWindowBounds` is available to
# anyone; it is the window *image* that Screen Recording gates, which is why the
# preflight below is a separate question from this one.

cat > "$WORK/window.swift" <<'SWIFT'
import CoreGraphics
import Foundation

guard CGPreflightScreenCaptureAccess() else {
  FileHandle.standardError.write(
    "no Screen Recording permission: grant it to this terminal in System Settings\n"
      .data(using: .utf8)!)
  exit(3)
}
guard let list = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
  exit(1)
}
for w in list {
  guard let owner = w[kCGWindowOwnerName as String] as? String,
        owner == "Open Audio Analyzer",
        let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
        let id = w[kCGWindowNumber as String] as? Int else { continue }
  print(id)
  exit(0)
}
FileHandle.standardError.write("no Open Audio Analyzer window on screen\n".data(using: .utf8)!)
exit(1)
SWIFT

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# The application, on a configuration directory of its own
#
# `--config-dir` so the canvas is the default layout rather than whatever this
# machine was last left looking at, and so nothing here writes over somebody's
# real session. See lib/src/app/launch_options.dart.
#
# `open` and not the binary inside the bundle: macOS attributes Local Network
# permission to the *responsible* process, and a bare exec of the executable is
# refused where the bundle is allowed. That refusal looks like a plugin that
# never connects.

say "Starting the application..."
rm -rf "$WORK/config"
mkdir -p "$WORK/config"
open "$APP" --args --config-dir="$WORK/config"

sleep 6

osascript >/dev/null 2>&1 <<OSA || die "Could not place the window. Grant Accessibility to this terminal."
tell application "System Events"
  tell process "Open Audio Analyzer"
    set frontmost to true
    set position of window 1 to {80, 60}
    set size of window 1 to {$WIN_W, $WIN_H}
  end tell
end tell
OSA

sleep 2

# ---------------------------------------------------------------------------
# The audio
#
# The shipped path, exactly as packaging/ios/screenshots.sh uses it: the fake
# DAW plays the track through the real VST3, the plugin dials 127.0.0.1:47822,
# and the application accepts it — the same link a DAW insert makes. Every
# number in the picture was measured by the engine from that file.

"$FAKE_DAW" --track="$TRACK" --headless --speed=1 --seconds=420 --play >/dev/null 2>&1 &
DAW_PID=$!
sleep 6
kill -0 "$DAW_PID" 2>/dev/null || die "The fake DAW exited immediately — run it by hand to see why."

# **Wait for the pair, then start counting.** The settle above is transport time,
# and it is only transport time if the link is up when the clock starts. Without
# this the script waited its 74 seconds from the moment the *process* launched,
# and a run where the application took a while to bind 47822 — because a
# simulator still held it, say — photographed a canvas that had been receiving
# for one second: −50.2 LUFS-I, an empty histogram, and dashes where the range
# should be. It looked like a broken application rather than like a mistimed
# script.
say "Waiting for the plugin to connect..."
waited=0
# Matched on the *plugin* end of the pair, not the application's. lsof prints
# this application as `Open\x20A` — the column is truncated and the space is
# escaped — so the obvious grep for its name matches nothing, waits the full
# thirty seconds and reports a plugin that is in fact connected.
until lsof -nP -iTCP:47822 -sTCP:ESTABLISHED 2>/dev/null | grep -q "oaa-fake-"; do
  sleep 1
  waited=$((waited + 1))
  [ "$waited" -ge 30 ] && die "The plugin never connected on 47822 — check the notice on the canvas."
done

say "Playing $SETTLE s of programme through the plugin..."
sleep "$SETTLE"

# **The application must be frontmost the whole time, and this is the check that
# says so.** Flutter pauses its ticker when the window is not visible, and this
# application repaints — and consumes the plugin's stream — from exactly one
# ticker. Occlude it and the canvas stops taking measurements silently: the link
# stays up, the format still reads 44.1 kHz, and the transport sits at
# 00:00:00:00 for as long as you leave it. Bring it forward and it catches up in
# a burst, which is worse than either, because the numbers are then right while
# the histogram's minute of history arrived in two seconds.
#
# So this refuses rather than photographing it. If it fires, something took the
# foreground during the wait — which on a machine somebody is using is simply
# what happens. Run it when the machine is free.
FRONT="$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null || true)"
[ "$FRONT" = "Open Audio Analyzer" ] || die "\
$(printf '%s' "Something else took the foreground during the wait ($FRONT).")
  The canvas stops measuring when it is not visible, so the picture would show
  a transport that never moved. Run this with the machine to itself."

WINDOW_ID="$(swift "$WORK/window.swift")" || exit 1

# `-o` drops the drop shadow, which is 40-odd transparent pixels a side that the
# site would have to crop back off; `-x` silences the shutter.
screencapture -x -o -l "$WINDOW_ID" "$OUT/desktop.png"

[ -s "$OUT/desktop.png" ] || die "screencapture wrote nothing."

say ""
say "  $OUT/desktop.png  $(sips -g pixelWidth -g pixelHeight "$OUT/desktop.png" \
  | awk '/pixel/ {printf "%s ", $2}')"
say ""
say "  Next: cd website && npm run flow -- --only=desktop"
