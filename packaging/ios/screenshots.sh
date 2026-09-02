#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# App Store screenshots for the iPad build.
#
# Writes three 2752x2064 PNGs into packaging/ios/screenshots/ — the 13-inch
# iPad display size App Store Connect asks for, landscape. Nothing else is
# needed for a submission: one size covers every iPad, and this app is iPad only
# (TARGETED_DEVICE_FAMILY = 2), so no iPhone set is required.
#
# **Into the repository, not into build/.** These are what the store is given,
# nothing in CI can take them — a fake DAW, a simulator and a person's grant to
# post keys — and a set that lived in `build/packaging/` was one clean away from
# being gone. They are committed, like the feature graphic beside the Android
# script, and a run overwrites them in place.
#
#   01-loudness.png           the Loudness tab, in the default skin
#   02-spectrum.png           the Spectrum tab, in the default skin
#   03-loudness-daylight.png  the Loudness tab again, in the light skin
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
# Nothing here moves the pointer
#
# This script used to post mouse clicks at the Simulator's window — five
# pictures, four of them reached by tapping a tab, a button or a menu at a
# coordinate read off a finished screenshot — and it owned the mouse for the two
# or three minutes it ran. It was also wrong twice without failing once: the
# menu row gained a FILE button, and then the readings left it for a status bar
# of their own, so every tap aimed at a control in that row landed on a
# different one and the remote-display picture came out as the plain canvas.
# Every picture was still real, which is why nothing said so.
#
# Nothing with coordinates is posted any more, and the three things a picture
# needs are each done another way:
#
# **The tab is a key.** `lib/src/app/shortcuts.dart` binds the bare digits to
# "go to a tab by number", so `2` opens the Spectrum tab with no modifier and no
# pointer. The Simulator forwards a hardware keyboard to the device, and a bare
# digit is what it forwards — a chord with ⌘ in it is the Simulator's own (⌘1
# to ⌘3 scale the window), which is why the earlier note here said the app's
# shortcuts "do not work" from a script. The Loudness runs post `1`, which
# selects the tab that is already selected; it is sent anyway so that every run
# takes the same path.
#
# **The skin is a file.** A skin is a setting, and settings are `settings.json`
# in the app's configuration directory, which on iOS is inside the app's data
# container — `xcrun simctl get_app_container` says where. It is written before
# the launch that photographs it, so the light picture is the application
# starting up in Daylight exactly as an iPad that had chosen it would, rather
# than the theme panel being opened and a row pressed. `AppSettings.fromJson`
# defends every field separately, so a document naming only the skin is read as
# the defaults plus that skin.
#
# **The orientation is one key too, and it is checked.** `simctl` cannot
# rotate, and the Simulator's `SimulatorWindowOrientation` preference describes
# the *window* rather than the device — write LandscapeLeft into it and the
# springboard comes up portrait anyway. What is left is the Simulator's own
# Rotate Right, ⌘→, posted at a device booted from cold, because a fresh boot
# is portrait. The press is not trusted blind: the first run of this version
# posted it eight seconds after opening the Simulator, the window was not ready
# to take it, and the run went on to photograph a portrait canvas. So the
# Simulator's device window is waited for first, and after each press its
# bounds are read back off the public window list — `kCGWindowBounds` is
# available to anyone, and a landscape device is a window wider than it is
# tall, because the Simulator turns its window with the device. That is also
# why the orientation preference is *not* written here: it would shape the
# window without turning the device, and the check would then pass on a
# portrait springboard. The framebuffer stays the panel's, so every capture is
# turned by `sips` afterwards.
#
# Both keys need only the grant `CGPreflightPostEventAccess` reports; the
# Simulator is brought forward with `NSRunningApplication.activate`, which is
# an API call and not a synthesised click. No Accessibility grant is needed
# anywhere in this file — `System Events` is not used.
#
# ---------------------------------------------------------------------------
# One launch per picture
#
# The obvious shape is one session and three shutters: settle, shoot, press 2,
# shoot, change the skin, shoot. It does not work, for two reasons that are
# both the application being right. A skin is read at launch, so the third
# picture needs a launch of its own regardless; and the Spectrum tab's
# spectrogram accumulates from `engine.generation`, so a module that was not
# on screen during the settle has nothing in it. So every picture is a fresh
# launch — configuration directory wiped, skin written, app started, tab
# chosen, *then* the fake DAW started from the top of the track and the same
# settle waited. The three are therefore three sessions, and the honest thing
# is to say so; what it buys is that all three stand at the same second of the
# same programme, and 01 and 03 are the same tab at the same instant of it in
# two skins.
#
# The settle is real time, because the pictures are of history: the histogram
# is a minute wide and the spectrogram scrolls per published frame, so a run at
# --speed=0 would fill them in a second and none of it would be the same minute
# the meters are showing. Nothing is frozen before a shutter — `simctl io
# screenshot` reads the framebuffer as it stands, and a single picture has
# nothing to agree with.
#
# The Simulator window has to stay uncovered for the whole run. The app inside
# it stops drawing when its window is hidden, exactly as the desktop one does,
# and a canvas that has stopped drawing has stopped consuming the plugin's
# stream. Being frontmost is not the requirement; being visible is.
#
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - Xcode, and an iOS runtime with an iPad Pro 13-inch device type.
#   - Permission to post key events — Input Monitoring, or whatever the
#     Accessibility-adjacent grant `CGPreflightPostEventAccess` reports — for
#     the ⌘→ that turns the device on its side and the digit that picks a tab.
#     No pointer event is posted. The script checks up front and says which
#     grant it is short of.
#   - Only one booted simulator, because a key goes to a window.
#   - `test_audio/citizens-apathy.flac`: `dart run tool/fetch_test_audio.dart`.
#   - The fake DAW and the VST3, which is the full plugin build:
#       cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
#       cmake --build plugin/build
#   - Port 47822 free. A copy of the application already running — on this Mac
#     or on another simulator — takes the plugin's link, and this photographs a
#     canvas reading a test tone with the meters moving convincingly.
#
# Usage: sh packaging/ios/screenshots.sh [--no-build]
#
# `--no-build` skips `flutter build ios --simulator --debug` and photographs
# whatever build/ios/iphonesimulator/Runner.app already is.
#
# **The website's tablet plate does not come from here.** It is shot by
# `packaging/signal_path.sh`, as a display attached to the desktop it stands
# next to, and both plates come out of one frozen frame. These three are the
# App Store's.
set -eu

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

