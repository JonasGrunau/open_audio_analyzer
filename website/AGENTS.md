# `website/` — open-audio-analyzer.com

GPL-3.0-or-later, like the application it describes. Nothing here ships in a
release: it is a static site, and no job in `ci.yml` builds it or deploys it.
`npm run deploy` from this directory is the whole release process.

## Why this exists

Because the content is *derived*. The version, the artefact filenames, the
minimum macOS, the fourteen modules, the measurement definitions and the list of
what is not built are all facts about the directories next to this one — and a
site kept in its own repository states them from memory. One repository means a
release can move the binaries and the page describing them in one commit.

It does not replace `docs/site/`. Those pages are generated from this repository
by `tool/docs.dart` and published to `jonasgrunau.github.io`; this is the front
door that links to them, and the two are different audiences — somebody deciding
whether to download it, and somebody who already has.

## Files

| File | Description |
|------|-------------|
| `README.md` | How to run, deploy and regenerate it, and how to point the domain at Cloudflare. The human-facing half of this file. |
| `astro.config.mjs` | Static output, `format: 'file'`, stylesheets always inlined. The whole build configuration. |
| `wrangler.jsonc` | Cloudflare Workers static assets. `not_found_handling: "404-page"` is what serves `404.html`; a Worker does not do that by itself. |
| `package.json` | The six scripts. `dev` and `build` both run `measure` first, so a fresh clone needs no extra step. |
| `tsconfig.json` | Astro's strict preset, and nothing else. |
| `src/layouts/Base.astro` | The shell every page is built from: head, JSON-LD, header, footer. The one place the canonical host and the two outbound links are written. |
| `src/pages/index.astro` | The front page. The meter bridge, the module catalogue, the architecture and the honest gaps. Also the platform table — see the rules below. |
| `src/pages/download.astro` | The six artefacts, what each carries, and what capturing system output needs per platform. |
| `src/pages/404.astro` | Three links and no search. |
| `src/scripts/painters.js` | The canvas painters behind the hero bridge. Pure functions of `(context, size, measurements, frame)`; none owns a timer. |
| `src/scripts/bridge.js` | The one `requestAnimationFrame` loop on the page, and the only thing that drives those painters. Stops when the section scrolls away or the tab is hidden, and freezes on `prefers-reduced-motion`. |
| `src/styles/global.css` | The tokens: the application's palette and spacing scale, the three typefaces, and the two rules carried over from `oaa_ui` — every spatial value from the scale, every number monospaced with tabular figures. |
| `scripts/measure.mjs` | Synthesises a twenty-second stereo programme and measures it — K-weighting, R128 gating, LRA, oversampled true peak, an FFT — into `src/data/bridge.json`. Deterministic: a seeded PRNG, no wall clock, no input files. |
| `scripts/render-modules.mjs` | Photographs the fourteen modules out of `tools/module-renderer` by driving Chrome over the DevTools protocol, and writes `public/modules/*.webp`. |
| `scripts/og.html` | The Open Graph card as a page, so it uses the site's own tokens. Rendered by `npm run og` into `public/og.png`. |
| `public/modules/*.webp` | The fourteen thumbnails. Committed output — see the rules. |
| `public/og.png` | The Open Graph card. Committed for the same reason. |
| `public/oaa.svg`, `public/favicon.svg`, `public/icon-180.png` | The mark, from `assets/brand/`. |
| `public/robots.txt`, `public/sitemap.xml` | Written by hand. Four URLs do not need a generator. |
| `tools/module-renderer/` | A Flutter web target that depends on `package:oaa` and renders one real module per page load against a mock `MeterSource`. Its own `README.md` documents the query string. Not in the root workspace, and not analysed by the repository's gates. |

Generated and git-ignored, all of it by `website/.gitignore`: `node_modules/`,
`dist/`, `.astro/`, `.wrangler/` and `src/data/bridge.json`.

## Rules

- **The numbers on the front page are measurements, not copy.** `measure.mjs`
  runs at build time and the page reads its output. If a number on the hero ever
  becomes a string in an `.astro` file, the site has started claiming things
  about a measurement tool that nobody measured, which is the one failure this
  project cannot afford. The script states where it differs from the shipping
  engine rather than implying it is the same code.

- **The catalogue is photographs of the real modules.** `render-modules.mjs`
  drives the actual widgets through `tools/module-renderer`; there is no second
  copy of any meter here. `painters.js` draws the hero bridge and only the hero
  bridge — it is an illustration of a canvas, not of a measurement display, and
  it must never grow into the catalogue. Two implementations of one meter are two
  meters that will eventually disagree, which is the argument
  `packages/oaa_core/lib/src/meter_source.dart` makes for the application
  itself.

- **The thumbnails and `og.png` are committed rather than built.** Rendering
  them needs Flutter, Chrome and `cwebp` on the machine, and CI should need none
  of the three. The cost is that they go stale silently: **a change to how a
  module looks is a change to its photograph**, and
  `npm run modules -- --only <id>` in the same commit is the whole fix.

- **Nothing here regenerates a version, a requirement or a filename.** `V` in
  `download.astro`, the `req` column beside it and `PLATFORMS` in `index.astro`
  are typed, and no test reads them. They were wrong within a day of being
  written — the macOS floor moved to 14.2 in the same change that added this
  directory and the download page still said 11 Big Sur. Treat them the way
  `CLAUDE.md` treats the install page's blurb: copy that goes stale unseen.

- **No shadows and no gradients, and every spatial value from the scale.** The
  first follows from the application's own "machined panels sitting flush", and
  depth here is background steps and hairlines only. The second is enforced the
  way `oaa_ui` enforces it, because a site that drifts from its subject one raw
  number at a time stops looking like the same object.
