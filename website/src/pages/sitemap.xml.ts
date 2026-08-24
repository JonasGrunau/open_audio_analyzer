/* The sitemap, derived rather than typed.
 *
 * It was a hand-written `public/sitemap.xml`, and `AGENTS.md` recorded what
 * that cost: it "named the front page alone for as long as the documentation
 * had been part of this site". Ten URLs really do not need a generator — but
 * they do need adding to, and the one thing a hand-written list cannot do is
 * notice that a list somewhere else has grown. This reads the same manifest the
 * pages are built from, so publishing a new document adds it here too.
 *
 * Two smaller things it fixes:
 *
 *   - **The URLs come through `urlFor`**, the same helper that writes every
 *     `<link rel="canonical">`. The old file said `https://…com/` for the front
 *     page while the canonical tag said `https://…com` with no slash, which is
 *     a page and its own sitemap describing two different addresses.
 *
 *   - **`<priority>` is gone.** Google has said for years that it ignores it,
 *     and a number nobody reads is a number that will eventually be wrong.
 *
 * `<lastmod>` is the commit date of the file each page is rendered from, which
 * is the only honest source for it: a file's mtime on disk is when the clone
 * happened. If git cannot answer — a tarball, a shallow checkout — the element
 * is left out rather than guessed, because a wrong `lastmod` is worse than none.
 */

import type { APIRoute } from 'astro';

import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

import { urlFor } from '../lib/app.mjs';
import { PAGES, href } from '../lib/docs.mjs';

/* This project is `website/` inside the repository, and git has to be asked
   from the repository. */
const ROOT = resolve(process.cwd(), '..');

/* Every published URL, and the file in the repository it is rendered from.
   `/privacy` is named because it is the one page outside the manual's
   manifest — see src/pages/privacy.astro. */
const ENTRIES = [
  { path: '/', source: 'website/src/pages/index.astro' },
  ...PAGES.map((page) => ({ path: href(page.slug), source: page.source })),
  { path: '/privacy', source: 'docs/site/privacy.md' },
];

/* `/analyzer/index.html` is deliberately absent. It is a real address and it is
   crawlable, but it is the compiled demo the front page loads into an iframe —
   it carries `noindex`, and a sitemap is a request to index. */

function lastModified(source: string): string | null {
  try {
    const out = execFileSync('git', ['log', '-1', '--format=%cI', '--', source], {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

export const GET: APIRoute = () => {
  const urls = ENTRIES.map(({ path, source }) => {
    const at = lastModified(source);
    return `  <url>\n    <loc>${urlFor(path)}</loc>${at ? `\n    <lastmod>${at}</lastmod>` : ''}\n  </url>`;
  });

  const body =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
    urls.join('\n') +
    '\n</urlset>\n';

  return new Response(body, {
    headers: { 'content-type': 'application/xml; charset=utf-8' },
  });
};
