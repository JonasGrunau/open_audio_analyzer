/* The facts about the application that the site states, read from the
 * application.
 *
 * The version was typed into three files. It was `0.9.0` in all three about
 * fifteen minutes after `0.10.0` was tagged, which is how a hand-copied version
 * always ends: the release is the moment nobody is thinking about the website.
 * `pubspec.yaml` is where the number actually lives, so it is read from there
 * at build time and the site cannot disagree with the thing it is describing.
 */

import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/* The canonical host, written once.
 *
 * It was written twice — here in the layout and again as `site` in
 * `astro.config.mjs` — and `AGENTS.md` claimed there was one. Two literals of a
 * host do not disagree loudly: they disagree in a `<link rel="canonical">` and
 * in a sitemap `<loc>`, which is a page telling a crawler that the page it is
 * on is a different page. `astro.config.mjs` imports this, and so does
 * everything that has to name an absolute URL.
 */
export const SITE = 'https://open-audio-analyzer.com';

/* Every absolute URL the site states, from the one host and the one rule about
   trailing slashes (`trailingSlash: 'never'`, so `/docs/install` and not
   `/docs/install/`). The root is the exception the rule needs stating for: it is
   `https://open-audio-analyzer.com/`, with the slash, because that is the URL —
   the bare origin is a host, not an address. Canonical tags and the sitemap both
   come through here so they cannot describe the site differently. */
export const urlFor = (path) => new URL(path, SITE).href;

export const REPO = 'https://github.com/JonasGrunau/open_audio_analyzer';
export const RELEASES = `${REPO}/releases/latest`;

/* The repository root: this project is `website/` inside it. `process.cwd()`
   rather than `import.meta.url`, which in a built page resolves into the bundle
   rather than into the source tree. */
const root = resolve(process.cwd(), '..');

function versionFromPubspec() {
  const pubspec = readFileSync(join(root, 'pubspec.yaml'), 'utf8');
  // `version: 0.11.0+13` — the build number is Flutter's and means nothing to
  // somebody downloading a file.
  const found = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m.exec(pubspec);
  if (!found) {
    throw new Error(
      'No `version:` in pubspec.yaml. The site prints the application version ' +
        'in four places and reads it from there; fix the pubspec or this regex.',
    );
  }
  return found[1];
}

export const VERSION = versionFromPubspec();

/* Where the two app stores are, and the fact that only one of them has
   anything on it.
 *
 * Google Play hands out **two** links for a closed test and they are not
 * interchangeable:
 *
 *   `PLAY_TESTING`  — `play.google.com/apps/testing/<package>`, the opt-in
 *                     page. A web page, and the one Play Console calls "join on
 *                     the web".
 *   `PLAY_LISTING`  — `play.google.com/store/apps/details?id=<package>`, the
 *                     listing. On Android this is a deep link the Play Store
 *                     app answers itself; in a desktop browser it is a 404.
 *
 * Neither is the badge's destination. **Both are useless on their own**,
 * because a closed test grants access by list and not by link: Play only lets
 * an account opt in if the developer has already put that account on the
 * track's tester list, so a reader who follows either link cold is turned away
 * with no idea why. The badge points at `/testing` instead — a page that says
 * get on the list first, then opt in, and hands over both links there, labelled
 * for what each is for.
 *
 * `TESTER_GROUP_NAME` is the Google Group that makes step one self-service: a
 * public group anybody can join, listed on the Play track, so the reader adds
 * themselves rather than waiting on somebody to paste their address into the
 * Console. **Until it exists this is null**, and `/testing` falls back to asking
 * on the repository — which works, and is slower for both sides.
 *
 * It is the group's **short name** and not either of the two strings that name
 * the group, because there are two and they are not interchangeable: the
 * website needs the web address `groups.google.com/g/<name>`, and Play Console
 * needs the email address `<name>@googlegroups.com`. Typing the wrong one into
 * either place fails quietly — Play accepts a malformed group and simply never
 * matches anybody against it, and a mailto in an href is a link that does
 * nothing useful. One name, derived twice, cannot disagree with itself.
 *
 * `APP_STORE` is null and the App Store badge is drawn unlinked beside its
 * `Coming soon` caption. When the iPad build clears review this becomes the
 * product URL and `index.astro` links the badge without any other change. */
export const PLAY_PACKAGE = 'com.openaudioanalyzer.oaa';
export const PLAY_TESTING = `https://play.google.com/apps/testing/${PLAY_PACKAGE}`;
export const PLAY_LISTING = `https://play.google.com/store/apps/details?id=${PLAY_PACKAGE}`;
/* The group's short name — `open-audio-analyzer-testers`, not a URL and not an
   email address. Set it and `/testing` switches step one to self-service.
   Play Console's Testers tab wants `${TESTER_GROUP_NAME}@googlegroups.com`. */
export const TESTER_GROUP_NAME = 'open-audio-analyzer-closed-test';
export const TESTER_GROUP = TESTER_GROUP_NAME
  ? `https://groups.google.com/g/${TESTER_GROUP_NAME}`
  : null;
export const APP_STORE = null;
