// Puts the application's typefaces where a tool's pubspec can name them.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// `OaaType` asks for these families by their bare names — 'Inter', not
// 'packages/oaa/Inter' — and only an *application-level* font declaration gives
// them those, so each tool has to declare them itself rather than inherit the
// ones `package:oaa` ships.
//
// Declaring them by relative path (`../../../assets/fonts/Inter-Regular.ttf`)
// looks like it works: the Flutter tool copies the files into the package and
// the build succeeds. It writes that path into the asset manifest verbatim
// though, so the running app asks for `assets/../../../assets/fonts/...` and
// gets five 404s and a fallback typeface. Copying them in and naming them
// locally is the version that actually loads.
//
// The copies are git-ignored: they are a build product, not a second set of
// fonts to keep in step with the first.

import { cpSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

export const FONTS = [
  'Inter-Regular.ttf',
  'Inter-Medium.ttf',
  'Inter-SemiBold.ttf',
  'GoogleSansCode-Regular.ttf',
  'GoogleSansCode-Medium.ttf',
];

/// Copy the application's fonts into `toolDir/assets/fonts`.
export function syncFonts(repoRoot, toolDir) {
  const to = join(toolDir, 'assets/fonts');
  mkdirSync(to, { recursive: true });
  for (const font of FONTS) {
    cpSync(join(repoRoot, 'assets/fonts', font), join(to, font));
  }
}
