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

const website = () => ({
  '@type': 'WebSite',
  '@id': SITE_ID,
  name: NAME,
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
