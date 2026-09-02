#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The two photographs behind the website's signal-path section, from one session.
#
# Writes packaging/screenshots/desktop.png and .../tablet.png — the real
# application on this Mac, and the real application on an iPad simulator
# *attached to it as a remote display*. `website/scripts/render-flow.mjs` picks
# both up as the second and third plates of the front page's signal path.
#
# ---------------------------------------------------------------------------
# Why one script and not two
#
# The section puts the two side by side under a paragraph saying the meter
# across the room cannot disagree with the one under your hand. They were shot
# by two scripts that could not run at once — the plugin dials one address and
# one application holds 47822 — so they were matched by *transport position*
# instead: 74 seconds here, 74.7 there, on the argument that the engine is
# deterministic. It is, and it was still not enough. The pair that shipped read
# 00:01:19:21 against 00:01:20:03, so LUFS-M was −9.6 on one and −9.8 on the
# other and the VU needles pointed at different numbers, directly beneath a
# sentence about the two agreeing. Determinism cannot fix that: it makes the
# same instant read the same, and the two scripts were never at the same
# instant.
#
# There is only one arrangement in which they cannot differ, and it is also the
# one the section is describing: the tablet is a **display** of the desktop.
# Both draw the same published frame, so the numbers are not two measurements
# that agree — they are one measurement, drawn twice.
#
# The old tablet plate was not that. It was the iPad running as the primary
# application with the plugin dialling *it*, which is a real thing the product
# does and is not the thing the paragraph beside it claims. ATTACH was never
# pressed.
#
# ---------------------------------------------------------------------------
# What makes it identical, and not merely close
#
# Both ends are live and neither can be photographed instantly, so the readings
# are stopped before the shutter rather than raced:
#
#   1. `kill -STOP` the fake DAW. No further audio reaches the plugin, so the
#      desktop's snapshot stops changing while it goes on drawing it and goes on
#      publishing it.
#   2. A moment later the display has received that unchanging frame, and the
#      two screens are the same picture.
#   3. `kill -STOP` both applications. Each window keeps its last surface — the
#      window server holds it for `screencapture`, and the simulator's
#      framebuffer holds it for `simctl io` — so there is no longer a clock to
#      race.
#
# Step 3 is not optional and there is a deadline on it. `PluginLink` marks a
# session stale after two seconds without a frame, and a stale snapshot is
# *cleared*: every reading becomes a dash. So the freeze has to land inside that
# window, which is why it is three signals in a row and not three captures.
#
# ---------------------------------------------------------------------------
# Nothing here posts a mouse event
#
# `packaging/ios/screenshots.sh` drives the iPad by posting CGEvents at the
# Simulator's window, which takes the pointer away from whoever is at the
# machine for as long as it runs. This needs two presses — PUBLISH here, ATTACH
# there — and both are launch options instead, `--publish` and `--attach`. The
# second of them cost a platform channel: iOS gives Flutter neither the command
# line nor an environment, so the runner has to be asked. See
# `lib/src/app/launch_options.dart` and `ios/Runner/OaaLaunchArguments.swift`.
#
# **One thing is still posted, and it is a key.** The device has to be in
# landscape, and nothing will put it there without asking a person: `simctl`
# cannot rotate, and `SimulatorWindowOrientation` in the Simulator's preferences
# turns out to describe the *window* rather than the device — write LandscapeLeft
# into it and the springboard comes up portrait anyway. What is left is the
# Simulator's own Rotate Right, so this posts ⌘→ once. A key event moves no
# pointer and steals no cursor; the Simulator is brought forward through
# `NSRunningApplication.activate`, which moves none either. The device is
# rebooted first so that one press is always enough — a fresh boot is portrait,
# which is the one fact that makes a blind rotation deterministic.
#
# It still needs the machine to itself for about two minutes, for a different
# reason: **both windows have to stay visible the whole time.** Flutter pauses
# its ticker when a window is occluded and this application consumes the
# plugin's stream from that one ticker, so a covered canvas stops measuring
# silently — the link stays up, the format still reads 44.1 kHz, and the
# transport sits at 00:00:00:00. The two are laid out side by side on the widest
# screen for exactly that reason; neither has to be frontmost, only uncovered.
#
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - **Screen Recording**, granted to whichever terminal runs this. Without it
#     `screencapture` returns an entirely black frame and exits 0 — see
#     CLAUDE.md. `CGPreflightScreenCaptureAccess` is checked up front.
#   - Permission to **post key events** — Input Monitoring, or whatever the
#     Accessibility-adjacent grant `CGPreflightPostEventAccess` reports — for the
#     one ⌘→ that turns the device on its side. No pointer event is posted.
#   - Only one booted simulator, because that key goes to a window.
#   - About 3000 points of width to lay the two windows out in. The script says
#     so rather than overlapping them.
#
#     **No Accessibility grant, deliberately.** Both windows used to be placed
#     through System Events, which needs one — and a terminal without it fails
#     at `AXErrorAPIDisabled` while `CGPreflightPostEventAccess` cheerfully
#     answers yes, because posting events and reading a window are two different
#     TCC services. Every geometry either application has is a *preference*:
#     `NSWindow Frame OaaMainWindow` for this one, and
#     `SimulatorWindowGeometry` / `SimulatorWindowOrientation` per device for the
#     Simulator. Writing them before launch is both permission-free and exact,
#     where clicking Window > Point Accurate was neither.
#   - The release build: `flutter build macos --release`. **Not a debug or
#     profile one** — a Mac shows the FILE button only in a debug build, and a
#     differently signed copy of the same bundle identifier is a different
#     subject to TCC, so it would ask for Local Network permission again and
#     draw the notice saying it had not been given it.
#   - The simulator build: `flutter build ios --simulator --debug`, and an Xcode
#     iOS runtime with an iPad Pro 13-inch device type.
#   - The fake DAW and the VST3, which is the full plugin build:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#   - `test_audio/citizens-apathy.flac`: `dart run tool/fetch_test_audio.dart`.
#   - Ports 47822 (the plugin's) and 47821 (the display's) free. A copy of
#     either application already running takes the link, and this photographs a
#     canvas reading dashes.
#
# Usage: sh packaging/signal_path.sh
set -eu

