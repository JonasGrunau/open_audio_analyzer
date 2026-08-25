#!/bin/sh
#
# make_aab.sh — build Open Audio Analyzer for Android and sign it for the Play
# Store.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/android/make_aab.sh
# Output: build/packaging/Open Audio Analyzer-<version>-android.aab
#
# ---------------------------------------------------------------------------
# This is the second artefact nobody can install from the releases page
#
# `packaging/ios/make_ipa.sh` is the first, and the reason is the same shape:
# an .aab is not an installable file. It is a publishing format — a container
# of every split Play might generate — and turning one into something a phone
# will accept needs `bundletool` *and* the app signing key, which after Play
# App Signing is Google's and not ours. Nobody who downloaded it could install
# it, so `ci.yml` keeps it off the release's asset list exactly as it keeps the
# IPA off. Attaching it would publish an installer that installs nothing.
#
# ---------------------------------------------------------------------------
# Where this differs from the IPA, and why
#
# `make_ipa.sh` produces *nothing* without its credentials, on the grounds that
# an App Store export with no distribution signature is not an unsigned IPA but
# a failed export. That reasoning does not carry over. An Android release build
# with no upload key succeeds and writes a real bundle — Gradle falls back to
# the debug key, which is what keeps `flutter run --release` working for
# somebody who has never seen the credential (see `android/app/build.gradle.kts`).
#
# So this builds either way, and refuses to hand over what it built. The build
# is worth having on its own: Android is otherwise compiled nowhere in CI, and
# `workflow_dispatch` is the only thing standing between a packaging path and
# six weeks of quiet rot. What must never happen is the bundle being uploaded,
# and that is what the check after the build is for — **nothing in an .aab says
# which key signed it**, so a debug-signed one looks exactly like a release
# until Play rejects it by fingerprint at the end of an upload.
#
# ---------------------------------------------------------------------------
# The version code is the workflow's, not the pubspec's
#
# The same trap as `CFBundleVersion`, and Play states it more plainly: a
# versionCode that has already been uploaded is refused, forever, on any track.
# `pubspec.yaml`'s `+N` is maintained by hand, so re-running a tag — or cutting
# two builds of one version — collides there and nowhere else.
# `OAA_BUILD_NUMBER` is set from the run counter in `ci.yml`, which only ever
# increases and which the iPad build already uses. Unset, the pubspec's own
# number is used, which is what you want running this by hand.
#
# Note that a version code cannot be *lowered* either: whatever number Play
# accepts first becomes the floor for every later upload. That is an argument
# for the run counter and against anything derived from the version string.
#
# ---------------------------------------------------------------------------
# Credentials
#
#   OAA_ANDROID_KEYSTORE           base64 of the **upload key** — a PKCS#12
#                                  or JKS keystore holding one key pair. Not
#                                  the app signing key: with Play App Signing,
#                                  which is mandatory for every app created
#                                  since 2021, Google holds that one and
#                                  re-signs what you upload. Losing this file
#                                  is recoverable by asking Play to reset the
#                                  upload key; losing the app signing key is
#                                  not, which is most of the reason the split
#                                  exists.
#   OAA_ANDROID_KEYSTORE_PASSWORD  the keystore's password.
#   OAA_ANDROID_KEY_ALIAS          the alias of the key pair inside it.
#   OAA_ANDROID_KEY_PASSWORD       optional; defaults to the keystore
#                                  password, which is what `keytool` gives you
#                                  when you press return at the second prompt.
#   OAA_BUILD_NUMBER               optional; see above.
#
# The keystore is written under $RUNNER_TEMP and pointed at through
# OAA_ANDROID_KEY_PROPERTIES, so neither it nor the two passwords ever land in
# the checkout — where the `*.jks` line in .gitignore is the only thing that
# has ever stood between a signing credential and a commit.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

