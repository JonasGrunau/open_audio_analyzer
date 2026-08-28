/* What the documentation site is: every page, in navigation order.
 *
 * This list is the manifest the old GitHub Pages generator carried, moved here
 * because the pages are rendered here now. It is a list and not a directory scan for
 * the reason it always was: a site whose contents are whatever happens to be in
 * `docs/` publishes `AGENTS.md` to strangers the day somebody moves it, and
 * instructions to a machine are not a manual.
 *
 * `source` is a path from the *repository* root, not from the website — these
 * documents live beside the code they describe and are edited there.
 * `docs/METRICS.md`, `docs/ODR.md` and `docs/WIRE.md` are normative and held
 * by tests; nothing here copies them, and a missing one fails the build rather
 * than quietly publishing a site with a hole in it.
 */

export const REPO = 'https://github.com/JonasGrunau/open_audio_analyzer';

/** Where a document is edited, for the link in every page's title bar. */
export const sourceUrl = (source) => `${REPO}/blob/main/${source}`;

export const PAGES = [
  {
    source: 'docs/site/index.md',
    slug: 'index',
    title: 'Open Audio Analyzer',
    nav: 'Overview',
    blurb: 'What it measures, what it will not do, and what is on the canvas.',
    section: '',
  },
  {
    source: 'docs/site/install.md',
    slug: 'install',
    title: 'Install',
    nav: 'Install',
    blurb:
      'pkg, Windows installer, tarball, AppImage and flatpak — which of them ' +
      'installs the plugin for you, and what each one will not do. The tablet ' +
      'builds come from a store instead.',
    section: 'Using Open Audio Analyzer',
  },
  {
    source: 'docs/site/keyboard.md',
    slug: 'keyboard',
    title: 'Keyboard',
    nav: 'Keyboard',
    blurb: 'Every shortcut, generated from the table the application binds.',
    section: 'Using Open Audio Analyzer',
  },
  {
    source: 'docs/site/analysing-files.md',
    slug: 'analysing-files',
    title: 'Analysing files',
    nav: 'Analysing files',
    blurb: 'The report panel and the `oaa` command-line analyser.',
    section: 'Using Open Audio Analyzer',
  },
  {
    source: 'docs/METRICS.md',
    slug: 'metrics',
    title: 'Metrics',
    nav: 'Metrics',
    blurb:
      'What every number means, how it is computed, and whether this build ' +
      'measures it.',
    section: 'Reference',
  },
  {
    source: 'docs/ODR.md',
    slug: 'odr',
    title: 'Open Dynamic Range',
    nav: 'Open Dynamic Range',
    blurb:
      'The ODR specification: two dynamics readings defined to the operand, ' +
      'the conformance cases that hold an implementation to it, and an ' +
      'annex on what the values mean.',
    section: 'Reference',
  },
  {
    source: 'docs/WIRE.md',
    slug: 'wire',
    title: 'Wire protocol',
    nav: 'Wire protocol',
    blurb: 'The remote display protocol, normatively.',
    section: 'Reference',
  },
  {
    source: 'CHANGELOG.md',
    slug: 'changelog',
    title: 'Changelog',
    nav: 'Changelog',
    blurb: 'What changed, and which numbers moved.',
    section: 'Reference',
  },
  {
    source: 'docs/site/building.md',
    slug: 'building',
    title: 'Building',
    nav: 'Building',
    blurb: 'Building from source, the test gates, and making the installers.',
    section: 'Contributing',
  },
];

/* A blurb is written for the contents list, where Markdown renders. Two places
   need it as plain text — a `<meta name="description">` and a `<title>` — and
   the backticks would be literal in both. Done here rather than in a page,
   because an Astro component's frontmatter is lexed for template literals and a
   backtick inside a regular expression inside one ends the template early. */
export const plainBlurb = (page) => page.blurb.replace(/`/g, '');

/* The home page is `/docs` rather than `/docs/index`: this site is
   `trailingSlash: 'never'` with `build.format: 'file'`, so `docs.astro` is the
   page at `/docs` and `docs/<slug>.astro` is everything under it. */
export const href = (slug) => (slug === 'index' ? '/docs' : `/docs/${slug}`);

/** The manifest keyed by the id the content loader gives an entry. */
export const bySource = new Map(PAGES.map((p) => [p.source, p]));

/** Nav order, grouped. The empty section is the home page and is not listed. */
export const SECTIONS = PAGES.reduce((sections, page) => {
  if (!page.section) return sections;
  const last = sections.at(-1);
  if (last?.name === page.section) last.pages.push(page);
  else sections.push({ name: page.section, pages: [page] });
  return sections;
}, []);
