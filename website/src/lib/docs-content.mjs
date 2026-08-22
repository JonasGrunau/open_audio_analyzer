/* Getting a manifest entry's Markdown out of the content collection.
 *
 * The collection is keyed by the path the file has in the repository — see the
 * `generateId` in src/content.config.ts — so a manifest entry and a loaded
 * document are matched by the one thing that cannot drift.
 *
 * A manifest entry with no file behind it throws, which fails the build. That
 * is the failure this indirection exists to catch: somebody renames a document
 * and the site quietly loses a page. It is what `tool/docs.dart` exited
 * non-zero for, kept because it is the one that actually happens.
 */

import { getCollection } from 'astro:content';
import { PAGES } from './docs.mjs';

let cache;

async function entries() {
  cache ??= new Map((await getCollection('docs')).map((e) => [e.id, e]));
  return cache;
}

export async function documentFor(page) {
  const found = (await entries()).get(page.source);
  if (!found) {
    throw new Error(
      `The documentation manifest lists ${page.source}, and no such file was ` +
        `loaded. Either the document was renamed — in which case fix the ` +
        `manifest in src/lib/docs.mjs — or its path is outside the patterns ` +
        `in src/content.config.ts.`,
    );
  }
  return found;
}

/** Every page's document, checked in one pass so a build reports all of them. */
export async function everyDocument() {
  const loaded = await entries();
  const missing = PAGES.filter((p) => !loaded.has(p.source));
  if (missing.length > 0) {
    throw new Error(
      `The documentation manifest lists ${missing.length} document(s) that ` +
        `were not loaded: ${missing.map((p) => p.source).join(', ')}`,
    );
  }
  return PAGES.map((page) => ({ page, entry: loaded.get(page.source) }));
}

/* Every anchor these documents point at, checked against the headings that
 * exist.
 *
 * `tool/docs.dart` failed the build when a page it was asked to publish had no
 * file, which is the coarse version of this. The fine version is worth having:
 * `analysing-files.md` linked to `install.html#where-oaa-keeps-your-configuration`
 * for as long as that page has existed, and the heading is called "Where Open
 * Audio Analyzer keeps your configuration". Nothing said so, because a fragment
 * that matches no element is not an error in a browser — it is a page that
 * opens at the top, which looks like the link working.
 *
 * Reads the Markdown rather than the rendered HTML so it can run before the
 * pages are written, and takes the heading ids from `render`, so it is checking
 * what will actually be in the document rather than its own idea of a slug.
 */
export async function checkAnchors(render) {
  const documents = await everyDocument();

  const ids = new Map();
  for (const { page, entry } of documents) {
    const { headings } = await render(entry);
    ids.set(page.slug, new Set(headings.map((h) => h.slug)));
  }

  const dead = [];
  for (const { page, entry } of documents) {
    const body = entry.body ?? '';
    // `](install.html#in-a-daw)` and `](#in-a-daw)`, which is the same document.
    for (const [, target, anchor] of body.matchAll(
      /\]\(([A-Za-z0-9._-]*?)(?:\.html)?(#[A-Za-z0-9._-]+)\)/g,
    )) {
      const slug = target === '' ? page.slug : target;
      const known = ids.get(slug);
      if (!known) continue; // Not a page of this site; nothing to check against.
      if (!known.has(anchor.slice(1))) {
        dead.push(`${page.source} -> ${slug}${anchor}`);
      }
    }
  }

  if (dead.length > 0) {
    throw new Error(
      `${dead.length} link(s) point at a heading that does not exist:\n  ` +
        `${dead.join('\n  ')}\n` +
        `Fix the link in the document, or the heading it meant to reach.`,
    );
  }

  return documents;
}