DEVICE_NAME="OAA-Screenshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB"
BUNDLE_ID="com.openaudioanalyzer.oaa"
APP="build/ios/iphonesimulator/Runner.app"
OUT="packaging/ios/screenshots"
TRACK="test_audio/citizens-apathy.flac"
FAKE_DAW="plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app/Contents/MacOS/oaa-fake-daw"
WORK="$(mktemp -d)"

# The tabs of the default canvas, as digits. `defaultPreset()` in
# lib/src/canvas/workspace.dart is the order; the digit is the shipped binding.
TAB_LOUDNESS=1
TAB_SPECTRUM=2

# Skin ids, from packages/oaa_core/lib/src/skin.dart. An empty skin means the
# default, which is the dark one.
SKIN_DEFAULT=""
SKIN_LIGHT="daylight"

# Seconds of programme before each shutter. Enough to fill the histogram, which
# is a minute wide, with a little over for the ramp at the top of the track.
SETTLE=75

DAW_PID=""

cleanup() {
  [ -n "$DAW_PID" ] && kill "$DAW_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ -f "$TRACK" ] || die "No $TRACK. Run: dart run tool/fetch_test_audio.dart"
[ -x "$FAKE_DAW" ] || die "No fake DAW at $FAKE_DAW. Build the plugin first — see the header."

# ---------------------------------------------------------------------------
# The helpers that are not shell

# Posts one key at the Simulator. `key <virtual key> [command]`.
#
# The Simulator is activated first because a posted key goes wherever the
# focus is; `activate` is an API call and not a synthesised click, so the
# pointer stays wherever the person left it.
cat > "$WORK/key.swift" <<'SWIFT'
import Cocoa

let a = CommandLine.arguments
guard a.count >= 2, let code = UInt16(a[1]) else {
  FileHandle.standardError.write("usage: key <virtual key> [command]\n".data(using: .utf8)!)
  exit(2)
}
let command = a.count >= 3 && a[2] == "command"

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
  let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
  if command { event?.flags = .maskCommand }
  event?.post(tap: .cghidEventTap)
  usleep(80_000)
}
SWIFT

# Whether the grant is there, before anything is booted. The same check the
# helper makes, made once up front so that a missing permission costs seconds
# and not a device boot.
cat > "$WORK/preflight.swift" <<'SWIFT'
import CoreGraphics
exit(CGPreflightPostEventAccess() ? 0 : 3)
SWIFT
swift "$WORK/preflight.swift" \
  || die "No permission to post key events. Grant Input Monitoring (or Accessibility) to this terminal in System Settings — the tab digit and the rotation are keys, and nothing else is posted."

