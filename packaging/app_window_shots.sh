#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The two photographs of the application's own window: the Loudness tab and the
# Spectrum tab, whole, with the window's chrome around them.
#
# Writes packaging/screenshots/window-loudness.png and
# .../window-spectrum.png. `website/scripts/render-window.mjs` encodes both into
# `website/public/window/`.
#
# ---------------------------------------------------------------------------
# Why this exists beside signal_path.sh
#
# Everything the website shows of the canvas is cropped to the meters:
# `analyzer-still.webp` is a Flutter *web* build photographed through headless
# Chrome, so there is no window around it at all, and the module thumbnails are
# one module each. The signal-path plates do show the window, but they show it
# doing one specific thing — publishing to a tablet, with PUBLISH lit — because
# that is what the paragraph beside them is about.
#
# What was missing was the ordinary thing: the application as somebody opening
# it sees it, both tabs, chrome included. That is a different picture and not a
# crop of an existing one, because the chrome is where the tab strip, the file
# name, the menu row and the status bar live and none of those appear in any
# photograph the site publishes.
#
# ---------------------------------------------------------------------------
# One launch per tab, and this is the part that was got wrong
#
# The obvious shape is one session and two shutters: settle, freeze, shoot
# Loudness, resume, press 2, settle, freeze, shoot Spectrum. It reads well —
# two views of one measurement — and it does not work, because **`kill -STOP` is
# not pausable**. Stopping the application stops it draining the socket while
# the plugin goes on filling it, so the resume costs blocks; the run that was
# written that way came back with the canvas carrying its own notice, in the
# application's words:
#
#     Audio was lost — 3073 frames never reached the measurement. Integrated
#     loudness and LRA average every block since the reset, so they are now
#     averages of less than what played and cannot be trusted.
#
# Which is the application being right. A meter that has just told you its
# integrated reading cannot be trusted is not a meter to photograph, and the
# notice would have been in the picture. So a freeze is **terminal**: nothing
# here is ever resumed, and the second tab gets a launch of its own.
#
# That makes the two shots two sessions, and the honest thing is to say so
# rather than to imply otherwise. It costs nothing here — unlike signal_path.sh,
# whose two plates sit under a sentence claiming they agree, these two are of
# different tabs and share no reading. The Spectrum tab shows no loudness number
# at all.
#
# The tab is therefore selected **before** the settle rather than between the
# shutters, which the Spectrum run needs anyway: the spectrogram accumulates
# from `engine.generation` and a module that is not built accumulates nothing,
# so the tab has to be on screen for the whole wait for its ring to fill.
#
# ---------------------------------------------------------------------------
# What is posted, and what is not
#
# One key per run: the tab digit. `lib/src/app/shortcuts.dart` binds the bare
# digits to "go to a tab by number", so no modifier and no pointer is involved —
# `CGPreflightPostEventAccess` is the only grant it needs, and the window is
# brought forward with `NSRunningApplication.activate`, which is an API call
# rather than a synthesised click and leaves the pointer where the person left
# it. The Loudness run posts `1`, which selects the tab that is already
# selected; it is sent anyway because a key that lands is also the proof that
# the window has the focus.
#
# There is no `--open-tab` launch option to prefer over this, unlike `--publish`
# and `--attach` in signal_path.sh, and one should not be added for a
# screenshot: the digit is a shipped, documented binding and posting it exercises
# it. What is *not* posted is anything with coordinates. See CLAUDE.md on why a
# script that clicks at a remembered offset is a script that stops pressing
# anything the day the row moves.
#
# ---------------------------------------------------------------------------
# The freeze
#
# Same three signals as signal_path.sh and for the same reason: neither the
# window server nor `screencapture` is instant, and a meter that moves between
# the read and the write is a meter photographed mid-repaint. `kill -STOP` the
# fake DAW, wait one publish interval, `kill -STOP` the application, shoot.
#
# **Inside two seconds**, because `PluginLink` marks a session stale after two
# without a frame and a stale snapshot is cleared to dashes.
#
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - **Screen Recording**, granted to whichever terminal runs this. Without it
#     `screencapture` returns a black frame and exits 0. Preflighted below.
#   - Permission to **post key events** — what `CGPreflightPostEventAccess`
#     reports. No Accessibility grant is needed: nothing here goes through
#     `System Events`.
#   - **The window uncovered** for the four minutes it runs. Flutter pauses its
#     ticker when a window is occluded and this application consumes the
#     plugin's stream from that ticker, so a covered canvas stops measuring
#     silently — the link stays up and the transport sits at 00:00:00:00. This
#     is checked for what it is rather than through the usual proxy: the window
#     list is read every five seconds and anything overlapping the window from
#     in front ends the run, naming itself. So the application does **not** have
#     to stay frontmost — a terminal or a browser somewhere else on a large
#     screen is fine — and a doomed run ends in five seconds rather than after
#     the whole settle.
#   - The release build: `flutter build macos --release`. Not a debug one — a
#     Mac draws the FILE button only in a debug build, and that row is part of
#     what these pictures are of.
#   - The fake DAW and the VST3, which is the full plugin build:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#   - `test_audio/citizens-apathy.flac`: `dart run tool/fetch_test_audio.dart`.
#   - Port 47822 free. A copy of the application already running takes the link,
#     and this would photograph a canvas reading dashes.
#
# Usage: sh packaging/app_window_shots.sh          # both tabs
#        sh packaging/app_window_shots.sh spectrum # one of them
set -eu

