# open-audio-analyzer.com

The website for Open Audio Analyzer — a static Astro site, deployed to Cloudflare Workers.

It lives in this repository rather than beside it because its content is *derived* from the
application: the version, the module list, the measurement definitions, the artefact filenames and
the list of what is not built are all facts about the code in the directories next to this one. One
repository means a release updates the binaries and the page that describes them in the same commit,
and it means a test can assert a number on the page against the constant it came from rather than
trusting that somebody typed it correctly.

Every command below is run from this directory.

## What is unusual about it

The meter bridge on the front page is not an animation. `scripts/measure.mjs` synthesises a
twenty-second stereo programme and measures it, at build time, against the same published
definitions the application uses:

| Stage | What it does |
|---|---|
| K-weighting | ITU-R BS.1770-4 stage-1 shelf and stage-2 RLB, coefficients as printed for 48 kHz |
| Gating | EBU R128: 400 ms blocks at 75% overlap, absolute gate −70 LUFS, relative gate −10 LU |
| LRA | EBU Tech 3342: 3 s windows, −20 LU relative gate, 10th to 95th percentile |
| True peak | 4× oversampling through a 48-tap, 4-phase polyphase FIR |
| Spectrum | 2048-point Hann, mapped onto 64 log-spaced bands with peak-per-bin |

It writes `src/data/bridge.json` — a 600-frame timeline of real measurements, about 96 kB — which
`src/scripts/bridge.js` plays back through the painters in `src/scripts/painters.js`. Those painters
draw the bridge and nothing else — the fourteen thumbnails below it are photographs of the real
modules, for the reason given further down.

The script is deterministic: a seeded PRNG, no wall-clock, no input files. `npm run measure` produces
the same file on any machine, so every number on the front page is checkable by reading one file.

The current build measures **−10.2 LUFS integrated** against a −14 LUFS target and **−0.21 dBTP**
against a −1.0 ceiling, so the validator on the front page shows a genuine two-line delivery
failure. That is deliberate — a demo that always passes teaches nothing.

## Running it

```sh
npm install
npm run dev        # measures, then serves on :4321
npm run build      # measures, then builds to dist/
npm run preview    # serves dist/
```

`src/data/bridge.json` is generated and git-ignored; `npm run dev` and `npm run build` both run
`npm run measure` first, so a fresh clone works with no extra step.

## Deploying to Cloudflare

The site is static. It deploys to Cloudflare Workers using
[static assets](https://developers.cloudflare.com/workers/static-assets/), configured in
`wrangler.jsonc`.

```sh
npx wrangler login          # once
npm run deploy              # build + wrangler deploy
```

### Pointing open-audio-analyzer.com at it

1. Add the domain as a zone in the Cloudflare dashboard and move its nameservers to the pair
   Cloudflare gives you (this is at the registrar, not in Cloudflare).
2. Once the zone is active: **Workers & Pages → open-audio-analyzer → Settings → Domains & Routes →
   Add → Custom domain**, and add both `open-audio-analyzer.com` and `www.open-audio-analyzer.com`.
   Cloudflare creates the DNS records and issues the certificate.
3. To send `www` to the apex, add a **Redirect Rule** (Rules → Redirect Rules): if hostname equals
   `www.open-audio-analyzer.com`, then a 301 to
   `https://open-audio-analyzer.com` preserving path and query.

`not_found_handling: "404-page"` in `wrangler.jsonc` is what makes `404.html` serve for unknown
paths — a Worker serving static assets does not do that by default.

### Deploying from CI instead

`wrangler deploy` in a GitHub Action needs one repository secret, `CLOUDFLARE_API_TOKEN`, with the
**Edit Cloudflare Workers** template scoped to this account:

```yaml
- run: npm ci && npm run build
- uses: cloudflare/wrangler-action@v4
  with:
    apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
    command: deploy
```

## The module catalogue is photographs, not drawings

The fourteen thumbnails in the catalogue are the real modules, rendered by the real application and
photographed. They used to be this site's own painters drawing an approximation of each meter, and an
approximation of a measurement display is the one thing this project should not publish: the two
would drift apart silently, and a picture of a meter that disagrees with the meter is worse than no
picture at all. It is the same argument `MeterSource` makes for why the application refuses to write
its meters twice — see `packages/oaa_core/lib/src/meter_source.dart`.

`tools/module-renderer` is a small Flutter web target that depends on `package:oaa` and renders one
module per page load against a mock `MeterSource`. There is no copy of any module in it, so there is
nothing to keep in sync.

```sh
npm run modules                                  # build the renderer, shoot all fourteen
npm run modules -- --no-build
npm run modules -- --only spectrogram,histogram
npm run modules -- --keep-png                    # keep the full-resolution captures
```

About 120 kB of WebP for the fourteen, at twice their logical size. The script drives Chrome over the
DevTools protocol rather than with `--headless --screenshot`, because it has to wait for the *picture*
rather than for a stopwatch: the page sets `globalThis.oaaRenderReady` once the mock programme has
frozen and the final frame is painted. `--virtual-time-budget` looks like the answer to that and is
not — it does not drive Flutter's ticker, so 8, 16 and 24 second budgets all produced the same 56
frames and a spectrogram with no history in it.

The mock programme lands on the −14 LUFS streaming target, so the meters read in spec and are
coloured as such, but drives true peak to −0.2 dBTP — which is what leaves the Validator a real
failure to report and the Alert Meter a reason to be red. A demo where everything passes teaches
nothing.

Like `public/og.png`, the output is committed: rendering it needs Flutter, Chrome and `cwebp`, and CI
should not need any of them.

## Regenerating the Open Graph card

`public/og.png` is committed, because rendering it needs a browser and CI should not need one. To
change it, edit `scripts/og.html` — it uses the site's own tokens and typefaces — then:

```sh
npm run og
```

## Design notes

The palette, the spacing scale and the 24-column grid are the application's own, taken from its
README rather than invented here, so the site and the thing it describes are visibly the same
object. Two of the application's rules are enforced in `src/styles/global.css` for the same reasons
they are enforced there: every spatial value comes from the scale, and every number is monospaced
with tabular figures. A third follows from "machined panels sitting flush" — there are no shadows
and no gradients on this site, and depth is background steps and hairlines only.

Three typefaces, each carrying one kind of information:

- **Archivo** — headings, panel labels, the small expanded caps
- **Source Serif 4** — prose
- **Google Sans Code** — every number, every path, every command. It is the face the application
  bundles for every number it draws.

`prefers-reduced-motion` freezes the bridge at one representative frame and the status bar says so.
The bridge also stops when it scrolls out of view or the tab is hidden, and resumes where it left
off rather than restarting.
