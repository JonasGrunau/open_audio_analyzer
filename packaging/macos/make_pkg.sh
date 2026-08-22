#!/bin/sh
#
# make_pkg.sh — build Open Audio Analyzer for macOS and wrap the application,
# the VST3 and the Audio Unit in one installer package.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/macos/make_pkg.sh [--skip-build] [--plugins <dir>]
# Output: build/packaging/Open Audio Analyzer-<version>-macos.pkg
#
# <dir> holds VST3/ and AU/, which is the layout both of
# plugin/build/OaaPlugin_artefacts/Release and of the oaa-plugin-macOS.tar.gz
# that ci.yml's plugin job uploads. Defaults to the first.
#
# ---------------------------------------------------------------------------
# This replaced the dmg, and the reason is the fifteen lines it deletes
#
# A disk image is a mounted folder. It can carry a plugin but it cannot
# install one, so docs/site/install.md spent a screenful telling people to
# create /Library/Audio/Plug-Ins/VST3 by hand, copy a bundle and not the
# directory holding it, and then find the option in Live's preferences. Every
# one of those steps is a place to get it wrong quietly — a plugin in the
# wrong folder and a plugin that failed to load look identical from inside a
# DAW, which is to say: like nothing at all.
#
# A pkg is also the only macOS format with a checkbox in it. That is the whole
# feature; see packaging/macos/pkg/distribution.xml for what the three rows
# do and why one of them cannot be unticked.
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
# distribution — this package, signed with a Developer ID and notarised — is
# the only channel.
#
# ---------------------------------------------------------------------------
# Two certificates, and the one that is easy to be missing
#
#   OAA_SIGNING_IDENTITY     "Developer ID Application: Name (TEAMID)"
#                            Signs code: the .app and its frameworks.
#   OAA_INSTALLER_IDENTITY   "Developer ID Installer: Name (TEAMID)"
#                            Signs the package, and nothing else can.
#
# They are different certificates from the same account and are not
# interchangeable — `productbuild --sign` given an Application identity fails
# with "no identity found", naming a certificate that is sitting right there
# in the keychain. packaging/macos/keychain.sh imports both from one .p12 and
# now refuses to finish if either name has nothing behind it.
#
# Three states, as the dmg had:
#
#   Neither         Built unsigned. Gatekeeper refuses it outright; useful for
#                   checking the layout and useless to a user.
#   Signed only     Refused on any machine that downloaded it, because
#                   quarantine wants a notarisation ticket and not a
#                   signature. This is the state that surprises people.
#   Signed+notarised  The only combination anybody can double-click.
#
# ---------------------------------------------------------------------------
# BundleIsRelocatable, which will ruin an install with no error at all
#
# pkgbuild marks every bundle it finds as relocatable by default. At install
# time the Installer then asks Spotlight where that bundle identifier already
# lives and puts the payload *there* instead of at the install-location — so a
# machine with an old copy of the app in ~/Downloads gets the update written
# into ~/Downloads, and /Applications keeps the version it had. It reports
# success. The pkg has to carry a component plist with the flag turned off,
# which is what `pkgbuild --analyze` and the PlistBuddy loop below are for.
#
# It is the *application* this catches: left alone, pkgbuild writes
# `<relocate><bundle id="com.openaudioanalyzer.oaa"/></relocate>` into its
# PackageInfo. The .vst3 and .component are not bundles pkgbuild will relocate
# and the loop finds nothing in them — it runs over all three anyway, because
# which formats qualify is Apple's rule to change and not ours to memorise.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
app="build/macos/Build/Products/Release/Open Audio Analyzer.app"
plugins="plugin/build/OaaPlugin_artefacts/Release"
out="build/packaging"
pkg="$out/Open Audio Analyzer-$version-macos.pkg"
skip_build=

while [ $# -gt 0 ]; do
  case $1 in
    --skip-build) skip_build=1 ;;
    --plugins)    shift; plugins=${1:?--plugins needs a directory} ;;
    *) echo "make_pkg: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$skip_build" ]; then
  echo "==> flutter build macos --release"
  flutter build macos --release
fi

vst3="$plugins/VST3/Open Audio Analyzer.vst3"
au="$plugins/AU/Open Audio Analyzer.component"

if [ ! -d "$app" ]; then
  echo "make_pkg: $app does not exist. Build first, or drop --skip-build." >&2
  exit 1
fi

# Required, not optional. A package that quietly ships without its plugins is
# indistinguishable from one that has them until somebody opens a DAW, and the
# download page cannot tell them apart at all.
for bundle in "$vst3" "$au"; do
  if [ ! -d "$bundle" ]; then
    echo "make_pkg: $bundle does not exist." >&2
    echo "  The plugins are the point of this package. Build them with:" >&2
    echo "    cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release \\" >&2
    echo "      -DOAA_CODESIGN_IDENTITY=\"\${OAA_SIGNING_IDENTITY:--}\"" >&2
    echo "    cmake --build plugin/build" >&2
    echo "  or point --plugins at an unpacked oaa-plugin-macOS.tar.gz." >&2
    exit 1
  fi
done

mkdir -p "$out"
rm -f "$pkg"
work="$out/pkg-work"
rm -rf "$work"
mkdir -p "$work/resources"

# --- Sign the application --------------------------------------------------
#
# The plugin bundles are signed and verified by plugin/CMakeLists.txt, which
# is the only place that can do it in the right order — JUCE writes
# moduleinfo.json after signing the VST3, so the seal has to be redone after
# the whole target is finished. They are not re-signed here; they are checked,
# because a broken seal inside a notarised package is a package Apple accepts
# and a DAW refuses.