APP="build/macos/Build/Products/Release/Open Audio Analyzer.app"
# Into the repository rather than build/, like `signal_path.sh`'s pair — see
# packaging/AGENTS.md on which outputs are committed and why.
OUT="packaging/screenshots"
TRACK="test_audio/citizens-apathy.flac"
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
WORK="$(mktemp -d)"

BUNDLE_ID="com.openaudioanalyzer.oaa"

# The window, in points. The same 16:10 as the signal-path plate and for the
# same reason — the default canvas is 24 columns and each wants room to draw its
# own scale — but as large as a laptop's own display will hold, because this one
# is not sharing a row with two others. It has to fit inside `visibleFrame`
# rather than the screen: a window under the menu bar or behind the Dock is a
# window that is partly occluded, and an occluded canvas stops measuring. The
# layout below refuses rather than shrinking it silently.
WIN_W=1568
WIN_H=980

# Transport time before the shutter, per run. Long enough that LUFS-I has
# integrated over something rather than over the first bar, that the histogram
# has a shape, and — on the Spectrum run — that the spectrogram's ring has
# filled, which takes about half of it.
SETTLE=75

# The tabs of the default canvas, as `<name>:<digit>`. `defaultPreset()` in
# `lib/src/canvas/workspace.dart` is where the order comes from.
TABS="loudness:1 spectrum:2"

STOPPED=""
DAW_PID=""

cleanup() {
  # CONT before TERM: a stopped process never sees a TERM.
  for pid in ${STOPPED:-}; do kill -CONT "$pid" 2>/dev/null || true; done
  [ -n "${DAW_PID:-}" ] && kill "$DAW_PID" 2>/dev/null || true
  osascript -e 'tell application "Open Audio Analyzer" to quit' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

WANTED="${1:-}"

[ -d "$APP" ]      || die "No release build at $APP. Run: flutter build macos --release"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW. Build the plugin first — see the header."
[ -f "$TRACK" ]    || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"

if lsof -nP -iTCP:47822 >/dev/null 2>&1; then
  die "Something is already on port 47822. Close the application and any fake DAW."
fi

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# The three helpers that are not shell

# Where to put the window, as the preference that decides it.
#
# `NSWindow`'s frame autosave string, in Cocoa's coordinate space: the frame,
# then the screen it was measured against, which is the shape it reads back.
cat > "$WORK/layout.swift" <<'SWIFT'
import Cocoa

let a = CommandLine.arguments
guard a.count >= 3, let w = Double(a[1]), let h = Double(a[2]) else { exit(2) }

for screen in NSScreen.screens.sorted(by: { $0.visibleFrame.width > $1.visibleFrame.width }) {
  let v = screen.visibleFrame
  guard v.width >= w, v.height >= h else { continue }
  print("\(Int(v.minX + (v.width - w) / 2)) \(Int(v.minY + (v.height - h) / 2)) " +
        "\(Int(w)) \(Int(h)) " +
        "\(Int(v.minX)) \(Int(v.minY)) \(Int(v.width)) \(Int(v.height)) ")
  exit(0)
}

FileHandle.standardError.write(
  "no screen large enough for a \(Int(w))x\(Int(h)) window\n".data(using: .utf8)!)
exit(1)
SWIFT

# The tab digit, as a key rather than a click.
#
# `activate` first because a posted key goes wherever the focus is. It is an API
# call and not a synthesised click, so the pointer stays where it is. 18, 19 and
# 20 are the digits 1, 2 and 3.
cat > "$WORK/tab.swift" <<'SWIFT'
import Cocoa

guard let digit = CommandLine.arguments.dropFirst().first.flatMap(Int.init),
      (1...9).contains(digit) else { exit(2) }

guard CGPreflightPostEventAccess() else {
  FileHandle.standardError.write(
    "no permission to post key events: grant Input Monitoring to this terminal\n"
      .data(using: .utf8)!)
  exit(3)
}
guard let app = NSRunningApplication.runningApplications(
  withBundleIdentifier: "com.openaudioanalyzer.oaa").first else {
  FileHandle.standardError.write("Open Audio Analyzer is not running\n".data(using: .utf8)!)
  exit(1)
}
app.activate(options: [])
usleep(800_000)

// kVK_ANSI_1 is 18, and 1–8 run consecutively from there; 9 does not, which is
// why the table is written out rather than computed.
let keys: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
                              6: 22, 7: 26, 8: 28, 9: 25]
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
  CGEvent(keyboardEventSource: source, virtualKey: keys[digit]!, keyDown: down)?
    .post(tap: .cghidEventTap)
  usleep(80_000)
}
SWIFT

