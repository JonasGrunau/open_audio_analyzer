#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# App Store screenshots for the iPad build.
#
# Writes five 2752x2064 PNGs into build/packaging/screenshots/ — the 13-inch iPad
# display size App Store Connect asks for, landscape. Nothing else here is
# needed for a submission: one size covers every iPad, and this app is iPad
# only (TARGETED_DEVICE_FAMILY = 2), so no iPhone set is required.
#
# ---------------------------------------------------------------------------
# Why the meters are measuring something
#
# A simulator has no audio input, so an iPad screenshot taken the obvious way
# is a photograph of dashes and a test tone — and a test tone is one spike in
# the spectrum and a flat line in the histogram, which tells a reader nothing
# about what the application does. What this script does instead is the shipped
# path: `plugin/host/`'s fake DAW plays a real track through the real VST3, the
# plugin dials 127.0.0.1:47822, and the application accepts it — the same link
# a DAW insert uses. A simulator app is a macOS process on the host's network
# stack, so the port the app binds inside the simulator *is* the host's
# loopback and the two find each other with nothing configured.
#
# So every number in these pictures was measured by the engine from the CC BY
# track in test_audio/, and the canvas is metering a plugin exactly as it would
# in Logic. Nothing is mocked, which is the only acceptable answer for a
# metering tool's store page: a screenshot of invented readings is a lie about
# the product's one job.
#
# ---------------------------------------------------------------------------
# Three things the tooling cannot do, and what stands in for each
#
# **`simctl` cannot rotate, and its screenshot is always the panel's own
# orientation.** The framebuffer is portrait whatever the device is doing; a
# landscape device simply draws into it rotated. So the orientation is set
# through the Simulator's own Device menu (AppleScript, no permission beyond
# the Accessibility grant the tap below already needs) and every capture is
# turned by `sips -r 270` afterwards. The result is a true 2752x2064 landscape
# frame, status bar included.
#
# **`simctl` cannot tap.** There is no touch command, so the taps are CGEvents
# posted at the Simulator window, mapped from device points through
# `windowWidth / 1376`. That needs the device bezels off and no window bezel
# padding, which the Window menu items below take care of. The app's own
# keyboard shortcuts would have been simpler and do not work: a hardware
# keyboard is connected and Flutter never sees the chords.
#
# **A rebooted device forgets its orientation but keeps its locale.** The
# locale write needs the reboot; the orientation has to be re-applied after
# one. Both are done here in that order, so a fresh device and a warm one end
# up in the same state.
#
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - Xcode, and an iOS runtime with an iPad Pro 13-inch device type.
#   - The Terminal running this needs the Accessibility grant that lets it post
#     events (System Settings -> Privacy & Security -> Accessibility). Without
#     it the taps silently do nothing and the panels never open; the script
#     says so up front rather than producing five pictures of the same canvas.
#   - `test_audio/citizens-apathy.flac`: `dart run tool/fetch_test_audio.dart`.
#   - The fake DAW and the VST3, which is the full plugin build:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#
# Usage: sh packaging/ios/screenshots.sh [--canvas-only]
#
# **`--canvas-only` posts no mouse events at all.** The taps below are CGEvents
# aimed at the Simulator's window, which means that for the two or three minutes
# a full run takes, the pointer belongs to this script and not to the person at
# the machine. Only the four navigated pictures need them; `01-loudness` is shot
# before the first tap, off the canvas the app opens on. So a run that wants only
# that one can and should skip the rest.
#
# **The website's tablet plate no longer comes from here.** It used to be this
# script's `01-loudness`, which is the iPad running as the primary application
# with the plugin dialling *it* — a real thing the product does, and not the one
# the paragraph beside that plate describes. It is shot by
# `packaging/signal_path.sh` now, as a display attached to the desktop it stands
# next to, and both of them come out of one frozen frame. Nothing here feeds the
# site any more; these five are the App Store's.
set -eu

CANVAS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --canvas-only) CANVAS_ONLY=1 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

DEVICE_NAME="OAA-Screenshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB"
BUNDLE_ID="com.openaudioanalyzer.oaa"
APP="build/ios/iphonesimulator/Runner.app"
OUT="build/packaging/screenshots"
TRACK="test_audio/citizens-apathy.flac"
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
WORK="$(mktemp -d)"

# The 13-inch iPad in landscape, in points. Every tap below is written in this
# space, read off a finished screenshot and halved.
POINTS_W=1376
POINTS_H=1032