APP="build/macos/Build/Products/Release/Open Audio Analyzer.app"
SIM_APP="build/ios/iphonesimulator/Runner.app"
# Into the repository rather than build/: a plate needs a Mac with the grants
# and the fake DAW, which no runner has, so it is kept the way the store sets in
# `ios/screenshots/` and `android/screenshots/` are — see packaging/AGENTS.md.
OUT="packaging/screenshots"
TRACK="test_audio/citizens-apathy.flac"
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
WORK="$(mktemp -d)"

BUNDLE_ID="com.openaudioanalyzer.oaa"
DEVICE_NAME="OAA-Screenshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB"

# The desktop window, in points. Wide enough that the default canvas' four
# columns of modules each get room to draw their scales, and 16:10 so the plate
# it becomes sits beside the other two without one of them towering over the
# rest.
WIN_W=1560
WIN_H=980

# The iPad in landscape, in points, with `Point Accurate` on and the bezels off.
SIM_W=1376
SIM_H=1032

# The display port the desktop opens and the tablet dials. `DisplayHost.defaultPort`.
DISPLAY_PORT=47821

# How much programme to let through before the shutter. One number now, because
# there is one session: it is transport time, counted from the moment the plugin
# is confirmed connected.
SETTLE=74

cleanup() {
  # CONT before TERM: a stopped process never sees a TERM.
  for pid in ${STOPPED:-}; do kill -CONT "$pid" 2>/dev/null || true; done
  [ -n "${DAW_PID:-}" ] && kill "$DAW_PID" 2>/dev/null || true
  xcrun simctl terminate "${UDID:-none}" "$BUNDLE_ID" >/dev/null 2>&1 || true
  osascript -e 'tell application "Open Audio Analyzer" to quit' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ -d "$APP" ]      || die "No release build at $APP. Run: flutter build macos --release"
[ -d "$SIM_APP" ]  || die "No simulator build at $SIM_APP. Run: flutter build ios --simulator --debug"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW. Build the plugin first — see the header."
[ -f "$TRACK" ]    || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"

for port in 47822 "$DISPLAY_PORT"; do
  if lsof -nP -iTCP:"$port" >/dev/null 2>&1; then
    die "Something is already on port $port. Close the application, any fake DAW, and any booted simulator running it."
  fi
done

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# The two helpers that are not shell

