#!/bin/sh
# packaging/macos/notarize.sh — notarise and staple, for anything Apple takes.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# Why this exists, and why it is one script rather than three
#
# Signing and notarising are different acts with different failure modes, and
# until this file existed only the macOS download attempted the second one —
# the dmg then, the pkg now. The plugin bundles did neither, so every macOS
# release up to 0.5.0 shipped a VST3 and an AU that Gatekeeper refuses on any
# machine but the one that built them — and the refusal is not the silent one
# the documentation described. It is a modal with no override, because a plugin
# is loaded *into* a host process and the "Open Anyway" button in Privacy &
# Security is only ever populated for a blocked *launch*. A user cannot get
# past it. They can only delete the plugin.
#
# One implementation, because two would drift, and this is a path that only
# runs on a release — the least-exercised code in the repository is the worst
# place to keep a duplicate.
#
# ---------------------------------------------------------------------------
# What gets submitted, and what gets stapled
#
# `notarytool` takes a .dmg, a .pkg or a .zip and nothing else, so a bundle has
# to travel inside a zip. `ditto -c -k --keepParent` is the only zip on macOS
# that round-trips a bundle's symlinks, permissions and extended attributes;
# `zip -r` loses enough of them to invalidate a signature Apple then rejects.
#
# The *ticket* staples to the bundle, not to the zip — so the zip is a
# temporary file this script deletes, and never an artefact. One submission per
# path, which costs a second wait for the AU rather than sharing the VST3's.
# That is a few minutes on a release-gated job, in exchange for a per-bundle
# log when Apple says no.
#
# **Stapling writes into a bundle that is already signed** — the ticket lands at
# `Contents/CodeResources`, beside the `Contents/_CodeSignature/` directory
# rather than inside it, and codesign's default resource rules exclude it, so
# the seal still verifies. That is Apple's design and not a coincidence. This
# script re-runs `codesign --verify --strict` afterwards anyway, because
# `plugin/CMakeLists.txt` shipped four releases of bundles whose seal did not
# cover their own contents, and the lesson written at length there is that the
# only signature you can trust is one something just asked about.
#
# ---------------------------------------------------------------------------
# Credentials, and the reason there are two ways to give them
#
#   OAA_NOTARY_PROFILE     an `xcrun notarytool store-credentials` profile.
#                          A developer's machine. It lives in that machine's
#                          keychain and cannot be handed to a runner, which is
#                          why it was the only supported form for three
#                          releases and why no macOS download was ever notarised
#                          by CI: the secret was read, the profile did not exist,
#                          and the step fell through to the ad-hoc branch.
#
#   OAA_NOTARY_APPLE_ID    the Apple ID that owns the Developer Program
#   OAA_NOTARY_TEAM_ID     the ten-character team id
#   OAA_NOTARY_PASSWORD    an app-specific password, *not* the Apple ID's own
#                          — appleid.apple.com -> Sign-In and Security ->
#                          App-Specific Passwords. This trio is what a runner
#                          can be given, and what `ci.yml` passes.
#
# Neither set present is not an error. A contributor builds a plugin and a pkg
# without an Apple account at all, and this script says what that costs them
# rather than failing their build.

set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: notarize.sh <path> [path...]" >&2
  echo "  A .dmg or .pkg is submitted as itself; anything else is a bundle" >&2
  echo "  and travels in a zip." >&2
  exit 2
fi

if [ "$(uname -s)" != Darwin ]; then
  echo "==> notarize: not macOS, nothing to notarise."
  exit 0
fi

credentials=none
if [ -n "${OAA_NOTARY_PROFILE:-}" ]; then
  credentials=profile
elif [ -n "${OAA_NOTARY_APPLE_ID:-}" ] &&
     [ -n "${OAA_NOTARY_TEAM_ID:-}" ] &&
     [ -n "${OAA_NOTARY_PASSWORD:-}" ]; then
  credentials=explicit
fi

