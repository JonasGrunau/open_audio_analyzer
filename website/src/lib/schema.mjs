/* The JSON-LD each page states about itself.
 *
 * One `SoftwareApplication` object used to be emitted on all ten pages, which
 * meant the privacy policy, the 404 and every documentation page each declared
 * that they *were* the application. That is not a small inaccuracy: structured
 * data is read by machines that have no other way to tell a manual page from the
 * thing it documents, and a site where every URL claims to be the same product
 * has told them nothing.
 *
 * So there are three shapes here, and they share their nodes by `@id` rather
 * than by repeating them — one `WebSite`, one `Person`, and whatever the page
 * actually is. Everything is derived from `app.mjs` and `docs.mjs`, so no
 * version, host or title is typed twice.
 *
 * What is deliberately absent: `aggregateRating` and `review`. They are what
 * produces stars in a search result and there is no rating data behind them.
 * The repository's rule against reporting a number nobody measured is not only
 * about meters.
 */

import { REPO, RELEASES, SITE, VERSION, urlFor } from './app.mjs';

const NAME = 'Open Audio Analyzer';

/* Stable `@id`s, so a node defined once can be referred to from anywhere. A
   fragment on the site's own URL is the convention, and it is only an
   identifier — nothing has to be served at it. */
const AUTHOR_ID = `${SITE}/#author`;
const SITE_ID = `${SITE}/#website`;
const APP_ID = `${SITE}/#app`;

const author = () => ({
  '@type': 'Person',
  '@id': AUTHOR_ID,
  name: 'Jonas Grunau',
  url: 'https://github.com/JonasGrunau',
});

/* The site, and what Google calls the *site name* — the line above the URL in a
   result, which is a different thing from the page's title link below it.
   Google generates it from the home page, and `WebSite` structured data is the
   strongest signal it takes; `og:site_name`, `<title>` and the `h1` in
   `Base.astro` and `index.astro` are the others, and all four say the same four
   words on purpose. Consistency across them is a documented requirement, not a
   nicety.

   `alternateName` is what the system falls back on when it is not confident
   enough to use the preferred name — which is the state a domain-name result
   means. `OAA` is a real alternative rather than an invented one: it is the
   prefix on every symbol in the engine and the name of the CLI binary.

   The domain is deliberately **not** in that list. Google's own troubleshooting
   offers it as a last-resort fallback, and it works — it is the result we are
   trying to move away from, so listing it would tell the system that the thing
   already happening is an acceptable answer. */
const website = () => ({
  '@type': 'WebSite',
  '@id': SITE_ID,
  name: NAME,
  alternateName: ['OAA'],
  url: urlFor('/'),
  inLanguage: 'en',
  author: { '@id': AUTHOR_ID },
  publisher: { '@id': AUTHOR_ID },
});

/* The application itself. `offers` at zero is not a formality — it is the
   difference between "free" and "no price stated", and a consumer that cannot
   tell assumes the second. */
const application = (description) => ({
  '@type': 'SoftwareApplication',
  '@id': APP_ID,
  name: NAME,
  description,
  applicationCategory: 'MultimediaApplication',
  applicationSubCategory: 'Audio analysis',
  operatingSystem: 'macOS, Windows, Linux, iPadOS, Android',
  softwareVersion: VERSION,
  license: 'https://www.gnu.org/licenses/gpl-3.0.html',
  url: urlFor('/'),
  downloadUrl: RELEASES,
  codeRepository: REPO,
  screenshot: urlFor('/analyzer-still.webp'),
  isAccessibleForFree: true,
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  author: { '@id': AUTHOR_ID },
});

const graph = (...nodes) => ({ '@context': 'https://schema.org', '@graph': nodes });

/* A trail a crawler can render as one, and a reader can see is two levels deep
   rather than ten. `/docs` is its own second step; a document under it is a
   third. */
const breadcrumb = (trail) => ({
  '@type': 'BreadcrumbList',
  itemListElement: trail.map(([name, path], at) => ({
    '@type': 'ListItem',
    position: at + 1,
    name,
    item: urlFor(path),
  })),
});

/// The front page: the application, and the site it is described on.
export const homeSchema = (description) =>
  graph(author(), website(), application(description));

/// One documentation page. `TechArticle` and not `Article`, which is what it is
/// — and `isPartOf` the site rather than a second site of its own.
export const docSchema = ({ title, description, path }) =>
  graph(
    author(),
    website(),
    {
      '@type': 'TechArticle',
      '@id': `${urlFor(path)}#article`,
      headline: title,
      description,
      url: urlFor(path),
      inLanguage: 'en',
      isPartOf: { '@id': SITE_ID },
      about: { '@id': APP_ID },
      author: { '@id': AUTHOR_ID },
      publisher: { '@id': AUTHOR_ID },
    },
    breadcrumb(
      path === '/docs'
        ? [['Home', '/'], ['Documentation', '/docs']]
        : [['Home', '/'], ['Documentation', '/docs'], [title, path]],
    ),
  );

/// An ordinary page that is neither the product nor a manual — `/privacy`.
export const pageSchema = ({ title, description, path }) =>
  graph(author(), website(), {
    '@type': 'WebPage',
    '@id': `${urlFor(path)}#page`,
    name: title,
    description,
    url: urlFor(path),
    inLanguage: 'en',
    isPartOf: { '@id': SITE_ID },
    publisher: { '@id': AUTHOR_ID },
  });
