#!/bin/sh
#
# play_store.sh — upload an already-built app bundle to Google Play.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  sh packaging/android/play_store.sh [path/to/app.aab]
#         With no argument it takes the one .aab in build/packaging/.
#
# ---------------------------------------------------------------------------
# Why this is a separate script from make_aab.sh
#
# The same reason `packaging/ios/testflight.sh` is separate from `make_ipa.sh`,
# and it is the same ordering: the upload happens **after** the GitHub release
# is published, so that a release either exists with a Play build behind it or
# does not exist at all. A build sitting on a Play track for a version that was
# never released is a state nothing else here can produce and nobody can clean
# up — a version code, once accepted, can never be reused or lowered.
#
# So: `make_aab.sh` runs beside the other packaging jobs and hands its bundle
# over as a workflow artefact; `publish` creates the release; this runs last, on
# the artefact.
#
# ---------------------------------------------------------------------------
# Two things the API cannot do, and one of them will bite you first
#
# **It cannot create the app.** There is no endpoint for it. The package name
# `com.openaudioanalyzer.oaa` has to exist in the Play Console, created by a
# person, before anything here works — and until the Console's own checklist is
# done (store listing, content rating, data safety, target audience) Play will
# accept an upload and refuse to make it live. The first release is a manual
# act; every one after it is this script.
#
# **It cannot un-publish a version code.** See above.
#
# ---------------------------------------------------------------------------
# Credentials: a service account, which is not a Google account
#
# The same distinction `testflight.sh` documents for App Store Connect. A
# person's Google account has a password, a second factor and consent screens,
# so it fails on a runner in a way that reads as a credential problem. A service
# account is issued to the project, authenticates with a signed assertion and
# has no interactive anything.
#
#   OAA_PLAY_SERVICE_ACCOUNT  the service account's JSON key. base64 of the
#                             file, or the JSON itself — this takes either,
#                             because it is the one credential here that is
#                             already text and somebody will paste it as text.
#   OAA_PLAY_TRACK            optional; `internal` by default. Promoting a
#                             build between tracks is a Console action and
#                             deliberately not one this script does.
#   OAA_PLAY_STATUS           optional; `completed` by default. `draft` uploads
#                             the build and leaves releasing it to a person,
#                             which is what you want the first time production
#                             is named above.
#
# The service account needs the **Release manager** role, or at minimum
# "Releases: create and publish" on this app, granted in the Play Console under
# Users and permissions. Granting it in Google Cloud IAM is a different thing
# and is not enough on its own: the account has to be invited to the Play
# developer account as well, and the upload is otherwise refused with a
# permissions error that names no role.
#
# ---------------------------------------------------------------------------
# Dependencies: curl, openssl, python3
#
# All three are on every GitHub runner and on every machine that can already
# build this. python3 does the JSON, rather than jq, for two reasons: it is the
# one of the two that is reliably present, and the field that must be read
# correctly — the service account's private key, whose newlines arrive as `\n`
# escapes inside a JSON string — is exactly the field a sed expression gets
# wrong, silently, producing a PEM that openssl rejects for no stated reason.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

package=com.openaudioanalyzer.oaa
track=${OAA_PLAY_TRACK:-internal}
status=${OAA_PLAY_STATUS:-completed}
api=https://androidpublisher.googleapis.com/androidpublisher/v3
upload_api=https://androidpublisher.googleapis.com/upload/androidpublisher/v3

if [ "$#" -gt 0 ]; then
  aab=$1