cleanup() {
  [ -n "${DAW_PID:-}" ] && kill "$DAW_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ -f "$TRACK" ] || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW. Build the plugin first — see the header."

# ---------------------------------------------------------------------------
# The two helpers that are not shell

cat > "$WORK/tap.swift" <<'SWIFT'
import Cocoa

// Posts one click into the Simulator's device screen, from device points.
//
// The window's width is the device's width — bezels are off — so the scale is
// one division, and the screen sits against the window's bottom edge with the
// title bar above it. `mouseEventClickState` is set to 1 explicitly: a click
// whose state is unset is not a click any application counts.
let a = CommandLine.arguments
guard a.count >= 5, let px = Double(a[1]), let py = Double(a[2]),
      let pw = Double(a[3]), let ph = Double(a[4]) else {
  FileHandle.standardError.write("usage: tap <x> <y> <pointsW> <pointsH>\n".data(using: .utf8)!)
  exit(2)
}

guard CGPreflightPostEventAccess() else {
  FileHandle.standardError.write("no permission to post events: grant Accessibility to this terminal\n".data(using: .utf8)!)
  exit(3)
}

guard let sim = NSRunningApplication.runningApplications(
  withBundleIdentifier: "com.apple.iphonesimulator").first else {
  FileHandle.standardError.write("Simulator is not running\n".data(using: .utf8)!)
  exit(1)
}
sim.activate(options: [])
usleep(400_000)

guard let windows = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }

var device: CGRect? = nil
for window in windows {
  guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid == sim.processIdentifier,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
        let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
        w > 300 else { continue }
  let rect = CGRect(x: x, y: y, width: w, height: h)
  if device == nil || rect.width > device!.width { device = rect }
}
guard let window = device else {
  FileHandle.standardError.write("no Simulator device window\n".data(using: .utf8)!)
  exit(1)
}

let scale = window.width / pw
let point = CGPoint(x: window.minX + px * scale,
                    y: window.maxY - ph * scale + py * scale)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                   mouseCursorPosition: point, mouseButton: .left)
down?.setIntegerValueField(.mouseEventClickState, value: 1)
down?.post(tap: .cghidEventTap)
usleep(90_000)
let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                 mouseCursorPosition: point, mouseButton: .left)
up?.setIntegerValueField(.mouseEventClickState, value: 1)
up?.post(tap: .cghidEventTap)
SWIFT

menu() { # menu <"Menu"> <"Item">  — one Simulator menu item, by name
  osascript >/dev/null 2>&1 \
    -e 'tell application "Simulator" to activate' \
    -e 'delay 0.6' \
    -e "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"$2\" of menu \"$1\" of menu bar 1" \
    || true
}

submenu() { # submenu <"Menu"> <"Item"> <"Subitem">
  osascript >/dev/null 2>&1 \
    -e 'tell application "Simulator" to activate' \
    -e 'delay 0.6' \
    -e "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"$3\" of menu 1 of menu item \"$2\" of menu \"$1\" of menu bar 1" \
    || true
}

marked() { # marked <"Menu"> <"Item"> — is a menu item ticked?
  osascript 2>/dev/null \
    -e "tell application \"System Events\" to tell process \"Simulator\" to get value of attribute \"AXMenuItemMarkChar\" of menu item \"$2\" of menu \"$1\" of menu bar 1" \
    | grep -q '✓'
}

tap() { swift "$WORK/tap.swift" "$1" "$2" "$POINTS_W" "$POINTS_H"; sleep "${3:-2}"; }

shot() { # shot <name>
  raw="$WORK/raw.png"
  xcrun simctl io "$UDID" screenshot "$raw" >/dev/null 2>&1
  # The framebuffer is the panel's, so a landscape device arrives rotated.
  sips -r 270 --out "$OUT/$1.png" "$raw" >/dev/null
  rm -f "$raw"
  say "  wrote $OUT/$1.png"
}

# ---------------------------------------------------------------------------
# The device

say "Building the simulator app..."
flutter build ios --simulator --debug >/dev/null

UDID="$(xcrun simctl list devices -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for r in d.values() for x in r if x["name"]=="'"$DEVICE_NAME"'"), ""))')"

if [ -z "$UDID" ]; then
  say "Creating $DEVICE_NAME..."
  RUNTIME="$(xcrun simctl list runtimes -j \
    | python3 -c 'import json,sys;r=[x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x["isAvailable"] and "iOS" in x["identifier"]];print(r[-1] if r else "")')"
  [ -n "$RUNTIME" ] || die "No available iOS runtime."
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
fi
say "Device $UDID"

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# English, so the status bar's date is not the developer's locale. This needs a
# reboot to take, and the reboot is what loses the orientation set below — so
# it happens first, and only when it has to.
if [ "$(xcrun simctl spawn "$UDID" defaults read .GlobalPreferences AppleLocale 2>/dev/null)" != "en_US" ]; then
  say "Setting the device locale to en_US..."
  xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLanguages -array en-US
  xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLocale -string en_US
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
fi

# 9:41, full battery, no carrier. Per boot, so after the reboot above.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode notSupported

open -a Simulator
sleep 5

# The window has to be the device's screen and nothing else, or the tap mapping
# is off by the bezel. `Point Accurate` also stops a HiDPI Mac from picking a
# scale that leaves the window wider than the screen it contains.
marked Window "Show Device Bezels" && menu Window "Show Device Bezels"
menu Window "Point Accurate"
submenu Device Orientation "Landscape Left"
sleep 3

