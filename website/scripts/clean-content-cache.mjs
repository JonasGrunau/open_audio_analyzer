// Drop Astro's rendered-content cache before a build.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A content collection is cached in `node_modules/.astro/data-store.json`, and
// the cache holds the *rendered HTML*, keyed by the Markdown file's digest. The
// documentation pages are rendered from Markdown that lives outside this
// project by four plugins in `src/lib/markdown.mjs` — and a change to one of
// those plugins does not change any document's digest. So the store answers
// with HTML produced by the previous version of the plugin, `astro build`
// reports success, and the site is silently a build behind.
//
// That is not a hypothetical: every plugin in this project was written with the
// build reporting success and the output unchanged, including once where the
// edit was a marker string put there to prove the plugin was running.
//
// Deleting the store costs one re-render of eight Markdown files, which on this
// site is a fraction of a second — cheaper than the class of bug where what
// deploys is not what the source says.

import { rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

const store = resolve(
  import.meta.dirname,
  '..',
  join('node_modules', '.astro', 'data-store.json'),
);

rmSync(store, { force: true });
