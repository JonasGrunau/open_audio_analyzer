/* Two things the repository's own Markdown needs before it is a website.
 *
 * These documents were written to be published as flat `.html` files next to
 * one another, and they link to each other that way: `install.html#in-a-daw`.
 * They also link sideways into the repository — `docs/METRICS.md`,
 * `README.md#roadmap` — which resolves when you are reading them on GitHub and
 * resolves nowhere when you are reading them here.
 *
 * Both are fixed here rather than by editing eight documents. The documents are
 * the source of truth and are read in three places (GitHub, an editor, this
 * site); rewriting at render time means a link written in the old style still
 * works, and means the `.md` files carry no knowledge of the URL layout of a
 * site that could change again.
 */

import { defineHastPlugin, defineMdastPlugin } from 'satteri';

import { PAGES, REPO, bySource, href } from './docs.mjs';

const bySlug = new Map(PAGES.map((p) => [p.slug, p]));

/** The rewrite itself, so the three link-shaped node types share one rule. */
function rewrite(url) {
  // `metrics.html#lra` -> `/docs/metrics#lra`, but only for a slug this site
  // actually publishes. An unknown one is left alone, so it shows up as a dead
  // link rather than as a confident 404.
  const page = /^([A-Za-z0-9._-]+)\.html(#.*)?$/.exec(url);
  if (page && bySlug.has(page[1])) return href(page[1]) + (page[2] ?? '');

  // `docs/METRICS.md` -> the page that publishes it, if one does; otherwise
  // the file on GitHub, which is where it actually is.
  const file = /^([A-Za-z0-9._/-]+\.md)(#.*)?$/.exec(url);
  if (file) {
    const published = bySource.get(file[1]);
    return published
      ? href(published.slug) + (file[2] ?? '')
      : `${REPO}/blob/main/${file[1]}${file[2] ?? ''}`;
  }

  return null;
}

export const docsLinks = defineMdastPlugin({
  name: 'oaa-docs-links',
  link(node, context) {
    const url = rewrite(node.url ?? '');
    if (url !== null) context.setProperty(node, 'url', url);
  },
  definition(node, context) {
    const url = rewrite(node.url ?? '');
    if (url !== null) context.setProperty(node, 'url', url);
  },
});

/* The document's own title, removed.
 *
 * Every one of these documents opens with an H1 naming itself, which is right
 * in a file and wrong on a page that has already printed that name from the
 * manifest — two H1s is wrong in the outline as well as on the screen. Only the
 * first block is considered: a `#` further down is a heading somebody meant.
 */
export const dropLeadingTitle = defineMdastPlugin({
  name: 'oaa-drop-leading-title',
  heading(node, context) {
    if (node.depth !== 1) return;
    if (context.indexOf(node) !== 0) return;
    if (context.parent(node)?.type !== 'root') return;
    context.removeNode(node);
  },
});

/* Something to click beside a heading.
 *
 * Astro already gives every heading an id, which is what makes
 * `install.html#in-a-daw` resolve. It does not give them anything to link with,
 * and a reference document whose sections cannot be linked to is a reference
 * document people paste screenshots of. Runs after `satteriHeadingIdsPlugin`,
 * because it needs the id that plugin sets.
 */
export const headingAnchors = defineHastPlugin({
  name: 'oaa-heading-anchors',
  element: {
    filter: ['h2', 'h3', 'h4', 'h5', 'h6'],
    visit(node, context) {
      const id = node.properties?.id;
      if (!id) return;
      context.setProperty(node, 'className', [
        ...[node.properties.className ?? []].flat(),
        'h-linked',
      ]);
      context.appendChild(node, {
        type: 'element',
        tagName: 'a',
        properties: {
          className: ['h-anchor'],
          href: `#${id}`,
          'aria-label': 'Link to this section',
        },
        /* No text node. Astro derives the table of contents from this tree
           after the plugins have run, so a `#` inside the heading becomes part
           of the heading's text and every entry in the contents list ends in
           one. The character is drawn by the stylesheet instead. */
        children: [],
      });
    },
  },
});

/* A specification table has a min-content width its columns cannot go below,
 * and on a phone that is wider than the screen. The site's own tables already
 * scroll inside a focusable container; Markdown cannot express one, so it is
 * wrapped here — including `tabindex`, because a region that scrolls has to be
 * reachable without a pointer.
 */
export const scrollableTables = defineHastPlugin({
  name: 'oaa-scrollable-tables',
  element: {
    filter: ['table'],
    visit(node, context) {
      context.wrapNode(node, {
        type: 'element',
        tagName: 'div',
        properties: {
          className: ['table-scroll'],
          tabindex: '0',
          role: 'region',
          'aria-label': 'Table',
        },
        children: [],
      });
    },
  },
});

/* The code theme.
 *
 * Every fenced block in these eight documents is a shell command or has no
 * language at all, so this is less a syntax theme than a way of keeping the two
 * colours a terminal listing actually has: the command, and the comment
 * explaining it. Written out rather than imported because every stock theme
 * brings six hues from somebody else's palette, and this site has one accent
 * that means "a measurement" and nothing else.
 */
export const codeTheme = {
  name: 'oaa',
  type: 'dark',
  colors: {
    'editor.background': '#171a1e', // --raised
    'editor.foreground': '#e6e8eb', // --text
  },
  settings: [
    { settings: { background: '#171a1e', foreground: '#e6e8eb' } },
    {
      // These hexes are the CSS tokens written out, because a TextMate theme
      // cannot read a custom property. That means they go stale silently, and
      // this one did: it kept `--faint`'s old #565e67 after the token moved,
      // which is 2.65:1 on this theme's own background and the last thing
      // standing between the documentation and a clean contrast pass. A code
      // comment is the smallest text on the page and the one most often the
      // part you actually needed to read.
      scope: ['comment', 'punctuation.definition.comment'],
      settings: { foreground: '#7c848d' }, // --faint
    },
    {
      scope: ['string', 'string.quoted', 'constant.numeric', 'constant.language'],
      settings: { foreground: '#8a9199' }, // --muted
    },
    {
      scope: ['variable', 'variable.other', 'punctuation.definition.variable'],
      settings: { foreground: '#8a9199' },
    },
    {
      scope: ['keyword', 'keyword.control', 'storage.type', 'entity.name.function'],
      settings: { foreground: '#e6e8eb' },
    },
  ],
};
