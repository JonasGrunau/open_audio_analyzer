#!/bin/sh
# packaging/macos/keychain.sh — put a Developer ID where codesign can find it.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# The step that was missing, and what its absence looked like
#
# `ci.yml` has read an `OAA_SIGNING_IDENTITY` secret since 0.3.0 and handed it
# to `codesign --sign`. A GitHub runner is a fresh machine with an empty
# keychain, so there was never a certificate for that name to match — the
# identity was a string with nothing behind it. Nothing in the workflow
# imported one, and nothing said so, because the secret was never set either:
# `make_dmg.sh` took its "no identity" branch, ad-hoc signed, and the release
# succeeded. Two halves of the same gap, each hiding the other.
#
# So: this runs before anything signs, and after it the identity named by
# OAA_SIGNING_IDENTITY exists.
#
#   OAA_SIGNING_CERTIFICATE           base64 of a .p12 holding the Developer ID
#                                     Application certificate *and its private
#                                     key*. An exported certificate on its own
#                                     imports cleanly and signs nothing.
#   OAA_SIGNING_CERTIFICATE_PASSWORD  the password used for that export.
#
# ---------------------------------------------------------------------------
# Three lines here are load-bearing and none of them is the import
#
# **`set-key-partition-list`.** Without it codesign finds the key, asks the
# window server for permission to use it, and blocks on a dialog no headless
# runner can draw. The job then hangs until the six-hour timeout, having
# printed nothing. It is the single most common way this file's job fails when
# somebody writes it from memory.
#
# **`set-keychain-settings -lut` with no `-l`.** Default settings relock the
# keychain on a timeout, and a build that signs four bundles over twenty
# minutes fails on a later one having succeeded on the first — which reads as
# "the fourth bundle is special" and is nothing of the kind.
#
# **`list-keychains -s` takes the whole list, not the addition.** It *replaces*
# the search list. Passing this keychain alone removes the login keychain from
# it for the rest of the session, and on a developer's machine that is a
# surprising amount of collateral damage from a build script, which is what the
# CI guard below is for.

set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "==> keychain: not macOS, nothing to import."
  exit 0
fi

if [ -z "${OAA_SIGNING_CERTIFICATE:-}" ]; then
  echo "==> keychain: no OAA_SIGNING_CERTIFICATE, nothing imported."
  echo "    Whatever signs after this will be ad-hoc, which is fine for a"
  echo "    build you run yourself and not for one anybody downloads."
  exit 0
fi

if [ -z "${OAA_SIGNING_CERTIFICATE_PASSWORD:-}" ]; then
  echo "keychain: OAA_SIGNING_CERTIFICATE is set and" >&2
  echo "  OAA_SIGNING_CERTIFICATE_PASSWORD is not. A .p12 export always has a" >&2
  echo "  password; an empty one is a secret that was not set rather than a" >&2
  echo "  certificate that needs none." >&2
  exit 1
fi

if [ -z "${CI:-}" ] && [ -z "${OAA_KEYCHAIN_FORCE:-}" ]; then
  echo "keychain: this replaces your login keychain search list and stores a" >&2
  echo "  certificate in a keychain of its own. It is written for a runner." >&2
  echo "  On your own machine, import the .p12 in Keychain Access instead —" >&2
  echo "  codesign then finds it with no help. OAA_KEYCHAIN_FORCE=1 to run" >&2
  echo "  this anyway." >&2
  exit 1
fi

keychain="$HOME/Library/Keychains/oaa-signing.keychain-db"

# The keychain's own password protects a keychain that exists for one job on a
# machine that is destroyed after it. It is generated rather than taken from a
# secret so that it is not one more thing to rotate.
password=$(uuidgen)

p12=$(mktemp "${TMPDIR:-/tmp}/oaa-signing.XXXXXX")
trap 'rm -f "$p12"' EXIT INT TERM

printf '%s' "$OAA_SIGNING_CERTIFICATE" | base64 --decode >"$p12"
if [ ! -s "$p12" ]; then
  echo "keychain: OAA_SIGNING_CERTIFICATE did not decode to anything." >&2
  echo "  It must be base64 of the .p12 file itself:" >&2
  echo "    base64 -i certificate.p12 | pbcopy" >&2
  exit 1
fi

security delete-keychain "$keychain" 2>/dev/null || true
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"

security import "$p12" -k "$keychain" \
  -P "$OAA_SIGNING_CERTIFICATE_PASSWORD" \
  -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

# Prepended to the existing list, never substituted for it. The quoting the
# `security` output needs stripping is the reason for the sed.
security list-keychains -d user -s "$keychain" \
  $(security list-keychains -d user | sed 's/^[[:space:]]*//; s/"//g')

echo "==> keychain: imported into $keychain"
security find-identity -v -p codesigning "$keychain" | sed 's/^/    /'