# Virtual key codes. 124 is the right arrow; the digits are the ANSI row, which
# a German layout maps to the same characters.
VK_RIGHT=124
vk_digit() { # vk_digit <1..9>
  case "$1" in
    1) echo 18 ;; 2) echo 19 ;; 3) echo 20 ;; 4) echo 21 ;; 5) echo 23 ;;
    6) echo 22 ;; 7) echo 26 ;; 8) echo 28 ;; 9) echo 25 ;;
    *) die "no such tab digit: $1" ;;
  esac
}

# The Simulator's window, as the preferences that decide it.
#
# Written while Simulator.app is not running, because it reads them at launch
# and writes them back on quit — so a copy already running would undo this at
# the worst moment. `ShowChrome` is the bezels, off, because a store picture
# wants the device's screen; the hardware keyboard is what carries the digit to
# the app. The orientation preference is deliberately absent — see the header.
cat > "$WORK/simprefs.py" <<'PYTHON'
import plistlib, subprocess, sys

udid = sys.argv[1]
domain = "com.apple.iphonesimulator"

exported = subprocess.run(["defaults", "export", domain, "-"],
                          capture_output=True, check=True).stdout
prefs = plistlib.loads(exported) if exported.strip() else {}

prefs["ShowChrome"] = False
prefs["ConnectHardwareKeyboard"] = True
# Which device Simulator opens on, so that the window the keys reach is this one.
prefs["CurrentDeviceUDID"] = udid
device = prefs.setdefault("DevicePreferences", {}).setdefault(udid, {})
device.pop("SimulatorWindowOrientation", None)
device.pop("SimulatorWindowRotationAngle", None)

subprocess.run(["defaults", "import", domain, "-"],
               input=plistlib.dumps(prefs), check=True)
PYTHON

# The Simulator's device window, from the public window list, as one word:
# `landscape` or `portrait`. Exits 1 while there is no such window yet.
# `kCGWindowBounds` needs no grant — it is the window *image* that Screen
# Recording gates, and nothing here reads one.
cat > "$WORK/window.swift" <<'SWIFT'
import Cocoa

guard let sim = NSRunningApplication.runningApplications(
  withBundleIdentifier: "com.apple.iphonesimulator").first else { exit(1) }