version=$(grep '^version:' pubspec.yaml | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
out="$root/build/packaging"
aab="$out/Open Audio Analyzer-$version-android.aab"

# --- The upload key --------------------------------------------------------

signed=false

if [ -n "${OAA_ANDROID_KEYSTORE:-}" ]; then
  for var in OAA_ANDROID_KEYSTORE_PASSWORD OAA_ANDROID_KEY_ALIAS; do
    eval "value=\${$var:-}"
    if [ -z "$value" ]; then
      echo "make_aab: OAA_ANDROID_KEYSTORE is set and $var is not. The" >&2
      echo "  keystore, its password and the alias are one credential; a" >&2
      echo "  keystore on its own opens nothing." >&2
      exit 1
    fi
  done

  keydir="${RUNNER_TEMP:-$(mktemp -d "${TMPDIR:-/tmp}/oaa-android.XXXXXX")}/oaa-upload-key"
  mkdir -p "$keydir"
  chmod 700 "$keydir"
  trap 'rm -rf "$keydir"' EXIT INT TERM

  # `|| true` for the same reason as in make_ipa.sh: under `set -e` a failed
  # decode exits on base64's own one-line complaint and the message below —
  # the one that says what the variable should contain — never prints.
  printf '%s' "$OAA_ANDROID_KEYSTORE" | base64 --decode >"$keydir/upload.jks" 2>/dev/null || true
  if [ ! -s "$keydir/upload.jks" ]; then
    echo "make_aab: OAA_ANDROID_KEYSTORE did not decode to anything. It must" >&2
    echo "  be base64 of the keystore file itself:" >&2
    echo "    base64 -i upload-keystore.jks | pbcopy" >&2
    exit 1
  fi

  cat >"$keydir/key.properties" <<EOF
storeFile=$keydir/upload.jks
storePassword=$OAA_ANDROID_KEYSTORE_PASSWORD
keyAlias=$OAA_ANDROID_KEY_ALIAS
keyPassword=${OAA_ANDROID_KEY_PASSWORD:-$OAA_ANDROID_KEYSTORE_PASSWORD}
EOF
  chmod 600 "$keydir/key.properties"
  export OAA_ANDROID_KEY_PROPERTIES="$keydir/key.properties"

  # Read the alias back before spending ten minutes on a build that Gradle
  # would fail at the very end. `keytool -list` with the wrong password or a
  # missing alias is the whole check, and it costs a second.
  if ! keytool -list -keystore "$keydir/upload.jks" \
    -storepass "$OAA_ANDROID_KEYSTORE_PASSWORD" \
    -alias "$OAA_ANDROID_KEY_ALIAS" >/dev/null 2>&1
  then
    echo "make_aab: the keystore does not open with that password, or it" >&2
    echo "  holds no key called '$OAA_ANDROID_KEY_ALIAS'. List what is in it" >&2
    echo "  with:" >&2
    echo "    keytool -list -v -keystore upload-keystore.jks" >&2
    exit 1
  fi

  signed=true
  echo "==> signing with the upload key, alias $OAA_ANDROID_KEY_ALIAS"
else
  echo "==> aab: no OAA_ANDROID_KEYSTORE. Building anyway — Gradle falls back"
  echo "    to the debug key — and the bundle will be discarded rather than"
  echo "    offered, because Play refuses the debug key by fingerprint."
fi

# --- Build -----------------------------------------------------------------

set -- --release
if [ -n "${OAA_BUILD_NUMBER:-}" ]; then
  echo "==> version code $OAA_BUILD_NUMBER (pubspec's is used when unset)"
  set -- "$@" --build-number="$OAA_BUILD_NUMBER"
fi

flutter pub get
flutter build appbundle "$@"

built=build/app/outputs/bundle/release/app-release.aab
if [ ! -f "$built" ]; then
  echo "make_aab: the build reported success and left no bundle at $built." >&2
  exit 1
fi

# --- Check what actually signed it -----------------------------------------
#
# The whole point, and the one thing the file itself will not tell you. An
# .aab is a zip whose META-INF/*.RSA holds the signer's certificate chain, and
# `keytool -printcert -jarfile` reads it without unpacking anything.
#
# Two things about reading that output, both of which produce a check that
# passes on a runner and fails on somebody's laptop or the reverse:
#
#   - **keytool is localised.** It prints `Owner:` under an English locale and
#     `Eigentümer:` under a German one, so a grep for the label is a check that
#     works in one country. `-J-Duser.language=en` pins it, and the match below
#     is on the certificate's *subject* rather than on the label anyway —
#     `CN=Android Debug` is a value, and values are not translated.
#   - **The debug key is per-machine**, generated by the SDK the first time it
#     is needed, so its fingerprint is different on every developer's machine
#     and on every runner. Its distinguished name is not: the SDK always writes
#     `C=US, O=Android, CN=Android Debug`. That is what makes the subject the
#     only stable thing here to match on.

cert=$(keytool -J-Duser.language=en -J-Duser.country=US \
  -printcert -jarfile "$built" 2>/dev/null || true)
owner=$(printf '%s\n' "$cert" | grep -m1 '^Owner:' | sed 's/^Owner: *//')
echo "==> signed by: ${owner:-<nothing — the bundle carries no signature>}"

case "$owner" in
  *"CN=Android Debug"* | "")
    if [ "$signed" = true ]; then
      echo "make_aab: an upload key was configured and the bundle came out" >&2
      echo "  signed by the debug key anyway. Gradle silently ignored the" >&2
      echo "  release signingConfig — check that OAA_ANDROID_KEY_PROPERTIES" >&2
      echo "  reached it and that android/app/build.gradle.kts still reads it." >&2
      exit 1
    fi
    echo "==> aab: debug-signed, so nothing is offered. Play rejects this key"
    echo "    by fingerprint, and no check downstream of here could tell it"
    echo "    apart from a release build. See the header of this file for the"
    echo "    four secrets a Play Store upload needs."
    exit 0
    ;;
esac

mkdir -p "$out"
mv "$built" "$aab"
echo "$aab"
