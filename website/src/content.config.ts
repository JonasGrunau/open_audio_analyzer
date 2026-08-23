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
 * to a machine, and neither is documentation. The list here is a superset of
 * the one in `src/lib/docs.mjs`, which is the manual's manifest and its
 * navigation order: a source that exists there and not on disk fails the
 * build, and one that exists here and not there is published only if some page
 * asks for it by name. Exactly one does — `src/pages/privacy.astro` renders
 * `docs/site/privacy.md` at `/privacy`, because a privacy policy is not a
 * chapter of the manual and its URL is typed into App Store Connect. Anything
 * else loaded here and unclaimed is simply not published.
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