guard let list = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
  exit(1)
}
var best: CGSize? = nil
for w in list {
  guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid == sim.processIdentifier,
        let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
        let bounds = w[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
        width > 300 else { continue }
  let size = CGSize(width: width, height: height)
  if best == nil || size.width * size.height > best!.width * best!.height { best = size }
}
guard let size = best else { exit(1) }
print(size.width > size.height ? "landscape" : "portrait")
SWIFT

shot() { # shot <name>
  raw="$WORK/raw.png"
  xcrun simctl io "$UDID" screenshot "$raw" >/dev/null 2>&1
  # The framebuffer is the panel's, so a landscape device arrives rotated.
  sips -r 90 --out "$OUT/$1.png" "$raw" >/dev/null
  rm -f "$raw"
  say "  wrote $OUT/$1.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$1.png" \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
}

# ---------------------------------------------------------------------------
# The device

if [ "$BUILD" -eq 1 ]; then
  say "Building the simulator app..."
  flutter build ios --simulator --debug >/dev/null
fi
[ -d "$APP" ] || die "No $APP. Run without --no-build."

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

# Only this one may be booted. The keys below go to whichever window has the
# focus, and a second device is a second window to land in.
OTHERS="$(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(" ".join(x["name"] for r in d.values() for x in r if x["udid"] != "'"$UDID"'"))')"
[ -z "$OTHERS" ] || die "Other simulators are booted ($OTHERS). Shut them down: a posted key would go to one of their windows."

# **Booted from cold, every time.** A fresh boot is portrait, which is what
# lets the rotation below start from a known state. It also takes the locale,
# which needs a reboot — and the locale is set to English so the status bar's
# date is not the developer's. And it ends whatever this device was running,
# including a copy of the application a previous run left holding the port.
say "Booting the device..."
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLanguages -array en-US 2>/dev/null || true
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLocale -string en_US 2>/dev/null || true
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# Nothing else may be holding the ingest port. The plugin dials one socket and
# the first listener wins, so a copy of the application left running on this
# Mac takes the programme and this run photographs a test tone with the meters
# moving convincingly. The application does say so, in a notice across the top
# of the canvas, which is how this was found; a screenshot run should not
# depend on somebody reading it. Checked after the reboot, which is what frees
# the port from a copy on this device.
if lsof -nP -iTCP:47822 -sTCP:LISTEN >/dev/null 2>&1; then
  die "Something is already listening on 47822 — the desktop application, or a copy on another simulator. Quit it: the plugin would stream to that one instead."
fi

# 9:41, full battery, no carrier. Per boot, so after the reboot above.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode notSupported

# Quit first, so that the preferences below are not overwritten on the way out
# by a copy that was already running with the old ones. The Apple Event needs
# the Automation grant and a terminal without it gets an error rather than a
# quit, so a plain signal stands behind it.
osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -x Simulator 2>/dev/null || true
sleep 1
python3 "$WORK/simprefs.py" "$UDID"

open -a Simulator

# The window, before any key is aimed at it. A fixed sleep here is how the
# first run of this version came to photograph a portrait canvas.
say "Waiting for the Simulator's window..."
waited=0
until swift "$WORK/window.swift" >/dev/null 2>&1; do
  sleep 1
  waited=$((waited + 1))
  [ "$waited" -ge 60 ] && die "The Simulator never showed a device window."
done
sleep 3

say "Turning the device on its side..."
presses=0
until [ "$(swift "$WORK/window.swift" 2>/dev/null)" = "landscape" ]; do
  presses=$((presses + 1))
  [ "$presses" -le 4 ] || die "The device is still portrait after $((presses - 1)) presses of ⌘→ — see the header."
  swift "$WORK/key.swift" "$VK_RIGHT" command || die "Could not rotate the device — see the header."
  sleep 3
done

say "Installing the app..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

# Where the app keeps its configuration: `resolveConfigRoot`'s iOS branch, under
# the data container `simctl` hands out for the install just made.
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
CONFIG="$CONTAINER/Library/Application Support/Open Audio Analyzer"

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# One picture, one launch, one shutter

shoot() { # shoot <name> <tab digit> <skin id or "">
  name="$1"; digit="$2"; skin="$3"

  say ""
  say "$name..."
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1

  # A first launch every time: the canvas is the default layout and the skin
  # is the one asked for, written the way the application writes it.
  rm -rf "$CONFIG"
  mkdir -p "$CONFIG"
  if [ -n "$skin" ]; then
    printf '{"version": 1, "skin": "%s"}\n' "$skin" > "$CONFIG/settings.json"
  fi

  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 8

  say "  selecting tab $digit..."
  swift "$WORK/key.swift" "$(vk_digit "$digit")" || die "Could not post the tab key — see the header."
  sleep 2

  # The shipped path: the fake DAW plays the track through the real VST3, the
  # plugin dials 127.0.0.1:47822, and the application accepts it. From the top
  # of the track for every picture, so all three stand at the same second.
  "$FAKE_DAW" --track="$TRACK" --headless --speed=1 --seconds=$((SETTLE + 60)) --play >/dev/null 2>&1 &
  DAW_PID=$!
  sleep 4
  kill -0 "$DAW_PID" 2>/dev/null || die "The fake DAW exited immediately — run it by hand to see why."

  # Wait for the pair, then start counting. The settle is transport time, and
  # it is only transport time if the link is up when the clock starts. Matched
  # on the plugin end: lsof prints the app as `Runner`, but the fake DAW's name
  # is the one that cannot be another process.
  waited=0
  until lsof -nP -iTCP:47822 -sTCP:ESTABLISHED 2>/dev/null | grep -q "oaa-fake-"; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge 30 ] && die "The plugin never connected on 47822 — check the notice on the canvas."
  done

  say "  waiting ${SETTLE}s for the programme..."
  sleep "$SETTLE"
  shot "$name"

  kill "$DAW_PID" 2>/dev/null || true
  wait "$DAW_PID" 2>/dev/null || true
  DAW_PID=""
}

shoot 01-loudness          "$TAB_LOUDNESS" "$SKIN_DEFAULT"
shoot 02-spectrum          "$TAB_SPECTRUM" "$SKIN_DEFAULT"
shoot 03-loudness-daylight "$TAB_LOUDNESS" "$SKIN_LIGHT"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

say ""
say "Three screenshots in $OUT, and no pointer event was posted. Every reading"
say "in them was measured by the engine from $TRACK — see the attribution"
say "beside it."