# The window id, and whether anything is lying on top of it.
#
# **Two questions, one list, and the second is the one that matters.** Flutter
# pauses its ticker when a window is occluded, and this application consumes the
# plugin's stream from that one ticker — so a covered canvas stops measuring
# silently, with the link still up and the transport parked at 00:00:00:00. The
# obvious guard is to ask what is frontmost, which is what `signal_path.sh` does
# because it is watching two windows in two applications and cannot demand
# either be first. It is a *proxy*, and a coarse one in both directions: a
# browser frontmost on the other half of a wide screen covers nothing, and a
# window that lost the focus an hour ago may be covering everything.
#
# `CGWindowListCopyWindowInfo` answers the real question. The list comes back
# front to back, so anything before ours is in front of it, and `kCGWindowBounds`
# is public — it is the window *image* that Screen Recording gates, which is why
# the preflight below is a separate question from this one. Layer 0 only, so the
# Dock and the menu bar are not read as cover, and they cannot be anyway: the
# window is placed inside `visibleFrame`.
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

func rect(_ w: [String: Any]) -> CGRect? {
  (w[kCGWindowBounds as String] as? [String: Any])
    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
}

// Everything ahead of ours in the list is in front of it.
var above: [(String, CGRect)] = []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
  guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
        let id = w[kCGWindowNumber as String] as? Int,
        let bounds = rect(w) else { continue }

  if owner == "Open Audio Analyzer" {
    // A window covered by a *sliver* is still a window Flutter stops drawing,
    // so any overlap at all is reported rather than a fraction of the area.
    for (name, other) in above where other.intersects(bounds) {
      FileHandle.standardError.write("covered by \(name)\n".data(using: .utf8)!)
      exit(4)
    }
    print(id)
    exit(0)
  }
  // Fully transparent helper windows cover nothing and are legion.
  if (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 {
    above.append((owner, bounds))
  }
}
FileHandle.standardError.write("no Open Audio Analyzer window on screen\n".data(using: .utf8)!)
exit(1)
SWIFT

APP_FRAME="$(swift "$WORK/layout.swift" "$WIN_W" "$WIN_H")" \
  || die "No screen big enough for a ${WIN_W}x${WIN_H} window."

# ---------------------------------------------------------------------------
# Nothing may lie on top of the window
#
# Not "nothing else may have the focus" — see the header of `window.swift`. The
# window may sit behind the terminal that started this, and this run will still
# be thrown away, so it is polled rather than checked once: a doomed run ends in
# five seconds instead of in seventy-five.
#
# The application does *not* have to be frontmost, which matters here: the tab
# key is posted through `NSRunningApplication.activate` and everything after it
# is a signal, so a person can click elsewhere on a large screen without
# spoiling the picture.

