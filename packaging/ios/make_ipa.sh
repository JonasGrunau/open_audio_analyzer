#!/bin/sh
#
# make_ipa.sh — build Open Audio Analyzer for iPadOS and export an App Store IPA.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/ios/make_ipa.sh
# Output: build/packaging/Open Audio Analyzer-<version>-ios.ipa
#
# ---------------------------------------------------------------------------
# This is the one artefact nobody can install from the releases page
#
# Every other script in packaging/ produces a file a user downloads and opens.
# This one produces a file only App Store Connect will accept: an App Store
# signature provisions no devices, so the IPA cannot be sideloaded, cannot be
# handed to a tester, and cannot be re-signed by whoever downloads it. It exists
# to be uploaded — `packaging/ios/testflight.sh` is the other half — and
# `ci.yml` deliberately keeps it off the release's asset list for that reason.
# Attaching it would publish an installer that installs nothing.
#
# ---------------------------------------------------------------------------
# Manual signing, injected through Release.xcconfig
#
# The Runner target is on **automatic** signing in `ios/Runner.xcodeproj`, and
# it stays there: that is what makes `flutter run -d <ipad>` work for whoever is
# developing here, with their own Apple ID and Xcode's own provisioning. A
# runner cannot use it. There is no Apple ID logged in, so automatic signing
# reaches out to create a distribution certificate — and an account caps how
# many of those may exist, so a workflow doing it on every release either fails
# on the cap or burns it, and neither failure names the cause.
#
# So the credentials arrive here instead, and are written into
# `ios/Flutter/Release.xcconfig` rather than into the project file. That file is
# the Release configuration's `baseConfigurationReference`, which means:
#
#   - Xcode reads it when it archives, so the archive signs with the
#     distribution certificate and not with whatever it would have invented;
#   - `xcodebuild -showBuildSettings` reports what it sets, which is where
#     `flutter build ipa` looks (see below);
#   - the Debug configuration is untouched, so nothing about a developer's
#     `flutter run` changes;
#   - and it is one file with one `#include` in it, so an appended block cannot
#     collide with anything.
#
# ---------------------------------------------------------------------------
# Why there is no ExportOptions.plist here
#
# There was going to be. `flutter build ipa --export-options-plist` takes one,
# and writing it looks like the explicit, honest thing to do — until you have to
# put a value in the `method` key. Xcode 15.4 renamed the export methods:
# `app-store` became `app-store-connect`, and a plist naming the wrong one for
# the Xcode on the runner fails the export. Flutter already knows this. Given
# `--export-method app-store` it asks Xcode its version and writes whichever
# string that version wants, so the flag is the version-proof spelling and a
# hand-written plist is the brittle one.
#
# It also writes the provisioning profile's **UUID** into the plist for us — but
# only when it can see all three of `CODE_SIGN_STYLE=Manual`,
# `PROVISIONING_PROFILE_SPECIFIER` and `DEVELOPMENT_TEAM` in the build settings,
# and only for a release or profile build. When it cannot, it silently falls
# back to a plist holding nothing but the method, which exports with *automatic*
# signing — the state described above. The xcconfig block below is exactly those
# three settings, and the assertions after the build are there because that
# fallback is a trace-level log message and nothing else.
#
# ---------------------------------------------------------------------------
# The build number is the workflow's, not the pubspec's
#
# TestFlight refuses a CFBundleVersion that is not higher than the last one
# uploaded for the same CFBundleShortVersionString, and it refuses it at the end
# of the upload — after the release is published, after everything else has
# gone green. `pubspec.yaml`'s `+N` is a hand-maintained number, so re-running a
# tag, or cutting two builds of one version, collides there and nowhere else.
# `OAA_BUILD_NUMBER` is set from the run counter in `ci.yml`, which only ever
# increases. Unset, the pubspec's own number is used, which is what you want
# when running this by hand.
#
# ---------------------------------------------------------------------------
# Credentials
#
#   OAA_SIGNING_CERTIFICATE           base64 of a .p12 holding the **Apple
#   OAA_SIGNING_CERTIFICATE_PASSWORD  Distribution** certificate and its
#                                     private key. Read by
#                                     packaging/macos/keychain.sh, which
#                                     `ci.yml` runs before this — the same
#                                     script the dmg uses, handed a different
#                                     certificate. A Developer ID certificate
#                                     signs a Mac app and is rejected here:
#                                     iOS App Store distribution is its own
#                                     certificate type.
#   OAA_IOS_PROFILE                   base64 of the .mobileprovision — an App
#                                     Store profile for the bundle id below.
#   OAA_IOS_TEAM_ID                   optional; defaults to the team in the
#                                     Xcode project.
#   OAA_IOS_SIGNING_IDENTITY          optional; defaults to "Apple
#                                     Distribution", which matches whichever
#                                     such certificate the keychain holds.
#   OAA_BUILD_NUMBER                  optional; see above.
#
# With no OAA_IOS_PROFILE this script prints why and exits 0, like every other
# script in packaging/: a fork has no credentials and must still go green. It
# produces nothing in that case rather than an unsigned IPA, because there is no
# such thing — an IPA with no distribution signature is an archive that failed
# to export.