# Where to put the two windows, as the two preferences that decide it.
#
# Both have to be fully on screen at once or the occluded one stops measuring,
# so this picks the widest screen that can hold them side by side and prints
# three things: the application's `NSWindow Frame OaaMainWindow` string, the
# centre the Simulator's window wants, and the UUID of the screen that centre is
# on — because `SimulatorWindowGeometry` is keyed by screen. Failing a screen
# that fits, it says so, because a script that quietly overlapped them would
# produce a picture of a transport that never moved.
#
# Everything here is Cocoa's coordinate space, which is what both preferences
# are written in: origin at the bottom left of the main screen, y counting up.
cat > "$WORK/layout.swift" <<'SWIFT'
import Cocoa

let a = CommandLine.arguments
guard a.count >= 5, let aw = Double(a[1]), let ah = Double(a[2]),
      let sw = Double(a[3]), let sh = Double(a[4]) else { exit(2) }

let gap = 24.0

func uuid(of screen: NSScreen) -> String? {
  guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber,
        let id = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
  else { return nil }
  return CFUUIDCreateString(nil, id) as String
}

for screen in NSScreen.screens.sorted(by: { $0.visibleFrame.width > $1.visibleFrame.width }) {
  let v = screen.visibleFrame
  guard v.width >= aw + gap + sw, v.height >= max(ah, sh), let id = uuid(of: screen)
  else { continue }

  let x = v.minX + (v.width - (aw + gap + sw)) / 2
  let appY = v.minY + (v.height - ah) / 2
  // The application's frame, then the screen it was measured against — the
  // shape `NSWindow`'s frame autosave writes, and the shape it reads back.
  print("\(Int(x)) \(Int(appY)) \(Int(aw)) \(Int(ah)) " +
        "\(Int(v.minX)) \(Int(v.minY)) \(Int(v.width)) \(Int(v.height)) ")
  // The Simulator wants a centre rather than a frame.
  print("{\(Int(x + aw + gap + sw / 2)), \(Int(v.midY))}")
  print(id)
  exit(0)
}

FileHandle.standardError.write(
  "no screen wide enough for a \(Int(aw))x\(Int(ah)) window beside a \(Int(sw))x\(Int(sh)) one\n"
    .data(using: .utf8)!)
exit(1)
SWIFT

# Rotate Right, as a key rather than a click.
#
# The Simulator is activated first because a posted key goes wherever the focus
# is; `activate` is an API call and not a synthesised click, so the pointer stays
# wherever the person left it. 124 is the right arrow.
cat > "$WORK/rotate.swift" <<'SWIFT'
import Cocoa

guard CGPreflightPostEventAccess() else {
  FileHandle.standardError.write(
    "no permission to post key events: grant Input Monitoring to this terminal\n"
      .data(using: .utf8)!)
  exit(3)
}
guard let sim = NSRunningApplication.runningApplications(
  withBundleIdentifier: "com.apple.iphonesimulator").first else {
  FileHandle.standardError.write("Simulator is not running\n".data(using: .utf8)!)
  exit(1)
}
sim.activate(options: [])
usleep(600_000)

let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
  let event = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: down)
  event?.flags = .maskCommand
  event?.post(tap: .cghidEventTap)
  usleep(80_000)
}
SWIFT

# The window id, from the public window list. `kCGWindowBounds` is available to
# anyone; it is the window *image* that Screen Recording gates, which is why the
# preflight is a separate question from this one.
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

# The Simulator's window, as the preferences that decide it.
#
# Written before Simulator.app is opened, because it reads them at launch and
# writes them back on quit — so a copy already running would undo this at the
# worst moment. `ShowChrome` is the bezels, off, because a plate wants the
# device's screen and not a picture of a picture frame; the orientation and its
# angle are per device; and a `WindowScale` of 1 is what the Window menu calls
# Point Accurate.
simulator_prefs() { # simulator_prefs <screen-uuid> <"{x, y}">
  python3 "$WORK/simprefs.py" "$UDID" "$1" "$2"
}

cat > "$WORK/simprefs.py" <<'PYTHON'
import plistlib, subprocess, sys

udid, screen, centre = sys.argv[1], sys.argv[2], sys.argv[3]
domain = "com.apple.iphonesimulator"

exported = subprocess.run(["defaults", "export", domain, "-"],
                          capture_output=True, check=True).stdout
prefs = plistlib.loads(exported) if exported.strip() else {}

