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
# nothing in CI can take them — a fake DAW, a simulator and a person to turn
# the device — and a set that lived in `build/packaging/` was one clean away from
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
# Nothing is posted any more, at anything, and nothing is brought to the front.
# The three things a picture needs are each done another way:
#
# **The tab is a launch option.** `--tab=2` opens the application on the
# Spectrum tab — `lib/src/app/launch_options.dart` says why it exists. It
# replaced a key: the bare digit is a shipped binding, but a key can only be
# delivered to the window that has the focus, and taking the focus is taking it
# from whoever is at the machine. A key handed to the Simulator's *process*
# instead (`CGEventPostToPid`) arrives and selects nothing — Flutter's key
# handling is not on that path.
#
# **The skin is a file.** A skin is a setting, and settings are `settings.json`
# in the app's configuration directory, which on iOS is inside the app's data
# container — `xcrun simctl get_app_container` says where. It is written before
# the launch that photographs it, so the light picture is the application
# starting up in Daylight exactly as an iPad that had chosen it would.
#
# **The orientation is checked and never set.** `simctl` cannot rotate, and
# every way of turning the device from a script — a posted ⌘→, a key handed to
# the Simulator's process, its Device menu through the accessibility API —
# takes effect only while the Simulator is frontmost. So the device is turned
# once, by a person, and left booted: its orientation lives for as long as the
# boot does, this script keeps a booted device as it finds it, and it refuses,
# naming the menu to use, rather than reaching for the keyboard. The check reads
# the Simulator's window off the public window list — `kCGWindowBounds` needs
# no grant — because the Simulator turns its window with the device; that is
# also why `SimulatorWindowOrientation` is *removed* from its preferences
# rather than written: present, it pins the device so that nothing rotates it.
# The framebuffer stays the panel's, so every capture is turned by `sips`.
#
# The Simulator is opened with `open -g`, behind whatever the person is
# working in, and stays there: `simctl io` reads the framebuffer, so its window
# need not be visible at all. No Accessibility grant, no Input Monitoring, no
# `System Events`, and no Screen Recording either.
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
# ---------------------------------------------------------------------------
# Prerequisites
#
#   - Xcode, and an iOS runtime with an iPad Pro 13-inch device type.
#   - Only one booted simulator, already turned on its side — Device ›
#     Orientation › Landscape Left, once, by hand. It stays turned for as long
#     as it is booted, and a portrait one is refused rather than turned.
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
[ -z "$OTHERS" ] || die "Other simulators are booted ($OTHERS). Shut them down: the orientation check reads one window."

# **Booted from cold, every time.** A fresh boot is portrait, which is what
# lets the rotation below start from a known state. It also takes the locale,
# which needs a reboot — and the locale is set to English so the status bar's
# date is not the developer's. And it ends whatever this device was running,
# including a copy of the application a previous run left holding the port.
# **A booted device is kept as it is** — its orientation lives for as long as
# the boot does, and nothing here can turn it without taking the focus; see the
# header. Only a device that is not running is booted, and that boot is what
# takes the locale.
if xcrun simctl list devices booted -j | grep -q "\"$UDID\""; then
  say "The device is already booted; keeping it as it is."
else
  say "Booting the device..."
  xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLanguages -array en-US 2>/dev/null || true
  xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleLocale -string en_US 2>/dev/null || true
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
fi

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

# **A running Simulator is left running.** Quitting it is what loses the
# device's orientation — the Simulator, not the device, remembers which way up
# it is, and a relaunch comes up portrait — and the only reason to relaunch was
# to write window preferences that no longer matter, because the window need
# not be seen. So the preferences are written, and the Simulator opened, only
# when it is not already running; and `-g` opens it behind whatever the person
# is working in, never activated.
if pgrep -x Simulator >/dev/null 2>&1; then
  say "The Simulator is already running; leaving it as it is."
else
  python3 "$WORK/simprefs.py" "$UDID"
  open -g -a Simulator
fi

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

say "Checking the device is on its side..."
# Checked, never pressed: every way of turning it from here works only while
# the Simulator is frontmost, and making it frontmost takes the focus from
# whoever is at the machine. See the header.
# Polled, because a window that has just reopened is portrait-shaped for a
# moment before it follows the device.
waited=0
until [ "$(swift "$WORK/window.swift" 2>/dev/null)" = "landscape" ]; do
  waited=$((waited + 1))
  [ "$waited" -le 10 ] || die "\
The device is not in landscape. Turn it once yourself — Device › Orientation ›
  Landscape Left in the Simulator — and run this again; it stays turned for as
  long as it is booted, and this script does not press keys at your machine."
  sleep 2
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

  # The tab is a launch option rather than a key: a key can only be delivered
  # to the window with the focus. See `lib/src/app/launch_options.dart`.
  xcrun simctl launch "$UDID" "$BUNDLE_ID" --args "--tab=$digit" >/dev/null
  sleep 8

  say "  on tab $digit..."
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