set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "==> ipa: not macOS, nothing to build."
  exit 0
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
bundle_id=com.openaudioanalyzer.oaa
out="$root/build/packaging"
ipa="$out/Open Audio Analyzer-$version-ios.ipa"

if [ -z "${OAA_IOS_PROFILE:-}" ]; then
  echo "==> ipa: no OAA_IOS_PROFILE, nothing built."
  echo "    An App Store IPA cannot be produced unsigned, so this produces no"
  echo "    artefact rather than an unusable one. See the header of this file"
  echo "    for the four secrets a TestFlight upload needs."
  exit 0
fi

# --- The profile -----------------------------------------------------------

profile=$(mktemp "${TMPDIR:-/tmp}/oaa-profile.XXXXXX")
plist=$(mktemp "${TMPDIR:-/tmp}/oaa-profile-plist.XXXXXX")
trap 'rm -f "$profile" "$plist"' EXIT INT TERM

# `|| true` so that the check below is what reports this. Under `set -e` a
# failed decode kills the script on base64's own one-line complaint and the
# message underneath — the one that says what the variable should contain —
# never prints.
printf '%s' "$OAA_IOS_PROFILE" | base64 --decode >"$profile" 2>/dev/null || true
if [ ! -s "$profile" ]; then
  echo "make_ipa: OAA_IOS_PROFILE did not decode to anything. It must be" >&2
  echo "  base64 of the .mobileprovision file itself:" >&2
  echo "    base64 -i profile.mobileprovision | pbcopy" >&2
  exit 1
fi

# A .mobileprovision is a CMS-signed plist, so it cannot be read with plutil
# directly — the signature has to come off first.
if ! security cms -D -i "$profile" >"$plist" 2>&1; then
  echo "make_ipa: OAA_IOS_PROFILE decoded to $(wc -c <"$profile" | tr -d " ") bytes" >&2
  echo "  that are not a signed provisioning profile. Export the" >&2
  echo "  .mobileprovision from Xcode or the developer portal and base64 that" >&2
  echo "  file whole — not a certificate, and not the profile's contents." >&2
  exit 1
fi

profile_uuid=$(plutil -extract UUID raw -o - "$plist")
profile_name=$(plutil -extract Name raw -o - "$plist")
app_id=$(plutil -extract 'Entitlements.application-identifier' raw -o - "$plist")

echo "==> profile: $profile_name ($profile_uuid)"
echo "    application-identifier: $app_id"

# Three checks, each for a rejection that otherwise arrives at the very end of
# the upload — after the release has been published — and names no cause.
case "$app_id" in
  *".$bundle_id") : ;;
  *)
    echo "make_ipa: this profile is for $app_id, and the app is $bundle_id." >&2
    echo "  Xcode would sign with it and App Store Connect would refuse the" >&2
    echo "  upload as a bundle id it has no record of." >&2
    exit 1
    ;;
esac

if plutil -extract ProvisionedDevices raw -o - "$plist" >/dev/null 2>&1; then
  echo "make_ipa: this profile provisions specific devices, so it is a" >&2
  echo "  development or ad-hoc profile. Both export an IPA that builds," >&2
  echo "  signs and verifies, and that App Store Connect rejects. Create an" >&2
  echo "  App Store distribution profile for $bundle_id." >&2
  exit 1
fi

# Absent counts as a distribution profile; only an explicit true is a
# development one. `plutil -extract` exits non-zero on a missing key, which
# `set -e` would read as a failure of this script rather than as an answer.
task_allow=$(plutil -extract 'Entitlements.get-task-allow' raw -o - "$plist" 2>/dev/null || echo false)
if [ "$task_allow" != false ]; then
  echo "make_ipa: this profile allows debugging (get-task-allow), which no" >&2
  echo "  distribution profile does. It is a development profile." >&2
  exit 1
fi

# Both directories, deliberately. Xcode 16 and Flutter 3.44 read the first;
# every Xcode before that read the second. Installing into one of them works on
# exactly one side of that boundary, and the failure is the silent fallback to
# automatic signing described in the header rather than a missing-file error.
for dir in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"
do
  mkdir -p "$dir"
  cp "$profile" "$dir/$profile_uuid.mobileprovision"