prefs["ShowChrome"] = False
# Which device Simulator opens on, so that the window the rotation key reaches
# is this one.
prefs["CurrentDeviceUDID"] = udid
device = prefs.setdefault("DevicePreferences", {}).setdefault(udid, {})
device["SimulatorWindowOrientation"] = "LandscapeLeft"
device["SimulatorWindowRotationAngle"] = 90.0
# Written under every screen key this device already has, as well as the one
# the layout picked. `WindowCenter` is a *global* point, so whichever key the
# Simulator decides is the current screen puts the window in the same place —
# and it has to be all of them, because the key it uses is not the UUID
# `CGDisplayCreateUUIDFromDisplayID` answers with and there is no documented way
# to find out which one it is.
geometry = device.setdefault("SimulatorWindowGeometry", {})
for key in list(geometry) + [screen]:
    geometry[key] = {"WindowCenter": centre, "WindowScale": 1.0}

subprocess.run(["defaults", "import", domain, "-"],
               input=plistlib.dumps(prefs), check=True)
PYTHON

# ---------------------------------------------------------------------------
# Where the two windows go
#
# Decided before either is opened, because both are told rather than moved.

LAYOUT="$(swift "$WORK/layout.swift" "$WIN_W" "$WIN_H" "$SIM_W" "$SIM_H")" \
  || die "Not enough screen to keep both windows visible at once. See the header."
APP_FRAME="$(printf '%s\n' "$LAYOUT" | sed -n 1p)"
SIM_CENTRE="$(printf '%s\n' "$LAYOUT" | sed -n 2p)"
SIM_SCREEN="$(printf '%s\n' "$LAYOUT" | sed -n 3p)"

# ---------------------------------------------------------------------------
# The simulator

say "Preparing the iPad simulator..."

UDID="$(xcrun simctl list devices -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for r in d.values() for x in r if x["name"]=="'"$DEVICE_NAME"'"), ""))')"

if [ -z "$UDID" ]; then
  say "Creating $DEVICE_NAME..."
  RUNTIME="$(xcrun simctl list runtimes -j \
    | python3 -c 'import json,sys;r=[x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x["isAvailable"] and "iOS" in x["identifier"]];print(r[-1] if r else "")')"
  [ -n "$RUNTIME" ] || die "No available iOS runtime."
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
fi

# Only this one may be booted. The rotation below is a key posted at whichever
# window has the focus, and a second device is a second window to land in.
OTHERS="$(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(" ".join(x["name"] for r in d.values() for x in r if x["udid"] != "'"$UDID"'"))')"
[ -z "$OTHERS" ] || die "Other simulators are booted ($OTHERS). Shut them down: the rotation key would go to one of their windows."

# **Booted from cold, every time.** A fresh boot is portrait, and that is what
# makes one press of Rotate Right enough without any way to ask which way up the
# device already is. It also takes the locale below, which needs a reboot.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLanguages -array en-US 2>/dev/null || true
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLocale -string en_US 2>/dev/null || true
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# 9:41, full battery, no carrier. Per boot, so after the reboot above.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode notSupported

# Quit first, so that the preferences below are not overwritten on the way out
# by a copy that was already running with the old ones.
osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
sleep 2
simulator_prefs "$SIM_SCREEN" "$SIM_CENTRE"

open -a Simulator
sleep 8

say "Turning the device on its side..."
swift "$WORK/rotate.swift" || die "Could not rotate the device — see the header."
sleep 3

