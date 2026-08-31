# `website/` — open-audio-analyzer.com

GPL-3.0-or-later, like the application it describes. Nothing here ships in a
release: it is a static site, deployed to Cloudflare rather than attached to a
tag. The `website` job in `ci.yml` builds it on every event and deploys it on a
push to `main`; `npm run deploy` from this directory does the same thing by
hand, for a change you want live before it lands.

## Why this exists

Because the content is *derived*. The version, the artefact filenames, the
minimum macOS, the fourteen modules, the measurement definitions and the list of
what is not built are all facts about the directories next to this one — and a
site kept in its own repository states them from memory. One repository means a
release can move the binaries and the page describing them in one commit.

**The documentation is part of this site now.** `/docs` renders the
repository's own Markdown — `docs/site/*.md`, `docs/METRICS.md`, `docs/WIRE.md`
and `CHANGELOG.md` — read from where those files are written rather than copied
in, so a change to a document is a change to the site with no step between.
`tool/docs.dart` used to generate a separate GitHub Pages site from the same
Markdown. It was replaced by this one, and in 0.11.0 it went: what it did last
was publish a redirect per page, and those redirects are deployed — GitHub Pages
serves what it was last given, so `jonasgrunau.github.io/…/install.html`, which
is in released READMEs and in issue threads nobody can edit, goes on arriving
here without anything continuing to publish it.

## Files