done

# --- The signing settings --------------------------------------------------

team=${OAA_IOS_TEAM_ID:-$(grep -m1 'DEVELOPMENT_TEAM = ' ios/Runner.xcodeproj/project.pbxproj |
  sed 's/.*DEVELOPMENT_TEAM = //; s/;//')}
identity=${OAA_IOS_SIGNING_IDENTITY:-Apple Distribution}

if [ -z "$team" ]; then
  echo "make_ipa: no development team, and none in the Xcode project." >&2
  exit 1
fi

# The fourth check, and the one that cost a release. `app_id` is
# `<team>.<bundle id>`, so the profile names the team it was issued for and it
# can be held against the team the build is about to use. They differed once,
# and nothing here noticed: the Runner target's Release configuration set
# DEVELOPMENT_TEAM in its own `buildSettings`, which outranks the
# `baseConfigurationReference` the block below appends to, so the team written
# into the xcconfig was silently shadowed by the project's own. It surfaces from
# Xcode as `No profile for team 'X' matching 'Y' found` naming the *project's*
# team, with OAA_IOS_TEAM_ID set correctly and having no effect whatever — and
# the profile installed, valid, and for a different team. The line is gone from
# that configuration now; this is what says so if it ever comes back, which
# opening Signing & Capabilities in Xcode is enough to do.
profile_team=${app_id%%.*}
if [ "$profile_team" != "$team" ]; then
  echo "make_ipa: the profile was issued to team $profile_team and the build" >&2
  echo "  is configured for team $team, so Xcode would find no profile and" >&2
  echo "  fall back to signing with whatever it could invent." >&2
  echo "  Either team may print as *** above — that is Actions masking" >&2
  echo "  OAA_IOS_TEAM_ID, and the mismatch is real regardless. Check that" >&2
  echo "  OAA_IOS_TEAM_ID names the team the profile was created under, and" >&2
  echo "  that no DEVELOPMENT_TEAM has reappeared in the Runner target's" >&2
  echo "  Release configuration in ios/Runner.xcodeproj/project.pbxproj." >&2
  exit 1
fi

# Appended, not written: the file's one line is `#include "Generated.xcconfig"`,
# and Flutter regenerates what that include points at on every build. Replacing
# the file would drop it and the build would fail on a missing FLUTTER_ROOT.
cat >>ios/Flutter/Release.xcconfig <<EOF

// Appended by packaging/ios/make_ipa.sh. Not for committing — see that file for
// why the project itself stays on automatic signing.
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $team
PROVISIONING_PROFILE_SPECIFIER = $profile_name
CODE_SIGN_IDENTITY = $identity
EOF

echo "==> signing as $identity, team $team"

# --- Build -----------------------------------------------------------------

set -- --release --export-method app-store
if [ -n "${OAA_BUILD_NUMBER:-}" ]; then
  echo "==> build number $OAA_BUILD_NUMBER (pubspec's is used when unset)"
  set -- "$@" --build-number="$OAA_BUILD_NUMBER"
fi

flutter pub get
flutter build ipa "$@"

# --- Check what was actually signed ----------------------------------------
#
# The whole point. `flutter build ipa` exits 0 on an export that used the
# fallback ExportOptions.plist, and the IPA it leaves behind is signed with
# whatever automatic signing found — which on a runner is nothing usable. What
# distinguishes the two is inside the archive, so read it there.

archive=$(ls -d build/ios/archive/*.xcarchive 2>/dev/null | head -1 || true)
if [ -z "$archive" ]; then
  echo "make_ipa: no .xcarchive under build/ios/archive." >&2
  exit 1
fi

built=$(ls build/ios/ipa/*.ipa 2>/dev/null | head -1 || true)
if [ -z "$built" ]; then
  echo "make_ipa: the archive was created and no IPA was exported. That is" >&2
  echo "  what the silent ExportOptions.plist fallback looks like: read the" >&2
  echo "  xcodebuild output above for 'exportOptionsPlist' or for a signing" >&2
  echo "  certificate it could not find." >&2
  exit 1
fi

app="$archive/Products/Applications/Runner.app"
authority=$(codesign -dv --verbose=2 "$app" 2>&1 | grep '^Authority=' | head -1)
echo "==> $authority"
case "$authority" in
  *"Apple Distribution"*) : ;;
  *)
    echo "make_ipa: the archive is not signed with an Apple Distribution" >&2
    echo "  certificate, so the upload would be refused. $authority" >&2
    exit 1
    ;;
esac

mkdir -p "$out"
mv "$built" "$ipa"
echo "$ipa"