if [ "$credentials" = none ]; then
  echo "==> notarize: no credentials, nothing submitted."
  echo "    These paths are signed at best, and Gatekeeper refuses a signed-"
  echo "    but-unnotarised download on every machine but this one:"
  for path in "$@"; do
    echo "      $path"
  done
  echo "    Set OAA_NOTARY_PROFILE (a local machine) or OAA_NOTARY_APPLE_ID,"
  echo "    OAA_NOTARY_TEAM_ID and OAA_NOTARY_PASSWORD (a runner)."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

submit() {
  if [ "$credentials" = profile ]; then
    xcrun notarytool submit "$1" \
      --keychain-profile "$OAA_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" \
      --apple-id "$OAA_NOTARY_APPLE_ID" \
      --team-id "$OAA_NOTARY_TEAM_ID" \
      --password "$OAA_NOTARY_PASSWORD" --wait
  fi
}

# `--wait` waits for a verdict. It does not reliably *exit non-zero* on a bad
# one — an Invalid submission has come back as a successful command with the
# rejection in its output, which is how an unnotarised build gets stapled with
# nothing and shipped. "Accepted" is the only status worth continuing from, so
# the status line is the gate rather than the exit code.
submit_and_check() {
  log="$tmp/notarytool.log"
  if ! submit "$1" >"$log" 2>&1; then
    cat "$log" >&2
    echo "notarize: notarytool failed for $1." >&2
    # A 401 is the overwhelmingly common first failure and it is not about the
    # bundle at all, so it gets its own answer rather than leaving somebody
    # inspecting a signature that is fine.
    if grep -q "401" "$log"; then
      echo >&2
      echo "  That is an authentication failure, not a problem with the" >&2
      echo "  bundle. In order of how often it is the cause:" >&2
      echo >&2
      echo "  1. The password must be an app-specific password, which looks" >&2
      echo "     exactly like abcd-efgh-ijkl-mnop. An Apple ID's own password" >&2
      echo "     is refused with this same 401." >&2
      echo "  2. The Apple ID and the team must belong together. An Apple ID" >&2
      echo "     that is not a member of --team-id fails here, and an account" >&2
      echo "     in more than one team makes the wrong pairing easy." >&2
      echo "  3. A trailing newline or space survives a paste." >&2
      echo >&2
      echo "  The quickest way to settle all three is to let notarytool" >&2
      echo "  validate them, which it does at store time and which prompts for" >&2
      echo "  the password so nothing can mangle it:" >&2
      echo >&2
      echo "    xcrun notarytool store-credentials oaa-notary \\" >&2
      echo "      --apple-id <apple id> --team-id <team id>" >&2
      echo "    OAA_NOTARY_PROFILE=oaa-notary sh $0 <path>" >&2
    fi
    exit 1
  fi
  cat "$log"
  if ! grep -q 'status: Accepted' "$log"; then
    id=$(sed -n 's/^ *id: *//p' "$log" | head -1)
    echo "notarize: Apple did not accept $1." >&2
    if [ -n "$id" ]; then
      echo "  xcrun notarytool log $id   — for the reason, which is almost" >&2
      echo "  always a missing hardened runtime or a missing secure timestamp." >&2
    fi
    exit 1
  fi
}

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "notarize: $path does not exist." >&2
    exit 1
  fi

  name=$(basename "$path")

  case "$path" in
    *.dmg | *.pkg)
      echo "==> notarytool submit $name (this waits for Apple)"
      submit_and_check "$path"
      xcrun stapler staple "$path"
      xcrun stapler validate "$path"
      ;;
    *)
      zip="$tmp/$name.zip"
      ditto -c -k --keepParent "$path" "$zip"
      echo "==> notarytool submit $name (this waits for Apple)"
      submit_and_check "$zip"
      rm -f "$zip"
      xcrun stapler staple "$path"
      xcrun stapler validate "$path"
      codesign --verify --strict "$path"
      ;;
  esac

  echo "==> $name: notarised and stapled"
done