wait_uncovered() { # wait_uncovered <seconds>
  waited=0
  while [ "$waited" -lt "$1" ]; do
    if ! COVER="$(swift "$WORK/window.swift" 2>&1 >/dev/null)"; then
      die "\
$(printf '%s' "The window is ${COVER:-gone} after ${waited}s.")
  Flutter pauses its ticker when a window is occluded and this application
  consumes the plugin's stream from that ticker, so a covered canvas stops
  measuring — the picture would show a transport that never moved. Leave the
  window uncovered for the whole run."
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# ---------------------------------------------------------------------------
# One tab, one launch, one shutter
#
# Everything this starts is dead by the time it returns, because the freeze is
# terminal — see the header.

shoot_tab() { # shoot_tab <name> <digit>
  name=$1
  digit=$2

  say ""
  say "--- $name ---"

  # `--config-dir` so the canvas is the default layout rather than whatever this
  # machine was last left looking at, and so nothing here writes over somebody's
  # real session. The window geometry is not in there: it is `NSWindow`'s own
  # frame autosave, which lives in the bundle's defaults.
  rm -rf "$WORK/config"
  mkdir -p "$WORK/config"
  defaults write "$BUNDLE_ID" "NSWindow Frame OaaMainWindow" "$APP_FRAME"
  # `open` and not the binary inside the bundle: macOS attributes Local Network
  # permission to the *responsible* process, and a bare exec of the executable
  # is refused where the bundle is allowed.
  say "Starting the application..."
  open "$APP" --args --config-dir="$WORK/config"
  sleep 8

  APP_PID="$(pgrep -x "Open Audio Analyzer" | head -1)"
  [ -n "$APP_PID" ] || die "The application did not start."

  # The shipped path: the fake DAW plays the track through the real VST3, the
  # plugin dials 127.0.0.1:47822, and the application accepts it — the same link
  # a DAW insert makes. Every number in the picture was measured by the engine
  # from that file.
  say "Starting the fake DAW..."
  "$FAKE_DAW" --track="$TRACK" --headless --speed=1 --seconds=420 --play >/dev/null 2>&1 &
  DAW_PID=$!
  sleep 4
  kill -0 "$DAW_PID" 2>/dev/null || die "The fake DAW exited immediately — run it by hand to see why."

  # **Wait for the pair, then start counting.** The settle is transport time, and
  # it is only transport time if the link is up when the clock starts. Matched on
  # the *plugin* end: lsof prints this application as `Open\x20A`, so the obvious
  # grep for its name matches nothing and waits the full thirty seconds.
  say "Waiting for the plugin to connect..."
  waited=0
  until lsof -nP -iTCP:47822 -sTCP:ESTABLISHED 2>/dev/null | grep -q "oaa-fake-"; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge 30 ] && die "The plugin never connected on 47822 — check the notice on the canvas."
  done

  say "Selecting the $name tab..."
  swift "$WORK/tab.swift" "$digit" || die "Could not post the tab key — see the header."

  say "Playing $SETTLE s of programme..."
  wait_uncovered "$SETTLE"

  # The freeze, and then the shutter. `-o` drops the drop shadow, which is
  # 40-odd transparent pixels a side that the site would have to crop back off;
  # `-x` silences the shutter sound.
  say "Photographing..."
  kill -STOP "$DAW_PID"; STOPPED="$DAW_PID"
  # One publish interval at 30 fps is 33 ms; a tenth of a second is three of
  # them, and well inside the two seconds the stale check allows.
  sleep 0.4
  kill -STOP "$APP_PID"; STOPPED="$STOPPED $APP_PID"

  WINDOW_ID="$(swift "$WORK/window.swift")" || exit 1
  screencapture -x -o -l "$WINDOW_ID" "$OUT/window-$name.png"
  [ -s "$OUT/window-$name.png" ] || die "screencapture wrote nothing."

  # And down, both of them, without ever running again. See the header.
  kill -CONT "$DAW_PID" 2>/dev/null || true
  kill "$DAW_PID" 2>/dev/null || true
  wait "$DAW_PID" 2>/dev/null || true
  DAW_PID=""
  kill -CONT "$APP_PID" 2>/dev/null || true
  kill "$APP_PID" 2>/dev/null || true
  STOPPED=""

  # The next run needs the port, and a terminating application does not hand it
  # back instantly.
  waited=0
  while lsof -nP -iTCP:47822 >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge 20 ] && die "Port 47822 never came free after the $name run."
  done
}

for entry in $TABS; do
  name="${entry%%:*}"
  digit="${entry##*:}"
  [ -z "$WANTED" ] || [ "$WANTED" = "$name" ] || continue
  shoot_tab "$name" "$digit"
done

say ""
for entry in $TABS; do
  name="${entry%%:*}"
  [ -f "$OUT/window-$name.png" ] || continue
  say "  $OUT/window-$name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/window-$name.png" \
    | awk '/pixel/ {printf "%s ", $2}')"
done
say ""
say "  Next: cd website && npm run window"
