// @ts-check
import { defineConfig } from 'astro/config';

import { satteri, satteriHeadingIdsPlugin } from '@astrojs/markdown-satteri';

import {
  codeTheme,
  docsLinks,
  dropLeadingTitle,
  headingAnchors,
  scrollableTables,
} from './src/lib/markdown.mjs';
import { SITE } from './src/lib/app.mjs';

export default defineConfig({
  site: SITE,
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file', inlineStylesheets: 'always' },
  compressHTML: true,
  devToolbar: { enabled: false },

  /* The documentation pages are rendered from the repository's own Markdown.
     See src/content.config.ts for which documents, and src/lib/markdown.mjs
     for the two rewrites they need. */
  markdown: {
    shikiConfig: { theme: codeTheme, wrap: false },
    processor: satteri({
      mdastPlugins: [dropLeadingTitle, docsLinks],
      /* The heading-id plugin is Astro's own and is normally implicit; naming
         it here is what puts it before the anchor plugin, which needs the id
         it sets. */
      hastPlugins: [satteriHeadingIdsPlugin(), headingAnchors, scrollableTables],
    }),
  },

  vite: {
    // The Markdown lives one directory up, in `docs/` and at the repository
    // root. Without this the dev server refuses to read outside its own root.
    server: { fs: { allow: ['..'] } },
  },
});
