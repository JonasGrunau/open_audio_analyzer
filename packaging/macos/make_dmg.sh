#!/bin/sh
#
# make_dmg.sh — build Open Audio Analyzer for macOS and wrap it in a disk image.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/macos/make_dmg.sh [--skip-build]
# Output: build/packaging/Open Audio Analyzer-<version>-macos-<arch>.dmg
#
# ---------------------------------------------------------------------------
# The Mac App Store is not a target, and that is a decision rather than a gap
#
# Open Audio Analyzer's macOS build is deliberately **not sandboxed**. A
# sandboxed application has its HOME redirected into
# ~/Library/Containers/<bundle id>/Data, which put every preset, skin and
# delivery target inside a container no user goes looking in and that
# OAA_CONFIG_DIR could not escape — see the comment at the top of
# macos/Runner/*.entitlements, and lib/src/storage/config_paths.dart, whose
# paths are only true because of it.
#
# The App Store requires the sandbox. So the store is out, and direct
# distribution — this dmg, signed with a Developer ID and notarised — is the
# only channel. Written here rather than in a document because this script is
# where somebody is standing when the question occurs to them.
#
# ---------------------------------------------------------------------------
# Signing, notarising, and what happens when you do neither
#
# Three states, and the script tells you which one you are in:
#
#   Neither         The dmg is built and ad-hoc signed. Gatekeeper refuses it
#                   on any machine but this one; the user must right-click ->
#                   Open, and macOS will still warn. Fine for a test build,
#                   never for a release.
#   Signed only     OAA_SIGNING_IDENTITY set. Gatekeeper still refuses on a
#                   first launch after download, because the quarantine flag
#                   requires notarisation, not merely a signature. This state
#                   surprises people; it is called out below.
#   Signed+notarised  OAA_SIGNING_IDENTITY and OAA_NOTARY_PROFILE both set.
#                   The only combination a user can double-click.
#
#   OAA_SIGNING_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   OAA_NOTARY_PROFILE    a `xcrun notarytool store-credentials` profile name
#
# The hardened runtime is required for notarisation and is always requested.
# The microphone entitlement is in the .entitlements files and must survive
# signing, or capture fails at runtime with a permission error nobody asked for.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
arch=$(uname -m)
app="build/macos/Build/Products/Release/oaa.app"
out="build/packaging"
dmg="$out/Open Audio Analyzer-$version-macos-$arch.dmg"
staging="build/packaging/dmg-staging"

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> flutter build macos --release"
  flutter build macos --release
fi

if [ ! -d "$app" ]; then
  echo "make_dmg: $app does not exist. Build first, or drop --skip-build." >&2
  exit 1
fi

mkdir -p "$out"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"

# --- Sign ------------------------------------------------------------------

if [ -n "${OAA_SIGNING_IDENTITY:-}" ]; then
  echo "==> codesign as $OAA_SIGNING_IDENTITY"
  # --deep is deprecated and does the wrong thing with nested code. The app
  # bundle carries one framework tree; signing inside-out is the supported
  # order, and codesign refuses to re-sign a nested item after its container.
  find "$app/Contents/Frameworks" -name "*.framework" -maxdepth 1 -print 2>/dev/null |
    while read -r framework; do
      codesign --force --timestamp --options runtime \
        --sign "$OAA_SIGNING_IDENTITY" "$framework"
    done

  codesign --force --timestamp --options runtime \
    --entitlements macos/Runner/Release.entitlements \
    --sign "$OAA_SIGNING_IDENTITY" "$app"

  codesign --verify --strict --verbose=2 "$app"
else
  echo "==> no OAA_SIGNING_IDENTITY: ad-hoc signing"
  # Ad-hoc rather than unsigned. An unsigned bundle on Apple silicon does not
  # merely warn, it refuses to launch at all, which reads as a broken build.
  codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$app"
fi

# --- Assemble --------------------------------------------------------------

cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

# The licences travel with the binary. Both bundled font families are SIL OFL
# 1.1 and their licence files must ship with anything they are embedded in.
mkdir -p "$staging/Licences"
cp LICENSE "$staging/Licences/"
cp assets/fonts/*-LICENSE.txt "$staging/Licences/" 2>/dev/null || true

echo "==> hdiutil create $dmg"
# UDZO: compressed and readable by every macOS that can run this build. No
# fancy window layout — a background image and an .DS_Store are a second thing
# to keep in step with the icon, for a window a user looks at for two seconds.
hdiutil create \
  -volname "Open Audio Analyzer $version" \
  -srcfolder "$staging" \
  -ov -format UDZO \
  "$dmg" >/dev/null

rm -rf "$staging"

# --- Notarise --------------------------------------------------------------

if [ -n "${OAA_NOTARY_PROFILE:-}" ]; then
  echo "==> notarytool submit (this waits for Apple)"
  xcrun notarytool submit "$dmg" --keychain-profile "$OAA_NOTARY_PROFILE" --wait
  # Stapling is what makes the dmg work on a machine with no network. Without
  # it Gatekeeper has to ask Apple at first launch, and an engineer on a plane
  # gets a refusal for a build that was notarised weeks ago.
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  echo "==> signed, notarised and stapled"
elif [ -n "${OAA_SIGNING_IDENTITY:-}" ]; then
  echo "==> signed but NOT notarised."
  echo "    Gatekeeper will still refuse this on first launch after download."
  echo "    Set OAA_NOTARY_PROFILE to finish the job."
else
  echo "==> ad-hoc signed. This dmg will not open on another Mac without the"
  echo "    user right-clicking Open and accepting a warning. Test builds only."
fi

echo "$dmg"
