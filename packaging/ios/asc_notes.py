"""asc_notes.py — put this release's changelog on the build Apple just took.

SPDX-License-Identifier: GPL-3.0-or-later

Usage:  python3 packaging/ios/asc_notes.py <key.p8> <bundle-id> <build-number>
                                           <version> <notes-json>

Run by `testflight.sh` after a successful upload, and by nothing else. Every
failure here is a warning: the build is already in App Store Connect and a note
is a poor reason to fail a release that Apple has accepted. The exit code says
whether anything went wrong, and `testflight.sh` prints rather than exits on it.

---------------------------------------------------------------------------
Two fields, and they are not the same audience

**What to Test** (`betaBuildLocalizations.whatsNew`) is what a TestFlight
tester reads before installing a build. It belongs to a *build*, so there is
one per upload and it is the one that matters here — TestFlight shipped with
this field empty for every build up to 0.13.0, which is a tester being asked to
try something with no statement of what changed.

**What's New** (`appStoreVersionLocalizations.whatsNewText`) is what a shopper
reads on the listing. It belongs to a *version*, exists only once a version is
being prepared, and Apple refuses it outright on a first release — an app with
no previous version has nothing to be new against. Both are 4000 characters,
against Play's 500, so `store_notes.py` usually fits the section whole.

---------------------------------------------------------------------------
The build does not exist when the upload finishes

`altool` returns when the bytes are accepted, and the build is a *resource*
only once Apple has finished processing it — minutes to an hour later. There is
no callback and no way to attach a note to bytes in flight, so the only way to
set What to Test is to wait for the build to appear and then write to it.

That is why this polls, and why the wait is bounded and can be turned off:

  OAA_ASC_NOTES_WAIT   seconds to wait for the build, 900 by default. `0` skips
                       the TestFlight note entirely and goes straight to the
                       listing, which is what a run that must not hold a runner
                       open wants.

A timeout is not an error. The build is uploaded and will process; only its
note is missing, and the next release writes its own.

---------------------------------------------------------------------------
ES256, which openssl signs and a JWT cannot use as it comes

App Store Connect keys are elliptic curve, so the token is ES256 rather than
the RS256 `play_store.sh` uses next door. `openssl dgst -sign` emits the
signature as **DER** — a SEQUENCE of two INTEGERs — and a JWT wants the two
numbers raw, big-endian, 32 bytes each, concatenated. Handing Apple the DER
gets a 401 that says the token is invalid and nothing about why, which is the
kind of failure that reads as a wrong credential. `_raw_signature` below is the
whole of the conversion.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
LOCALE = "en-US"

# Apple's states for a version that can still be edited. A version that is
# waiting for review or already on the store is not one of them, and writing to
# it is refused rather than ignored.
EDITABLE = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}

problems = 0


def warn(message):
    global problems
    problems += 1
    sys.stderr.write("    ! " + message + "\n")


def say(message):
    sys.stdout.write("    " + message + "\n")
    sys.stdout.flush()


def _b64url(raw):
    import base64

    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _raw_signature(der):
    """DER SEQUENCE of two INTEGERs -> the 64 bytes a JWT wants."""

    def integer(at):
        if der[at] != 0x02:
            raise ValueError("openssl did not emit an ASN.1 INTEGER")
        length = der[at + 1]
        return int.from_bytes(der[at + 2 : at + 2 + length], "big"), at + 2 + length

    if der[0] != 0x30:
        raise ValueError("openssl did not emit an ASN.1 SEQUENCE")
    at = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    r, at = integer(at)
    s, _ = integer(at)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def token(key_path, key_id, issuer):
    now = int(time.time())
    header = _b64url(
        json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode()
    )
    # Apple caps a token's life at 20 minutes and refuses a longer one.
    claims = _b64url(
        json.dumps(
            {
                "iss": issuer,
                "iat": now,
                "exp": now + 900,
                "aud": "appstoreconnect-v1",
            }
        ).encode()
    )
    signing = (header + "." + claims).encode()
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
        input=signing,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    return header + "." + claims + "." + _b64url(_raw_signature(der))


def call(bearer, method, path, payload=None):
    """One request. Returns (status, body-as-dict). Never raises for HTTP."""
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + bearer)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            body = answer.read().decode("utf-8") or "{}"
            return answer.status, json.loads(body)
    except urllib.error.HTTPError as refusal:
        body = refusal.read().decode("utf-8", "replace")
        try:
            return refusal.code, json.loads(body)
        except ValueError:
            return refusal.code, {"raw": body}
    except OSError as broken:
        return 0, {"raw": str(broken)}


def said(answer):
    """Apple's own words for a refusal, which name the field that was wrong."""
    errors = answer.get("errors") or []
    detail = "; ".join(
        filter(None, (e.get("detail") or e.get("title") for e in errors))
    )
    return detail or answer.get("raw", "")


def app_id(bearer, bundle):
    status, answer = call(bearer, "GET", "/apps?filter[bundleId]=%s&limit=1" % bundle)
    if status != 200:
        warn("could not look up %s (HTTP %s). %s" % (bundle, status, said(answer)))
        return None
    found = answer.get("data") or []
    if not found:
        warn(
            "App Store Connect has no app with the bundle id %s. The key may "
            "belong to a different team." % bundle
        )
        return None
    return found[0]["id"]