| File | Description |
|------|-------------|
| `README.md` | How to run, deploy and regenerate it, and how to point the domain at Cloudflare. The human-facing half of this file. |
| `astro.config.mjs` | Static output, `format: 'file'`, stylesheets always inlined. The whole build configuration. |
| `wrangler.jsonc` | Cloudflare Workers static assets, and the two custom domains. `not_found_handling: "404-page"` is what serves `404.html`, and `routes` is what gives the Worker an address at all — `workers_dev` is false, so a deploy without them succeeds and is reachable nowhere. A Worker does neither by itself. |
| `package.json` | The eleven scripts, and the one dependency that is not Astro or Wrangler: `lighthouse`, which `npm run audit` drives. `prebuild` runs before every build and is not optional — see `scripts/clean-content-cache.mjs`. `deploy` builds the live analyzer first, which `build` alone does not, so working on the site needs no Flutter toolchain. |
| `tsconfig.json` | Astro's strict preset, and nothing else. |
| `src/content.config.ts` | The documentation collection: the four sources above, loaded from the repository root by path rather than slug, so an entry can be matched to the file it came from. A list and not a glob, because `docs/` also holds `AGENTS.md`, which is instructions to a machine and not documentation. |
| `src/lib/docs.mjs` | Every page the manual publishes, in navigation order — the manifest the old Pages generator used to carry. A document that is not in it is not published; one that is in it and not on disk fails the build. |
| `src/lib/docs-content.mjs` | Getting a manifest entry's Markdown out of the collection, matched by the path it has in the repository. The indirection exists to fail the build when somebody renames a document, which is the failure that actually happens. |
| `src/lib/markdown.mjs` | The two things the repository's own Markdown needs before it is a website: links written for flat `.html` files (`install.html#in-a-daw`), and links sideways into the repository (`docs/METRICS.md`, `README.md#-in-a-daw`). Rewritten at render time rather than by editing eight documents that are also read on GitHub. |
| `src/lib/app.mjs` | `SITE`, `urlFor`, `REPO`, `RELEASES`, `VERSION`, and the app stores — `PLAY_PACKAGE`, `PLAY_TESTING`, `PLAY_LISTING`, `TESTER_GROUP_NAME`, `TESTER_GROUP`, `APP_STORE`. The header says why neither Play URL is the badge's destination. The version is **read from the application's `pubspec.yaml` at build time**: typed here, it was three literals and it was a release behind within the hour after a tag. `SITE` is the canonical host, which was written twice — here and as `site` in `astro.config.mjs`, which now imports it — and `urlFor` is the one rule about trailing slashes, so a `<link rel="canonical">` and a sitemap `<loc>` cannot name the same page differently. They did: the front page was `…com` in one and `…com/` in the other. |
| `src/lib/schema.mjs` | What each page claims to be, in JSON-LD: the front page is the application, a documentation page is a `TechArticle` with a breadcrumb, `/privacy` and `/impressum` are `WebPage`s and `/404` is nothing. One `SoftwareApplication` object used to be emitted on all ten, so the privacy policy and every manual page declared that they *were* the product. Nodes are shared by `@id` rather than repeated, and everything is derived from `app.mjs` and `docs.mjs`. **No `aggregateRating`** — that is what draws stars in a search result and there is no rating behind it. The `WebSite` node is also where the **site name** is set: the line above the URL in a Google result, which is not the page title below it. Google builds it from the home page, weighing this node most and `og:site_name`, `<title>` and the `h1` after it, so all four say `Open Audio Analyzer` and have to keep saying it. `alternateName` carries `OAA` as the fallback for when the system is not confident enough to use the full name — deliberately **not** the domain, which Google offers as a last resort and which is the result this exists to move away from. |
| `src/layouts/Base.astro` | The shell every page is built from: head, JSON-LD, header, footer. Takes a `schema` for what the page is and a `noindex` for the one page that is not a page — `/404`, which `not_found_handling` serves at every address that has none, so a canonical there is a thousand URLs all claiming to be `/404`. It preloads two of the five typefaces; the comment beside them says which two and why not the third. |
| `src/layouts/Docs.astro` | One documentation page: the contents, the document, its sections. What is not ordinary about it is the readout above the title, which names the file in the repository the page was rendered from and links to it — the reader who has just found the mistake can see where the fix goes. |
| `src/pages/index.astro` | The front page. The analyzer, the signal path, the module catalogue, the measurement table and the platform table. Also `METRICS` and `PLATFORMS` — see the rules below — and `BANDS` / `ANCHORS`, ODR Annex A.2 drawn to scale under the Dynamics section, one of the annex's three copies (`CLAUDE.md` § Documentation Sync). **Every word of it is addressed to somebody who makes records**, which is the rule the whole page is held to: the three-tier architecture section is gone, the measurement table says what each reading means rather than how it is computed, and the Known gaps section went the same way — the twelve are in `README.md` and the one a reader has to *act* on, that publishing has no password, is a sentence in the tablet paragraph under `#reach`. |
| `src/pages/docs.astro` | `/docs`: `docs/site/index.md` rendered, with the manual's contents underneath it. A landing page that is only a list of links makes the reader choose before telling them what they are choosing between. |
| `src/pages/docs/[slug].astro` | Every documentation page but that one. `build.format: 'file'` and no trailing slash, so it writes `dist/docs/install.html` and the address is `/docs/install`. |
| `src/pages/404.astro` | Three links and no search. |
| `src/pages/privacy.astro` | `/privacy`: the privacy policy, rendered from `docs/site/privacy.md`. Outside the manual's manifest on purpose, and at the short address because App Store Connect holds this URL — see the file header. |
| `src/pages/impressum.astro` | `/impressum`: the provider identification § 5 DDG requires of a German site — name, postal address, telephone, email, and the § 18 Abs. 2 MStV line naming who is responsible for the content. German first and English under it, because the law is about being *found*: the word a German reader looks for in a footer is the one this page is called, and everyone else on this site reads English. Written into the page rather than rendered from `docs/site/`, unlike `/privacy` — that document is there because it makes claims about what the application does with a microphone and a socket, and this one claims nothing about the software at all: it changes when a person moves house. **Three things are deliberately absent and the header says why**: the EU ODR link, which every template still carries and which points at a platform shut down on 20 July 2025; a VAT number, because saying there is none is a claim about somebody's tax status; and the four paragraphs of Haftungsausschluss boilerplate, which restate §§ 7–10 DDG whether or not a page recites them. Outside the manual's manifest like `/privacy`, and named in `sitemap.xml.ts` and `scripts/check-layout.mjs` for the same reason. |
| `src/pages/testing.astro` | `/testing`: **where the Google Play badge lands**, and the reason it does not land on Play. A closed test grants access by list and not by link, so both of Play's URLs turn away everybody who is not already a tester and neither says why — the badge would recruit nobody. This page is the missing explanation: get on the list, opt in, install. Google's badge guidelines constrain the artwork and say nothing about the destination, which was checked before it was built; Apple's *do* constrain it, which is one more reason their badge is not a link. `TESTER_GROUP_NAME` in `app.mjs` switches step one between a self-join Google Group and asking on the repository — the group's **short name**, because the site needs `groups.google.com/g/<name>` and Play Console needs `<name>@googlegroups.com`, and both are derived from the one value rather than typed twice. Outside the manual's manifest, like `/privacy`, and named in `sitemap.xml.ts` for the same reason. |
| `src/pages/alternatives/decibel.astro` | `/alternatives/decibel`: what somebody searching for a free alternative to Decibel by Process.Audio lands on. The README has called this project a reimplementation of Decibel's ideas since the first commit, and the README is not one of the nine documents `docs.mjs` publishes — so the sentence answering that question was on GitHub and nowhere on this domain. **The comparison table is four rows because four is what there is evidence for**: every cell in its Decibel column is Process.Audio's own description or a behaviour recorded in `README.md`, and where we do not know there is no row. That is the engine's rule about unmeasured quantities applied to somebody else's product, and it is what the page is worth — a guess in that table is what stops a reader believing the rows that are right. One row is a design this project *took* rather than improved on, and the gaps section is `README.md`'s Known gaps shortened and not softened. `slimFooter`, and not for the usual reason: the four-column footer carries the Apple and Google trademark credit those companies require *wherever their badge is shown*, and no badge is on this page. Outside the manual's manifest like `/privacy`, `/impressum` and `/testing`, and named in `sitemap.xml.ts` and `scripts/check-layout.mjs` for the same reason. |
| `src/scripts/facade.js` | The still in front of the live analyzer, and the swap to the real thing when a reader asks for it — prefetched on hover, an iframe rather than Flutter mounted into this document. Its header says why both. It also measures the two travel distances the press animates over, and writes them onto the elements as `--dx` / `--dy` for the keyframes in `index.astro` to read; the header says why they are measured off `offsetLeft` and not off a bounding box. **On a phone none of it runs**, because the control is `display: none` there and a hidden element is never hovered, focused or pressed — the stylesheet is the only place that breakpoint is written, and the file's header says why there is no second copy of it here. |
| `src/scripts/toc.js` | Marking the section you are in, in the list on the right. A `scroll` listener coalesced into one frame, and **not** an `IntersectionObserver` — the rule the list wants is "the last heading to have passed under the bar", and writing that as a band gives the observer a root rectangle of negative height, and nothing ever intersects one of those — so the callback fires once and never again. Its header has the whole account. |
| `src/styles/fonts.css` | The eight `@font-face` rules, **generated** by `npm run fonts` — do not edit it. Inlined into every page like every other stylesheet here, so the declarations cost no request. |
| `src/styles/global.css` | The tokens: the application's palette and spacing scale, the three typefaces, and the two rules carried over from `oaa_ui` — every spatial value from the scale, every number monospaced with tabular figures. **One token is deliberately not the application's**: `--faint`, for the reason written above it. |
| `src/styles/docs.css` | The manual, set as a manual: body text at full contrast rather than muted, a measure, and the three-column shape. Global rather than scoped because Astro scopes a component's CSS by stamping the elements it compiled, and it did not compile these — they are Markdown rendered at build time. It also carries `.legal`, the one-column shell `/privacy` and `/impressum` share: they sit one link apart in the footer, and a scoped style would be two copies of a measure a reader moves between. |
| `src/data/analyzer-still.json` | The still's pixel size **and the five widths it is published at**, written beside the picture by `npm run analyzer`, so the facade is sized and its `srcset` built from the images that exist rather than from numbers typed twice. |
| `src/data/flow-shots.json` | The intrinsic size of each signal-path plate, written beside the pictures by `npm run flow` for the same reason as the still's — and **it is also the gate**. `index.astro` draws only the stages that have an entry, so a machine that cannot take one of the three photographs builds a site that is a plate shorter rather than a site with a hole in it. |
| `scripts/measure.mjs` | The gated loudness path in JavaScript — K-weighting, R128 gating, LRA, oversampled true peak, an FFT — which fed the meter bridge the front page used to draw. **Nothing calls it.** Left in place because it works and is self-contained, not because it is used; see the rules. |
| `scripts/record.mjs` | Runs the engine over a real track and writes the recording the demos replay. **The one script here with a prerequisite outside the repository**: the track is CC BY 3.0 and 35 MB, fetched by `dart run tool/fetch_test_audio.dart` from the repository root. It refuses to run without the attribution file that tool writes, because the licence requires the credit wherever the audio is published. The excerpt was chosen by measuring — the header lists the four candidates and their loudness ranges. It encodes through `afconvert` where that exists and `ffmpeg` everywhere else; the first is the better AAC encoder at this bitrate and made the committed excerpt, the second is what keeps the whole path off a Mac-only dependency. |
| `scripts/render-modules.mjs` | Photographs the fourteen modules out of `tools/module-renderer` and writes `public/modules/*.webp`. Two device pixels per logical one and the frame sized to where it lands — more resolution came out softer, and the README says why. |
| `scripts/render-analyzer.mjs` | Builds `tools/analyzer-demo` into `public/analyzer/` and photographs it into `public/analyzer-still.webp`, at five widths. `--no-still` stops after the build, which is what the CI deploy runs: the still is committed and the browser it is shot through is one machine's. The header lists them and what each is for: the picture is the front page's Largest Contentful Paint and it is asked for at anything from 370 to 1376 CSS px. |
| `scripts/render-flow.mjs` | `npm run flow`: the three photographs behind the signal-path section, from two different places, and nothing is shot here. The plugin panel comes out of `plugin/build/oaa_editor_snapshot`, which needs no DAW and no screen-recording grant. The desktop and tablet plates are both written by `packaging/signal_path.sh`, **in one session**: the tablet is a remote display attached to that desktop, so the two are one measurement photographed twice rather than two that happen to agree. The desktop plate is deliberately not the headless `tools/analyzer-demo` render the hero uses — that one has no chrome, so it photographs the modules and not the program. This only picks up what was left in `build/packaging/screenshots/`. `--only=` does one stage; shooting `desktop` or `tablet` alone re-encodes one half of a pair and is only ever right straight after a run of that script. Each missing stage prints what would make it. |
| `scripts/lib/headless.mjs` | Serving a directory to a headless Chrome and photographing what it draws, shared by both renderers and by `npm run audit`. Waits for `globalThis.oaaRenderReady` — the picture — rather than for a stopwatch, because `--virtual-time-budget` does not drive Flutter's ticker. Its `serve()` **parses `public/_headers` and gzips text**, so an audit measures the cache policy and the transfer sizes the deploy actually produces rather than a bare local server's absence of both — compression is worth 3.4x here, because every stylesheet is inlined and the HTML is the payload. |
| `scripts/lib/fonts.mjs` | Puts the application's typefaces where a tool's own pubspec can name them. `OaaType` asks for the bare family names, which only an application-level declaration provides, and a relative path in that declaration builds fine and 404s at runtime. |
| `scripts/fetch-fonts.mjs` | `npm run fonts`: the typefaces, fetched from Google Fonts once and written into `public/fonts/` with `src/styles/fonts.css` to name them. Its header says why `math` and `symbols` are not optional and why `latin-ext` is kept although nothing needs it yet. |
| `scripts/audit.mjs` | `npm run audit`: Lighthouse over every page the site publishes, mobile and desktop, from the same manifest `check-layout.mjs` walks. Nothing in `ci.yml` measures this directory, so a score here is only as durable as something that re-measures it. It also checks every JSON-LD block parses, which no Lighthouse audit does. |
| `scripts/check-layout.mjs` | `npm run check`: opens every page at 360, 390 and 768 px with the viewport actually overridden, and fails if one scrolls sideways. The bug it catches is invisible in a screenshot and obvious on a phone, and a browser window cannot be dragged narrow enough to see it. Needs Chrome, so it is not part of `npm run build`. **It reported every page clean while three of them overflowed**, for a reason worth knowing before writing another check like it: `probe` emulated a *mobile* viewport, and mobile emulation shrinks a too-wide document to fit, so `innerWidth` came back as the content's width and the comparison was a quantity against itself. Desktop metrics at a chosen width are the layout a phone actually gets — `initial-scale=1` pins the scale and the page scrolls — and the check now also fails outright when the width it asked for is not the width it got. |
| `scripts/clean-content-cache.mjs` | Drops Astro's rendered-content store before a build. The store is keyed by each document's digest, so editing a plugin in `src/lib/markdown.mjs` changes no digest, the build reports success and the site is silently a build behind. Every plugin here was written into that trap at least once. |
| `scripts/og.html` | The Open Graph card as a page, so it uses the site's own tokens. Rendered by `npm run og` into `public/og.png`. |
| `public/modules/*.webp` | The fourteen thumbnails. Committed output — see the rules. |
| `public/analyzer-still.webp`, `public/analyzer-still-*.webp` | The still the front page shows in front of the live analyzer, at 768, 1024, 1440, 1920 and 2560 px. Committed for the same reason, and needed by every build rather than only by a deploy. The bare name is the widest, so anything pointing at it still resolves. |
| `public/flow/*.webp` | The signal path's three plates — `plugin`, `desktop`, `tablet`. Committed output, like the thumbnails, because making them needs JUCE, Flutter, Chrome, `cwebp` and Xcode between them and the website job has none of the five. |
| `public/og.png` | The Open Graph card. Committed for the same reason. |
| `public/oaa.svg`, `public/icon-180.png` | The app icon. **Written by `packaging/icon/make_icons.dart`**, not copied here by hand — `oaa.svg` is `assets/brand/oaa-icon.svg` byte for byte, and is what `scripts/og.html` references rather than holding its own copy of the mark. |
| `public/favicon.svg` | The tab icon, and **the one icon in this repository that is drawn by hand**: the wave cropped out of the tile and stroked in the signal colour, because a tab shows it at 16 px where the tile is most of what you see and the wave inside it is four grey pixels. `Base.astro` uses it for the header mark as well, so a reader fetches one file. `make_icons.dart` wrote the tile over it until 0.10.0; there is a note where that line was. |
| `public/badges/app-store.svg`, `public/badges/google-play.svg` | Apple's and Google's own badge artwork, downloaded from [Apple's marketing guidelines](https://developer.apple.com/app-store/marketing/guidelines/) and [Google's Partner Marketing Hub](https://partnermarketinghub.withgoogle.com/brands/google-play/google-play/lockups-icons-badges/) and committed **unaltered**. Neither may be recoloured, restretched, cropped or animated, so `index.astro` sets no colour, filter, transform or hover state on `.store-art` — with one deliberate exception, recorded in the CSS: the App Store badge is dimmed to `opacity: .42` while there is no iPad app, which departs from Apple's "Don't modify" and was asked for knowingly. It is scoped to `span.store-badge`, which is precisely the not-yet-a-link case, so it lifts itself the day `APP_STORE` gets a URL — the state of each badge is carried by the caption under it. They are the only files in this repository nobody here holds the copyright to; the credit line both owners require is the `.foot-tm` paragraph in `Base.astro`. Re-download rather than edit: Google's guidelines say to use the current artwork, which is also why `_headers` gives them a month rather than `immutable`. |
| `public/robots.txt` | Written by hand, and short enough to stay that way: crawl everything, and here is the sitemap. It deliberately does **not** disallow `/analyzer/` — that document carries `noindex`, and a disallowed URL is never fetched, so the refusal would never be read. |
| `src/pages/sitemap.xml.ts` | The sitemap, **generated** from the manual's manifest, because the hand-written one it replaces named the front page alone for as long as the documentation had been part of this site. `<lastmod>` is the source file's commit date, omitted rather than guessed when git cannot answer. |
| `public/_headers` | The cache policy and three security headers, applied by Cloudflare to everything in `dist/`. Without it the platform default is `max-age=0, must-revalidate` on every asset — an ETag round trip for a typeface that will never change again. Only `/fonts/*` is `immutable`, and the file says why the photographs are not. |
| `public/fonts/` | The five typeface files the site is set in, and `OFL.txt`, which has to travel with them. **Generated** by `npm run fonts`; committed, like the photographs, because a build must not need the network. |
| `tools/module-renderer/` | A Flutter web target that depends on `package:oaa` and renders one real module per page load, reading the recording in `tools/oaa_replay`. Its own `README.md` documents the query string. |
| `tools/analyzer-demo/` | The same idea, one canvas further: eight real modules, one `MeterClock`, the same `ModuleHost` and the same painters the application runs. Compiled into `public/analyzer/` and loaded only when a reader presses the still. **Its `web/programme.oaaz` and `web/programme.m4a` are committed**, unlike the renderer's — 1.2 MB, and the deploy runs on a runner that may not fetch the 35 MB source track they are cut from. `web/ATTRIBUTION.md` is the CC BY credit and travels into the build with them. |
| `tools/oaa_record/` | A **Dart CLI that links the real engine by FFI**, pushes a real track through it, and writes down what it measured. The only thing in `website/` that touches `oaa_engine`, and it never runs in a browser. |
| `tools/oaa_replay/` | The recording format, and `ReplaySource` — the **fourth `MeterSource`**, beside the native one, the socket the tablet reads and the mock this replaced. Pure Dart, so it compiles for the web. Shared by both targets, so the stills and the live canvas cannot disagree about what the material did: they are the same forty-five seconds, measured once. |
| `tools/oaa_replay/test/` | The scope window, which is the one reading this source *synthesises* — every other number is read out of a plane. It is assembled from the decoded audio and handed to a reader that decides what is new from the clock rather than by looking at the buffer, so a window narrower than the recording's cadence is drawn as missing audio: the front page's oscilloscope was a comb for a week. `dart test` here is a step in `ci.yml`'s `checks` job — the `website` job runs `npm` and nothing else, and this directory is outside anything `flutter analyze` reaches. |

Generated and git-ignored, all of it by `website/.gitignore`: `node_modules/`,
`dist/`, `.astro/`, `.wrangler/`, `src/data/bridge.json`, `public/analyzer/` —
about 7 MB of compiled Flutter that `npm run deploy` builds — and
`tools/*/web/programme.*`, which is the recording and the audio it was taken
from. Those last are derived from a track this repository does not carry, so
they cannot be committed and a fresh clone has to run `npm run record` before
either renderer produces anything.

## Rules

- **Nothing on this site draws a meter of its own.** The catalogue is
  photographs of the real modules and the front page is a photograph of the real
  canvas with the application itself one press behind it; both come out of
  Flutter targets that depend on `package:oaa`. The front page used to open with
  a meter bridge this site drew in JavaScript from measurements taken at build
  time — real numbers and invented pictures, which is the one thing a
  measurement tool must not publish, because the drawing and the meter drift
  apart silently. It is the argument `packages/oaa_core/lib/src/meter_source.dart`
  makes for why the application refuses to write its meters twice.
  `scripts/measure.mjs` is what fed it and is now called by nothing; deleting it
  would lose a working, dependency-free implementation of the gated loudness
  path, so it stays, unwired and labelled.

- **The documentation is read from where it is written, never copied.** The
  manifest in `src/lib/docs.mjs` and the pattern in `src/content.config.ts` are
  the two lists that decide what is published, and they must agree: a source in
  one and not the other is a page that silently does not exist. A document that
  moves fails the build here, which is what the old Pages generator exiting
  non-zero used to be for — and the `website` job runs this build on every
  event, so it fails a pull request rather than a deploy.

- **The thumbnails, `og.png` and the analyzer still are committed rather than
  built.** Rendering them needs Flutter, Chrome and `cwebp` on the machine, and
  CI should need none of the three. The cost is that they go stale silently: **a
  change to how a module looks is a change to its photograph**, and
  `npm run modules -- --only <id>` in the same commit is the whole fix.

- **The typefaces are served from this origin, and `npm run fonts` is the only
  thing that writes them.** They were three families linked from
  `fonts.googleapis.com` on every page: one render-blocking stylesheet on a
  second origin, naming files on a third, so nothing typographic painted until
  two cross-origin round trips had finished — and this site sets
  `font-synthesis: none` and varies Archivo's `wdth` axis, so the fallback does
  not merely differ in weight, it re-wraps. That showed up as
  `cumulative-layout-shift` on eight pages.

  Two things not to undo. **`math` and `symbols` are kept for Google Sans Code
  and are load-bearing**: `⌘ ⇧ ⌃ ⇥ ⌦ ⌫` on the keyboard page and the `→` and `↗`
  in every documentation page live in those subsets and in neither `latin` nor
  `latin-ext`, so shipping latin alone redraws the one page whose whole subject
  is which key to press — with no error and no failed request. And **the
  filenames carry the family version**, which is what lets `_headers` call
  `/fonts/*` immutable; a refresh that changes a file changes its name.

  `scripts/og.html` still links Google Fonts, on purpose: `npm run og` renders it
  from a `file://` URL, where `/fonts/…` resolves to nothing. It runs once, at
  build time, and no reader is involved.

- **`--faint` is the one token that is not the application's.**
  `OaaColors.textFaint` is #565e67, which is 2.97:1 on `--ink` — under the 4.5:1
  WCAG AA asks of body text, and used here at 0.6875rem for the footer, the
  eyebrow, every table heading and the whole documentation contents list. In the
  application it labels a meter the eye is already on. On a page somebody arrives
  at cold, on a phone, it is text they cannot read, and it was the only thing
  standing between this site and a clean accessibility score on all eleven pages.
  It is #7c848d here, which is the first value on the same ramp to clear 4.5:1
  against all three of the site's backgrounds — the code blocks sit on the
  lightest one, so it is set by that and not by the page. Three distinguishable
  steps remain. **The Shiki theme in `src/lib/markdown.mjs` carries the same
  hexes written out**, because a TextMate theme cannot read a custom property;
  it kept the old value after the token moved and was the last contrast failure
  on the site.
  **The application still has the problem**, and fixing it there means reviewing
  fourteen modules and the skins and re-shooting every thumbnail, so it is
  recorded rather than done.

- **Nothing on this site requests anything from a third party.** After the fonts
  moved, the only off-origin request left is CanvasKit from `www.gstatic.com`,
  and only for a reader who presses the button that loads the live analyzer.
  `docs/site/privacy.md` states both, and it is the file that goes stale if this
  changes — it disclosed the Google Fonts request for exactly as long as the
  request existed, which is the standard to keep.

- **The version is derived; the requirements are not.** `src/lib/app.mjs` reads
  `VERSION` out of the application's `pubspec.yaml`, so no page can name a
  release the repository is not on. `PLATFORMS` in `index.astro` — the minimum
  macOS, what each installer carries — is still typed, and no test reads it. It
  was wrong within a day of being written: the macOS floor moved to 14.2 in the
  same change that added this directory and the download page still said 11 Big
  Sur. Treat it the way `CLAUDE.md` treats the install page's blurb: copy that
  goes stale unseen.

- **`tools/` is outside the root workspace, and outside the repository's analyze
  gate.** Each of the four packages resolves its own dependencies, and nothing
  in `ci.yml` builds this directory — so on a runner, `package:oaa_replay` names
  a package that has never been resolved there. They are excluded in the root
  `analysis_options.yaml` for that reason and analysed by the
  `analysis_options.yaml` each of them carries. It is worth knowing *why* they
  passed the root gate for as long as they did: each target held its own copy of
  the source it drove and imported it relatively, and a relative import needs no
  package resolution. Sharing it is what turned a gate that never looked into
  one that failed.

- **No shadows and no gradients, and every spatial value from the scale.** The
  first follows from the application's own "machined panels sitting flush", and
  depth here is background steps and hairlines only. The second is enforced the
  way `oaa_ui` enforces it, because a site that drifts from its subject one raw
  number at a time stops looking like the same object.

  **Square corners go with it, and there is exactly one exception.** No rule ever
  said so, because until the signal path there was no `border-radius` on this
  site outside the facade's play button. `.flow-device` — the bezel around the
  tablet — has one, and it holds only because it is not a style applied to a
  surface: it is the shape of a real object, and a tablet drawn with square
  corners is a drawing of something else. It stays the only one. If a second is
  ever wanted, that is the moment to take this one out rather than to start a
  set.

- **The front page is written for a musician, not for a contributor.** It is the
  page somebody arrives on, and it spent most of its life explaining the
  architecture to them: three tiers and their thread affinities, `ModuleFrame`
  plus a painter, a seqlock, filter topologies and window lengths, what a
  continuous-integration run asserts and in which units. All of that is true and
  all of it belongs in `README.md`, `docs/METRICS.md` and the `AGENTS.md` files,
  where the reader has asked for it. Here the test is whether a mastering
  engineer would care: **what a number means, what the app does, what to
  download**. Standards keep their names — `BS.1770-4` and `R 128` are what a
  delivery spec cites, so they are credentials rather than jargon — but the
  mechanism behind a number is not on this page: how a band is spaced, which
  percentiles an `LRA` is taken across, how a preset file is structured. That is
  `docs/METRICS.md` and `README.md`, and the reader there has asked for it.

  **The gaps are honest somewhere the reader will look, and that is no longer
  here.** The front page carried six of the twelve for three releases; the
  section is gone and the list lives in `README.md` and `/docs`. What survived onto the page is the one gap a reader has to act on
  rather than know about — the tablet link has no password, so publish on a
  network you control — because a warning is not documentation and it has to be
  where the feature is described. Anything else that is not built goes in the
  README, not back onto this page.