# Nothing else may be holding the ingest port. The plugin dials one socket and
# the first listener wins, so a copy of the application left running on another
# simulator — or on this Mac — takes the programme and this run photographs a
# test tone with the meters moving convincingly. The application does say so, in
# a notice across the top of the canvas, which is how this was found; a
# screenshot run should not depend on somebody reading it.
for other in $(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(" ".join(x["udid"] for r in d.values() for x in r))'); do
  [ "$other" = "$UDID" ] && continue
  xcrun simctl terminate "$other" "$BUNDLE_ID" >/dev/null 2>&1 || true
done
if lsof -nP -iTCP:47822 -sTCP:LISTEN >/dev/null 2>&1; then
  die "Something is already listening on 47822 — the desktop application, or a copy on another simulator. Quit it: the plugin would stream to that one instead."
fi

say "Installing the app..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

mkdir -p "$OUT"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 8

# ---------------------------------------------------------------------------
# The programme
#
# Real time, because the pictures are of history: the histogram is a minute
# wide and the spectrogram scrolls per published frame, so a run at --speed=0
# would fill them in a second and none of it would be the same minute the
# meters are showing.

say "Starting the fake DAW..."
"$FAKE_DAW" --track="$TRACK" --headless --speed=1 --seconds=420 --play >/dev/null 2>&1 &
DAW_PID=$!
sleep 6
kill -0 "$DAW_PID" 2>/dev/null || die "The fake DAW exited immediately — run it by hand to see why."

# And that it reached *this* copy. An established pair on 47822 is the whole
# difference between six pictures of a measurement and six pictures of a tone.
lsof -nP -iTCP:47822 -sTCP:ESTABLISHED 2>/dev/null | grep -q Runner \
  || die "The plugin is not connected to the application on 47822 — check the notice on the canvas."

# ---------------------------------------------------------------------------
# The pictures. Tap coordinates are device points; see POINTS_W above.

TAB_LOUDNESS_X=84;   TAB_SPECTRUM_X=144;  TAB_Y=87
BTN_TARGET_X=727;    BTN_ATTACH_X=1010;   BTN_SETTINGS_X=1208; BAR_Y=52
BTN_MODULE_X=1322
CLOSE_X=976;         CLOSE_ATTACH_Y=294

# **This number used to be paired with one in packaging/macos/screenshot.sh, and
# the pairing is what failed.** `01-loudness` was the website's tablet plate,
# beside a desktop plate shot by that script, under a paragraph saying the meter
# across the room cannot disagree with the one under your hand — matched by
# transport position, on the argument that the engine is deterministic. It is,
# and the two runs were still never at the same instant: they shipped reading
# 00:01:19:21 and 00:01:20:03, so LUFS-M differed by 0.2 and the VU needles
# pointed at different numbers. Both plates come out of one session now, one of
# them a display of the other — see `packaging/signal_path.sh`. What is left here
# is an App Store screenshot, and 74 seconds is simply enough programme to fill
# the histogram.
#
# The activate is cursor-free — AppleScript, not a posted event — and it is here
# because the app inside the simulator stops drawing when its window is hidden,
# exactly as the desktop one does.
osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1 || true
say "Waiting for a minute of programme..."
# 74.7 and not 74: the desktop shot lands on frame 21 of its second and this one
# landed on frame 4, which is two thirds of a second of programme and exactly the
# 0.1 LU the two plates differed by. The overhead either side of this sleep is
# repeatable to about a sixth of a second, so the fraction is worth carrying.
sleep 74.7
shot 01-loudness

if [ "$CANVAS_ONLY" -eq 1 ]; then
  say ""
  say "One screenshot in $OUT, and no mouse events were posted."
  say "Every reading in it was measured by the engine from $TRACK."
  exit 0
fi

say "Spectrum..."
tap "$TAB_SPECTRUM_X" "$TAB_Y" 3
sleep 45
shot 02-spectrum

say "Delivery targets..."
tap "$TAB_LOUDNESS_X" "$TAB_Y" 3
tap "$BTN_TARGET_X" "$BAR_Y" 2
shot 03-delivery-targets
tap "$TAB_LOUDNESS_X" "$TAB_Y" 2   # dismiss the menu

say "Module library..."
tap "$BTN_MODULE_X" "$TAB_Y" 2
shot 04-modules
tap "$TAB_LOUDNESS_X" "$TAB_Y" 2

say "Remote display..."
tap "$BTN_ATTACH_X" "$BAR_Y" 3
shot 05-remote-display
tap "$CLOSE_X" "$CLOSE_ATTACH_Y" 2

# **The settings panel is deliberately not one of these.** It is the obvious
# sixth picture and it cannot be published as it stands: its Source section
# explains System Output in terms of macOS 14.2, VB-Cable and PulseAudio, which
# is desktop copy being read on an iPad; the delivery target row names five
# streaming services, which is five other companies' trademarks on our store
# page; and Name and port shows whatever this device is called, which on a
# simulator is the developer's Mac. Fix the first, decide about the second, and
# a `tap "$BTN_SETTINGS_X" "$BAR_Y"` here is all it takes.

say ""
say "Five screenshots in $OUT. Every reading in them was measured by the engine"
say "from $TRACK — see the attribution beside it."