def wait_for_build(bearer, app, build_number, seconds):
    """The build resource, once Apple has finished processing the upload."""
    query = "/builds?filter[app]=%s&filter[version]=%s&limit=1" % (app, build_number)
    deadline = time.time() + seconds
    announced = False
    while True:
        status, answer = call(bearer, "GET", query)
        if status != 200:
            warn("could not look for build %s (HTTP %s). %s"
                 % (build_number, status, said(answer)))
            return None
        found = answer.get("data") or []
        if found:
            return found[0]["id"]
        if time.time() >= deadline:
            return None
        if not announced:
            say("waiting for Apple to finish processing build %s (up to %d min)"
                % (build_number, seconds // 60))
            announced = True
        time.sleep(30)


def set_what_to_test(bearer, build, text):
    status, answer = call(
        bearer, "GET", "/builds/%s/betaBuildLocalizations?limit=50" % build
    )
    if status != 200:
        warn("could not read the build's localizations (HTTP %s). %s"
             % (status, said(answer)))
        return
    mine = [
        row
        for row in (answer.get("data") or [])
        if (row.get("attributes") or {}).get("locale") == LOCALE
    ]
    if mine:
        status, answer = call(
            bearer,
            "PATCH",
            "/betaBuildLocalizations/" + mine[0]["id"],
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": mine[0]["id"],
                    "attributes": {"whatsNew": text},
                }
            },
        )
    else:
        status, answer = call(
            bearer,
            "POST",
            "/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": LOCALE, "whatsNew": text},
                    "relationships": {
                        "build": {"data": {"type": "builds", "id": build}}
                    },
                }
            },
        )
    if status in (200, 201):
        say("What to Test written (%d characters)" % len(text))
    else:
        warn("What to Test was refused (HTTP %s). %s" % (status, said(answer)))


def set_whats_new(bearer, app, version, text):
    status, answer = call(
        bearer, "GET", "/apps/%s/appStoreVersions?limit=20" % app
    )
    if status != 200:
        warn("could not read the app's versions (HTTP %s). %s"
             % (status, said(answer)))
        return
    editable = None
    for row in answer.get("data") or []:
        attributes = row.get("attributes") or {}
        # `appStoreState` is the older spelling of `appVersionState` and both
        # are still served depending on the day; neither is worth depending on
        # alone.
        state = attributes.get("appVersionState") or attributes.get("appStoreState")
        if attributes.get("versionString") == version and state in EDITABLE:
            editable = row["id"]
            break
    if editable is None:
        say("no %s version in an editable state; What's New left alone" % version)
        return

    status, answer = call(
        bearer,
        "GET",
        "/appStoreVersions/%s/appStoreVersionLocalizations?limit=50" % editable,
    )
    if status != 200:
        warn("could not read the version's localizations (HTTP %s). %s"
             % (status, said(answer)))
        return
    mine = [
        row
        for row in (answer.get("data") or [])
        if (row.get("attributes") or {}).get("locale") == LOCALE
    ]
    if not mine:
        warn("the %s version has no %s listing to write to" % (version, LOCALE))
        return

    status, answer = call(
        bearer,
        "PATCH",
        "/appStoreVersionLocalizations/" + mine[0]["id"],
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": mine[0]["id"],
                "attributes": {"whatsNewText": text},
            }
        },
    )
    if status == 200:
        say("What's New written (%d characters)" % len(text))
    elif status == 409:
        # What Apple returns for a first release, which has nothing to be new
        # against. Not a defect and not worth a warning.
        say("What's New is not accepted on a first release; left alone")
    else:
        warn("What's New was refused (HTTP %s). %s" % (status, said(answer)))


def main():
    key_path, bundle, build_number, version, notes = sys.argv[1:6]
    text = json.loads(notes) if notes else ""
    if not text.strip():
        say("CHANGELOG.md has no section for %s; nothing to write" % version)
        return 0
    if not re.fullmatch(r"[0-9]+", build_number or ""):
        warn("the IPA's CFBundleVersion is %r, which is not a build number"
             % build_number)
        return 1

    try:
        bearer = token(key_path, os.environ["OAA_ASC_KEY_ID"],
                       os.environ["OAA_ASC_ISSUER_ID"])
    except (subprocess.CalledProcessError, ValueError, KeyError) as broken:
        warn("could not sign a token for App Store Connect: %s" % broken)
        return 1

    app = app_id(bearer, bundle)
    if app is None:
        return 1

    wait = int(os.environ.get("OAA_ASC_NOTES_WAIT", "900"))
    if wait <= 0:
        say("OAA_ASC_NOTES_WAIT is 0; What to Test skipped")
    else:
        build = wait_for_build(bearer, app, build_number, wait)
        if build is None:
            say("build %s has not finished processing; What to Test left unset"
                % build_number)
        else:
            set_what_to_test(bearer, build, text)

    set_whats_new(bearer, app, version, text)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
