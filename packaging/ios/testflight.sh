#!/bin/sh
#
# testflight.sh — upload an already-built IPA to App Store Connect.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/ios/testflight.sh [path/to/app.ipa]
#         With no argument it takes the one IPA in build/packaging/.
#
# ---------------------------------------------------------------------------
# Why this is a separate script from make_ipa.sh
#
# Because it runs at a different time. `xcodebuild -exportArchive` will export
# and upload in one step, and `ci.yml` deliberately does not use that: the
# upload has to happen **after** the GitHub release is published, so that a
# release either exists with a TestFlight build behind it or does not exist at
# all. An export that uploaded would put the upload before every other
# packaging job had finished, and a failure there would leave a build in
# TestFlight for a version that was never released.
#
# So: `make_ipa.sh` runs beside the other packaging jobs and hands its IPA over
# as a workflow artefact; `publish` creates the release; this runs last, on the
# artefact. It is idempotent in the only sense that matters — an IPA whose build
# number App Store Connect has already seen is refused, loudly, and nothing is
# overwritten.
#
# ---------------------------------------------------------------------------
# Credentials, and the shape a runner can use
#
# An App Store Connect **API key**, not an Apple ID. `notarize.sh` next door
# documents the same distinction for notarytool and it is the same trap: an
# Apple ID with an app-specific password works from a person's Mac and needs
# that person to have accepted whatever agreement Apple last published, so it
# fails on a runner in a way that reads as a credential problem. An API key is
# issued to the team, not to a human.
#
#   OAA_ASC_KEY_ID     the key's ID, the 10 characters in its filename.
#   OAA_ASC_ISSUER_ID  the issuer UUID, shown once at the top of the Keys page
#                      in App Store Connect and the same for every key.
#   OAA_ASC_KEY        base64 of the AuthKey_<id>.p8 itself. App Store Connect
#                      lets it be downloaded exactly once.
#
# The key needs the **App Manager** role, or the upload is refused with a
# permissions error that names no role.
#
# ---------------------------------------------------------------------------
# The .p8 goes in a directory, because altool will not take a path
#
# `altool` finds the private key by convention rather than by argument: it looks
# for `AuthKey_<key id>.p8` in ./private_keys, ~/private_keys, ~/.private_keys,
# ~/.appstoreconnect/private_keys and $API_PRIVATE_KEYS_DIR. This writes the key
# under $RUNNER_TEMP (falling back to a mktemp directory off CI) and points
# API_PRIVATE_KEYS_DIR at it, so the key never lands in the checkout — where the
# `*.p12` line in .gitignore is the only thing that has ever stood between a
# signing credential and a commit — and never in $HOME, where a later job on a
# self-hosted runner would still find it.

set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "==> testflight: not macOS, nothing to upload."
  exit 0
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

if [ "$#" -gt 0 ]; then
  ipa=$1
else
  ipa=$(ls "$root"/build/packaging/*.ipa 2>/dev/null | head -1 || true)
fi

if [ -z "$ipa" ] || [ ! -f "$ipa" ]; then
  echo "==> testflight: no IPA, nothing to upload."
  echo "    make_ipa.sh produces none without its signing credentials, so this"
  echo "    is what a fork and a run with no secrets look like."
  exit 0
fi

if [ -z "${OAA_ASC_KEY:-}" ]; then
  echo "==> testflight: no OAA_ASC_KEY, $ipa not uploaded."
  echo "    The IPA is built and signed; nothing was sent to Apple."
  exit 0
fi

for var in OAA_ASC_KEY_ID OAA_ASC_ISSUER_ID; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "testflight: OAA_ASC_KEY is set and $var is not. All three are one" >&2
    echo "  credential; two of them authenticate nothing." >&2
    exit 1
  fi
done

keys="${RUNNER_TEMP:-$(mktemp -d "${TMPDIR:-/tmp}/oaa-asc.XXXXXX")}/private_keys"
mkdir -p "$keys"
chmod 700 "$keys"
trap 'rm -rf "$keys"' EXIT INT TERM

# `|| true` for the same reason as in make_ipa.sh: under `set -e` a failed
# decode exits on base64's own complaint and the message below never prints.
printf '%s' "$OAA_ASC_KEY" | base64 --decode >"$keys/AuthKey_$OAA_ASC_KEY_ID.p8" 2>/dev/null || true
if [ ! -s "$keys/AuthKey_$OAA_ASC_KEY_ID.p8" ]; then
  echo "testflight: OAA_ASC_KEY did not decode to anything. It must be base64" >&2
  echo "  of the .p8 file itself:" >&2
  echo "    base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy" >&2
  exit 1
fi
export API_PRIVATE_KEYS_DIR="$keys"

echo "==> uploading $(basename "$ipa") to App Store Connect"

# The output is captured as well as printed, because the two failures worth
# telling apart are indistinguishable by exit code: a build number App Store
# Connect has already accepted, and everything else. The first one is the
# expected way a re-run of a tag fails and it is not a defect in anything.
# Redirected and then printed rather than piped through tee: a pipeline's exit
# status is its *last* command's, so `altool | tee` reports on tee and every
# upload failure would read as a success.
log=$(mktemp "${TMPDIR:-/tmp}/oaa-altool.XXXXXX")
status=0
if ! xcrun altool --upload-app -f "$ipa" -t ios \
  --api-key "$OAA_ASC_KEY_ID" \
  --api-issuer "$OAA_ASC_ISSUER_ID" >"$log" 2>&1
then
  status=$?
fi
sed 's/^/    /' "$log"

if [ "$status" -ne 0 ]; then
  if grep -qi 'bundle version must be higher\|already been used\|redundant' "$log"; then
    echo "" >&2
    echo "testflight: App Store Connect has this build number already." >&2
    echo "  Nothing is wrong with the build. OAA_BUILD_NUMBER comes from the" >&2
    echo "  workflow's run counter, so this is a re-run of a run that had" >&2
    echo "  already uploaded — the existing TestFlight build is the one this" >&2
    echo "  would have produced. See the header of make_ipa.sh." >&2
  fi
  rm -f "$log"
  exit "$status"
fi

rm -f "$log"

echo "==> uploaded. App Store Connect processes the build before TestFlight"
echo "    offers it; that takes minutes to an hour and is not something this"
echo "    workflow waits on."