if [ -n "${OAA_SIGNING_IDENTITY:-}" ]; then
  echo "==> codesign as $OAA_SIGNING_IDENTITY"
  # --deep is deprecated and does the wrong thing with nested code. Signing
  # inside-out is the supported order, and codesign refuses to re-sign a
  # nested item after its container.
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
  echo "==> no OAA_SIGNING_IDENTITY: ad-hoc signing the application"
  # Ad-hoc rather than unsigned. An unsigned bundle on Apple silicon does not
  # merely warn, it refuses to launch at all, which reads as a broken build.
  codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$app"
fi

for bundle in "$vst3" "$au"; do
  if codesign --verify --strict "$bundle" 2>/dev/null; then
    echo "==> seal intact: $(basename "$bundle")"
  else
    echo "make_pkg: $bundle fails codesign --verify --strict." >&2
    echo "  Delete plugin/build/OaaPlugin_artefacts and rebuild — an" >&2
    echo "  incremental build hides this, because the file that invalidates" >&2
    echo "  the seal is already present when the seal is computed." >&2
    exit 1
  fi
done

# --- Licences --------------------------------------------------------------
#
# Generated rather than held, so it cannot go stale against LICENSE. The
# package carries binaries under three licences and the plugins' is the
# strictest of them; a notice that names only the application's would be
# wrong about the two bundles this format exists to install.

{
  cat <<'NOTICE'
Open Audio Analyzer

This package installs binaries under more than one licence:

  The application                    GPL-3.0-or-later
  The VST3 and Audio Unit plug-ins   AGPL-3.0-or-later, because they link JUCE
  The DSP engine and domain packages MIT
  The bundled fonts                  SIL OFL 1.1

Corresponding Source for every binary here is the tagged commit at
https://github.com/JonasGrunau/open_audio_analyzer, which also carries the
full text of each licence above.

The GNU General Public License, version 3, follows.

---------------------------------------------------------------------------

NOTICE
  cat LICENSE
} >"$work/resources/LICENSE.txt"

# --- Component packages ----------------------------------------------------

component() {
  name=$1; bundle=$2; identifier=$3; location=$4; scripts=${5:-}

  stage="$work/stage-$name"
  mkdir -p "$stage"
  # ditto rather than cp -R: it is the copy that preserves everything a
  # signed bundle is made of, and the one Apple documents for the job.
  ditto "$bundle" "$stage/$(basename "$bundle")"

  plist="$work/$name-component.plist"
  pkgbuild --analyze --root "$stage" "$plist" >/dev/null

  i=0
  while /usr/libexec/PlistBuddy -c "Print :$i:BundleIsRelocatable" "$plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$plist" >/dev/null
    i=$((i + 1))
  done
  if [ "$i" -gt 0 ]; then
    echo "==> $name: relocation off for $i bundle(s)"
  else
    echo "==> $name: nothing pkgbuild would relocate"
  fi

  if [ -n "$scripts" ]; then
    pkgbuild --root "$stage" --component-plist "$plist" \
      --identifier "$identifier" --version "$version" \
      --install-location "$location" --scripts "$scripts" \
      "$work/$name.pkg" >/dev/null
  else
    pkgbuild --root "$stage" --component-plist "$plist" \
      --identifier "$identifier" --version "$version" \
      --install-location "$location" \
      "$work/$name.pkg" >/dev/null
  fi
}

component app  "$app"  com.openaudioanalyzer.oaa.app  /Applications
component vst3 "$vst3" com.openaudioanalyzer.oaa.vst3 "/Library/Audio/Plug-Ins/VST3"
component au   "$au"   com.openaudioanalyzer.oaa.au   "/Library/Audio/Plug-Ins/Components" \
  "$root/packaging/macos/pkg/scripts"

# --- The distribution ------------------------------------------------------

if [ -n "${OAA_INSTALLER_IDENTITY:-}" ]; then
  echo "==> productbuild, signed as $OAA_INSTALLER_IDENTITY"
  productbuild \
    --distribution packaging/macos/pkg/distribution.xml \
    --package-path "$work" \
    --resources "$work/resources" \
    --sign "$OAA_INSTALLER_IDENTITY" \
    --timestamp \
    "$pkg" >/dev/null
else
  echo "==> no OAA_INSTALLER_IDENTITY: productbuild, unsigned"
  productbuild \
    --distribution packaging/macos/pkg/distribution.xml \
    --package-path "$work" \
    --resources "$work/resources" \
    "$pkg" >/dev/null
fi

rm -rf "$work"

# --- Verify, on the spot ---------------------------------------------------
#
# The gate, and the reason it is here rather than in a test: a test runs after
# a build that has already succeeded at producing the broken artefact. An
# unsigned pkg is refused by the notary service with a message about the
# submission rather than about the signature, twenty minutes later.

if [ -n "${OAA_INSTALLER_IDENTITY:-}" ]; then
  echo "==> pkgutil --check-signature"
  if ! pkgutil --check-signature "$pkg" | sed 's/^/    /'; then
    echo "make_pkg: the package did not verify against its own signature." >&2
    exit 1
  fi
fi

# --- Notarise --------------------------------------------------------------
#
# notarize.sh rather than a notarytool call of its own: it already knows that
# `--wait` can exit 0 having been told no, and the plugin bundles go through
# the same one. Stapling matters as much here as it does there — without the
# ticket in the file, Gatekeeper asks Apple at first open, and somebody
# installing on a machine with no network is refused a package that was
# notarised weeks ago.

sh "$root/packaging/macos/notarize.sh" "$pkg"

if [ -z "${OAA_INSTALLER_IDENTITY:-}" ]; then
  echo "==> unsigned. macOS will refuse this package on any machine that"
  echo "    downloaded it, and it cannot be notarised. Layout checks only."
fi

echo "$pkg"
