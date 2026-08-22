/* The documentation, loaded from where it is written.
 *
 * Nothing is copied into this project. These are the repository's own
 * documents — `docs/METRICS.md` and `docs/WIRE.md` are normative and held by
 * tests, `docs/site/keyboard.md` is generated from the shortcut table the
 * application binds, and `CHANGELOG.md` is the changelog — so the site reads
 * them in place and a change to a document is a change to the site with no
 * step in between.
 *
 * The pattern is a list rather than `docs/**\/*.md` on purpose: `docs/` also
 * holds `PLAN.md` and `AGENTS.md`, which are records of intent and instructions
 * to a machine, and neither is documentation. The list here matches the one in
 * `src/lib/docs.mjs`, which is the manifest the pages are built from; a source
 * that exists here and not there is simply not published, and one that exists
 * there and not on disk fails the build.
 */

import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';

const docs = defineCollection({
  loader: glob({
    // The repository root. The website is one directory inside it.
    base: '../',
    pattern: ['docs/site/*.md', 'docs/METRICS.md', 'docs/WIRE.md', 'CHANGELOG.md'],
    // The path itself, so an entry can be matched to the manifest by the file
    // it came from. The default slugifies, which folds `docs/METRICS.md` and a
    // hypothetical `docs/metrics.md` onto one id.
    generateId: ({ entry }) => entry,
  }),
});

export const collections = { docs };