# Nothing else may be holding the ingest port — including a copy of this
# application left running on another simulator.
for other in $(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(" ".join(x["udid"] for r in d.values() for x in r))'); do
  [ "$other" = "$UDID" ] && continue
  xcrun simctl terminate "$other" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

say "Installing the app on the simulator..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$SIM_APP"

# ---------------------------------------------------------------------------
# The desktop, on a configuration directory of its own
#
# `--config-dir` so the canvas is the default layout rather than whatever this
# machine was last left looking at, and so nothing here writes over somebody's
# real session. `--publish` opens the display port; see launch_options.dart for
# why that is a flag and not a setting.
#
# `open` and not the binary inside the bundle: macOS attributes Local Network
# permission to the *responsible* process, and a bare exec of the executable is
# refused where the bundle is allowed.

say "Starting the application..."
rm -rf "$WORK/config"
mkdir -p "$WORK/config"
# The window geometry is not in `--config-dir`: it is `NSWindow`'s own frame
# autosave, which lives in the bundle's defaults, so it is written here and the
# window opens where it is wanted rather than where this Mac last left it.
defaults write "$BUNDLE_ID" "NSWindow Frame OaaMainWindow" "$APP_FRAME"
open "$APP" --args --config-dir="$WORK/config" --publish
sleep 8

if ! lsof -nP -iTCP:"$DISPLAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "The application is not publishing on $DISPLAY_PORT. --publish was ignored, or the port is taken."
fi

# ---------------------------------------------------------------------------
# The audio
#
# The shipped path: the fake DAW plays the track through the real VST3, the
# plugin dials 127.0.0.1:47822, and the application accepts it — the same link a
# DAW insert makes. Every number in both pictures was measured by the engine
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

# ---------------------------------------------------------------------------
# The tablet, as a display of the desktop
#
# `--args` reaches the Dart entrypoint through `ios/Runner/OaaLaunchArguments.swift`,
# which exists because iOS gives Flutter neither the command line nor an
# environment. 127.0.0.1 is the Mac's loopback from inside the simulator — a
# simulator app is a macOS process on the host's network stack — so this is a
# real socket carrying the real wire protocol, and it asks for no Local Network
# permission inside the guest.

say "Attaching the tablet to it..."
# `simctl launch` prints `<bundle>: <pid>`, and that pid is a *host* pid — a
# simulator app is an ordinary macOS process — which is what the freeze below
# signals.
SIM_PID="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" \
  --args "--attach=oaa://127.0.0.1:$DISPLAY_PORT" | awk -F': ' '{print $2}')"
[ -n "$SIM_PID" ] || die "The simulator app did not report a pid."
sleep 8

lsof -nP -iTCP:"$DISPLAY_PORT" -sTCP:ESTABLISHED >/dev/null 2>&1 \
  || die "No display attached on $DISPLAY_PORT — the tablet is showing the host picker, not the desktop."

say "Playing $SETTLE s of programme..."
sleep "$SETTLE"

# **Both windows must have been visible the whole time.** An occluded canvas
# stops measuring silently; the readings are then right while the transport
# never moved. Neither has to be frontmost, so this refuses only when something
# *else* took the screen.
FRONT="$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null || true)"
case "$FRONT" in
  "Open Audio Analyzer" | "Simulator") ;;
  *) die "\
$(printf '%s' "$FRONT took the foreground during the wait.")
  A covered canvas stops measuring, so the pictures would show a transport that
  never moved. Run this with the machine to itself." ;;
esac

# ---------------------------------------------------------------------------
# The freeze, and then the shutter
#
# Three signals inside two seconds; see the header for why that is the deadline
# and why this is what makes the two pictures the same measurement rather than
# two close ones.

APP_PID="$(pgrep -x "Open Audio Analyzer" | head -1)"
[ -n "$APP_PID" ] || die "Lost the application's process."

kill -STOP "$DAW_PID"
STOPPED="$DAW_PID"
# One publish interval at 30 fps is 33 ms; a tenth of a second is three of them,
# and well inside the two the stale check allows.
sleep 0.4
kill -STOP "$SIM_PID"; STOPPED="$STOPPED $SIM_PID"
kill -STOP "$APP_PID"; STOPPED="$STOPPED $APP_PID"

WINDOW_ID="$(swift "$WORK/window.swift")" || exit 1
# `-o` drops the drop shadow, which is 40-odd transparent pixels a side that the
# site would have to crop back off; `-x` silences the shutter.
screencapture -x -o -l "$WINDOW_ID" "$OUT/desktop.png"
[ -s "$OUT/desktop.png" ] || die "screencapture wrote nothing."

# The framebuffer is always the panel's own orientation — portrait, whatever the
# device is doing — so a landscape device arrives lying on its side. 90 is the
# way back from the single Rotate Right above.
xcrun simctl io "$UDID" screenshot "$WORK/tablet-raw.png" >/dev/null 2>&1
[ -s "$WORK/tablet-raw.png" ] || die "simctl wrote no screenshot."
sips -r 90 --out "$OUT/tablet.png" "$WORK/tablet-raw.png" >/dev/null

say ""
for f in desktop tablet; do
  say "  $OUT/$f.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$f.png" \
    | awk '/pixel/ {printf "%s ", $2}')"
done
say ""
say "  Both were taken from one frozen frame: the tablet is a display of the"
say "  desktop, so every reading in them is one measurement drawn twice."
say ""
say "  Next: cd website && npm run flow"