else
  aab=$(ls "$root"/build/packaging/*.aab 2>/dev/null | head -1 || true)
fi

if [ -z "$aab" ] || [ ! -f "$aab" ]; then
  echo "==> play: no app bundle, nothing to upload."
  echo "    make_aab.sh offers none when it has no upload key, so this is what"
  echo "    a fork and a run with no secrets look like."
  exit 0
fi

if [ -z "${OAA_PLAY_SERVICE_ACCOUNT:-}" ]; then
  echo "==> play: no OAA_PLAY_SERVICE_ACCOUNT, $aab not uploaded."
  echo "    The bundle is built and signed; nothing was sent to Google."
  exit 0
fi

for tool in curl openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "play_store: $tool is not on PATH, and all three of curl, openssl" >&2
    echo "  and python3 are needed. See the header of this file." >&2
    exit 1
  }
done

work="${RUNNER_TEMP:-$(mktemp -d "${TMPDIR:-/tmp}/oaa-play.XXXXXX")}/oaa-play"
mkdir -p "$work"
chmod 700 "$work"
body="$work/body.json"

# --- Helpers ---------------------------------------------------------------

# Read one dotted path out of the JSON on stdin. Strings come back raw so they
# can be used as shell values; anything else comes back as JSON.
json_get() {
  python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
sys.stdout.write(value if isinstance(value, str) else json.dumps(value))
' "$1"
}

# base64url, no padding: what a JWT is made of.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

fail() {
  echo "" >&2
  echo "play_store: $1" >&2
  if [ -s "$body" ]; then
    echo "  Google said:" >&2
    sed 's/^/    /' "$body" >&2
  fi
  exit 1
}

# Every call writes its body to one file and returns the status code, so a
# failure can print what Google actually said. Piping curl through anything
# would report on the last command in the pipeline instead — the mistake
# testflight.sh documents next door.
http() { curl -sS -o "$body" -w '%{http_code}' "$@"; }

# An edit that is created and not committed holds no lock and expires on its
# own, but leaving one behind makes the next failure harder to read. Deleted on
# any exit once there is an id to delete.
edit=""
cleanup() {
  if [ -n "$edit" ] && [ -n "${token:-}" ]; then
    curl -sS -o /dev/null -X DELETE \
      -H "Authorization: Bearer $token" \
      "$api/applications/$package/edits/$edit" || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# --- The service account key -----------------------------------------------

# base64 first, then the raw value. A JSON key is text, so both forms turn up
# in practice and neither is a mistake worth an error message.
printf '%s' "$OAA_PLAY_SERVICE_ACCOUNT" | base64 --decode >"$work/sa.json" 2>/dev/null || true
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$work/sa.json" 2>/dev/null; then
  printf '%s' "$OAA_PLAY_SERVICE_ACCOUNT" >"$work/sa.json"
fi
chmod 600 "$work/sa.json"

if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$work/sa.json" 2>/dev/null; then
  echo "play_store: OAA_PLAY_SERVICE_ACCOUNT is neither JSON nor base64 of" >&2
  echo "  JSON. It must be the key file Google Cloud gave you when you added" >&2
  echo "  a key to the service account — the whole file, starting {\"type\":" >&2
  echo "  \"service_account\"." >&2
  exit 1
fi

client_email=$(json_get client_email <"$work/sa.json")
json_get private_key <"$work/sa.json" >"$work/key.pem"
chmod 600 "$work/key.pem"

if [ ! -s "$work/key.pem" ]; then
  echo "play_store: the key file has no private_key. A key downloaded as P12" >&2
  echo "  rather than JSON looks like this. Add a new JSON key to the service" >&2
  echo "  account and use that file." >&2
  exit 1
fi

echo "==> service account: $client_email"

# --- An access token --------------------------------------------------------

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
claims=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"https://oauth2.googleapis.com/token","iat":%s,"exp":%s}' \
  "$client_email" "$now" "$((now + 3600))" | b64url)
signature=$(printf '%s.%s' "$header" "$claims" |
  openssl dgst -sha256 -sign "$work/key.pem" -binary | b64url)

code=$(http -X POST https://oauth2.googleapis.com/token \
  --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
  --data-urlencode "assertion=$header.$claims.$signature")
[ "$code" = 200 ] || fail "the service account could not get a token (HTTP $code).
  An 'invalid_grant' here is usually the clock or a key that has been revoked;
  'unauthorized_client' means the Android Publisher API is not enabled on the
  Cloud project the account belongs to."
token=$(json_get access_token <"$body")

# --- An edit ---------------------------------------------------------------

code=$(http -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' \
  "$api/applications/$package/edits")
case "$code" in
  200) : ;;
  401 | 403) fail "the service account may not edit $package (HTTP $code).
  Invite it in the Play Console under Users and permissions and give it the
  Release manager role. A Cloud IAM role is a different thing and is not
  enough on its own." ;;
  404) fail "Play has no app called $package (HTTP 404).
  The API cannot create one. Create it in the Play Console first — the first
  release of any app is a manual act." ;;
  *) fail "could not open an edit (HTTP $code)." ;;
esac
edit=$(json_get id <"$body")
echo "==> edit $edit"

# --- The bundle ------------------------------------------------------------

echo "==> uploading $(basename "$aab") ($(($(wc -c <"$aab") / 1024 / 1024)) MB)"

code=$(http -X POST -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary "@$aab" \
  "$upload_api/applications/$package/edits/$edit/bundles?uploadType=media")
[ "$code" = 200 ] || fail "Play refused the bundle (HTTP $code).
  The two that arrive here rather than earlier are a version code it has
  already accepted — which is what a re-run of a tag looks like, and is not a
  defect in anything — and a bundle signed with a key whose fingerprint is not
  the registered upload key."
version_code=$(json_get versionCode <"$body")
echo "==> accepted as version code $version_code"

# --- The release notes ------------------------------------------------------
#
# This tag's own changelog section, the same one `publish` puts on the release,
# rewritten to fit Play's **500-character** "What's new" field. Play rejects a
# longer one outright, so the fitting is not cosmetic — but notes are a poor
# reason to fail an upload Play has already accepted, so every failure here is
# a warning and the notes are simply left off.
#
# Three rules do the fitting. All three are readings of *this* CHANGELOG.md
# rather than general ones, and between them they mean nobody writes a store
# note: the changelog is the store note, and editing it edits the store.
#
# **A bold lead is the note.** This repository's entries put the point in bold
# at the start and the reasoning after it, so a bold lead is at once the
# shortest form of an entry and the author's own summary of it — "**The
# smallest supported window is now 960x808**, up from 960x768 (macOS; the only
# platform that enforces one)" gives up 84 characters of parenthesis for
# nothing. An entry with no bold lead falls back to its first sentence, which
# CHANGELOG.md's rules make a fair summary of one: an entry "describes the
# effect on the user, not the diff". Nothing else works here — every bullet in
# 0.11.0 runs to 650–800 characters whole, so a keep-whole-entries rule keeps
# nothing at all and a cut-at-500 rule ships half a sentence.
#
# **Bold entries first, then round-robin across the sections.** Straight
# changelog order is what sent 0.13.0 to the store as four Added bullets, with
# the mono Phase Scope, the microphone Android had never been asked for and
# every other fix behind the cut: one long section spends the budget before the
# next is reached, and what a tester wants to read first is usually what was
# *fixed*. So a sweep takes the bold entries a section at a time, a second
# sweep takes the rest, and an entry too long for what is left is stepped over
# rather than ending the pass — one 140-character bullet costs its own place
# and nobody else's.
#
# **The link is only paid for when something was left behind.** It costs 55 of
# the 500, which is a whole entry, so a release whose changelog fits entirely
# says so by linking nowhere.
#
# **en-US, and no other language, ever.** `releaseNotes` is an array with one
# entry per listing language, so the shape invites a second one — and the text
# for it would have to come from somewhere. CHANGELOG.md is written in English;
# anything else here is a machine translation nobody in this repository can
# review, shipped to a store where it is the first thing a tester reads. A
# language Play is not given falls back to the listing's default, which is this
# one, so leaving it out costs nothing. Add a language here only when a person
# is writing that language's changelog.
#
# The generator is written out and then run, rather than piped from a heredoc
# inside `$(...)`. That is not a style preference: a backtick anywhere inside a
# here-document nested in a command substitution kills the *parser*, quoted
# delimiter or not — `sh -n` reports "unexpected EOF while looking for matching
# `" and the script never runs at all, on a line that is a Python comment. The
# regex below strips markdown code ticks, so it contains one.

version=$(grep '^version:' "$root/pubspec.yaml" | head -1 | cut -d' ' -f2 | cut -d'+' -f1)
more="More: github.com/JonasGrunau/open_audio_analyzer/releases"

cat >"$work/notes.py" <<'PYTHON'
import json, re, sys

path, version, more = sys.argv[1], sys.argv[2], sys.argv[3]
LIMIT = 500

lines, inside = [], False
for line in open(path, encoding="utf-8"):
    if line.startswith("## [" + version + "]"):
        inside = True
        continue
    if inside and line.startswith("## ["):
        break
    if inside:
        lines.append(line.rstrip())

# Sections in changelog order, each a (label, [entry, ...]) pair. Bullets are
# unwrapped first, because CHANGELOG.md is hard-wrapped at 80 columns and Play
# renders this text exactly as it arrives — the breaks would land mid-phrase on
# a phone.
sections, entries, label, current = [], None, None, None


def flush_entry():
    global current
    if current is not None:
        entries.append(current)
        current = None


def flush_section():
    global entries, label
    flush_entry()
    if label is not None and entries:
        sections.append((label, entries))
    entries, label = None, None


for line in lines:
    # A heading keeps its name and loses its emoji, matched as `\S+` rather than
    # at a fixed width: an emoji is one code point here and two somewhere else,
    # and counting them is how "### <emoji> Measurement" reaches a store as raw
    # markdown.
    heading = re.match(r"^#{3,4}\s+(?:\S+\s+)?(.+)$", line)
    if heading:
        flush_section()
        label, entries = heading.group(1).strip(), []
    elif entries is None:
        continue
    elif line.startswith("- "):
        flush_entry()
        current = line[2:]
    elif line.strip() and current is not None:
        current += " " + line.strip()
    elif not line.strip():
        flush_entry()
flush_section()

# The Internal section is refactors, build and CI, and CHANGELOG.md puts it last
# "because most readers stop before it". A store listing is the one place where
# that is not a figure of speech: somebody deciding whether to install an app
# does not want a note about a screenshot script.
sections = [s for s in sections if s[0].lower() != "internal"]


def shorten(entry):
    """One line for the store, out of an entry written for a changelog."""
    entry = re.sub(r"\s*\(#\d+\)", "", entry)                # issue references
    entry = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", entry)    # links to their text

    # The bold lead, where there is one; the first sentence otherwise. The
    # header of play_store.sh says why that is a reading of this changelog.
    lead = re.match(r"\*\*(.+?)\*\*", entry)
    if lead:
        entry = lead.group(1)
    else:
        # Split on a full stop and the space after it, which is what keeps a
        # version number whole: "0.11.0" has a digit after the point rather
        # than a space. Not "a full stop and a capital" — 0.10.1's second
        # sentence opens on `src/lib/app.mjs`, so that rule found no boundary
        # at all and sent 300 characters of build reasoning to a store.
        entry = re.split(r"(?<=[.!?])\s+", entry, maxsplit=1)[0]

    entry = re.sub(r"[*`]", "", entry).strip()               # emphasis, code ticks
    if entry and entry[-1] not in ".!?":
        entry += "."
    return entry, bool(lead)


for index, (label, entries) in enumerate(sections):
    sections[index] = (label, [e for e in map(shorten, entries) if e[0]])
sections = [s for s in sections if s[1]]


def fit(budget):
    """Fill `budget` characters: bold entries first, round-robin by section.

    See the header of play_store.sh for why both of those, and why an entry
    that does not fit is stepped over rather than ending the pass. `kept` holds
    each entry with its position, so a section renders in changelog order
    however the sweeps reached it.
    """
    kept = [[] for _ in sections]
    length = 0
    dropped = False
    for tier in (True, False):
        depth = 0
        while any(depth < len(entries) for _, entries in sections):
            for index, (label, entries) in enumerate(sections):
                if depth >= len(entries):
                    continue
                entry, bold = entries[depth]
                if bold is not tier:
                    continue
                heading = 0 if kept[index] else len(label) + 2   # "Label:\n"
                cost = heading + len(entry) + 3                  # "- " and "\n"
                if length + cost > budget:
                    dropped = True
                    continue
                kept[index].append((depth, entry))
                length += cost
            depth += 1
    return [sorted(taken) for taken in kept], dropped


# Two passes, because the "More:" line is only worth its 55 characters when
# there is in fact more. A release whose whole changelog fits says so by not
# linking anywhere.
kept, dropped = fit(LIMIT)
if dropped:
    kept, _ = fit(LIMIT - len(more) - 2)

rendered = []
for (label, _), taken in zip(sections, kept):
    if taken:
        rendered.append(label + ":")
        rendered += ["- " + entry for _, entry in taken]
text = "\n".join(rendered).strip()

# One entry longer than the whole budget is the only case left, and an ellipsis
# beats no notes at all.
if not text and sections:
    head = sections[0][1][0][0][: LIMIT - len(more) - 2]
    text = head[: head.rfind(" ")].rstrip(" ,;:") + "…"
    dropped = True

if text and dropped:
    text += "\n\n" + more
sys.stdout.write(json.dumps(text) if text else "")
PYTHON

notes=$(python3 "$work/notes.py" "$root/CHANGELOG.md" "$version" "$more" 2>/dev/null || true)

# **en-US, and no other language, ever.** `releaseNotes` is an array with one
# entry per listing language, so the shape invites a second one — and the text
# for it would have to come from somewhere. CHANGELOG.md is written in English;
# anything else here is a machine translation nobody in this repository can
# review, shipped to a store where it is the first thing a tester reads. A
# language Play is not given falls back to the listing's default, which is this
# one, so the cost of leaving it out is nothing. Add a language here only when
# a person is writing that language's changelog.
if [ -z "$notes" ]; then
  echo "==> no release notes: CHANGELOG.md has no section for $version."
  release_notes=""
else
  release_notes=",\"releaseNotes\":[{\"language\":\"en-US\",\"text\":$notes}]"
fi

# --- The track -------------------------------------------------------------

echo "==> assigning to the $track track, status $status"

cat >"$work/track.json" <<EOF
{"track":"$track","releases":[{"name":"$version","versionCodes":["$version_code"],"status":"$status"$release_notes}]}
EOF

code=$(http -X PUT -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  --data-binary "@$work/track.json" \
  "$api/applications/$package/edits/$edit/tracks/$track")
[ "$code" = 200 ] || fail "could not assign version $version_code to $track (HTTP $code).
  A 400 naming 'track' means this app has no such track — the four Play
  defines are internal, alpha, beta and production, and a closed testing track
  is named by the Console rather than by one of those."

# --- Commit ----------------------------------------------------------------

code=$(http -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' \
  "$api/applications/$package/edits/$edit:commit")
[ "$code" = 200 ] || fail "the edit was not committed (HTTP $code).
  Nothing has been published. A 400 here is usually the Console's own
  checklist — store listing, content rating, data safety, target audience —
  which has to be complete before Play will release to any track."

# Committed, so there is no edit left to delete.
edit=""

echo "==> committed. Version $version ($version_code) is on the $track track."
echo "    Play processes the bundle before testers are offered it; that takes"
echo "    minutes to a few hours and is not something this workflow waits on."
