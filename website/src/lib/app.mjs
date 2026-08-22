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

export const REPO = 'https://github.com/JonasGrunau/open_audio_analyzer';
export const RELEASES = `${REPO}/releases/latest`;

/* The repository root: this project is `website/` inside it. `process.cwd()`
   rather than `import.meta.url`, which in a built page resolves into the bundle
   rather than into the source tree. */
const root = resolve(process.cwd(), '..');

function versionFromPubspec() {
  const pubspec = readFileSync(join(root, 'pubspec.yaml'), 'utf8');
  // `version: 0.10.0+11` — the build number is Flutter's and means nothing to
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
