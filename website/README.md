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

Nothing on this site draws a meter of its own.

The fourteen thumbnails in the module catalogue are photographs of the real modules, and the panel on
the front page is a photograph of the real canvas with the running application one press behind it.
Both come from Flutter web targets that depend on `package:oaa` and render the actual widgets — no
second implementation, nothing to keep in step.

That is a deliberate reversal. The front page used to open with a meter bridge this site drew itself
in JavaScript, fed by a twenty-second programme measured at build time with a reimplementation of
BS.1770. The numbers were real and the pictures were not: an approximation of a measurement display
is the one thing this project should not publish, because the two drift apart silently and a picture
of a meter that disagrees with the meter is worse than no picture. It is the argument `MeterSource`
makes for why the application refuses to write its meters twice — see
`packages/oaa_core/lib/src/meter_source.dart`.

`scripts/measure.mjs` is what fed that bridge. Nothing calls it now; it is left in place rather than
deleted because it is a working, self-contained implementation of the gated loudness path, but it is
not part of any build.

## Running it

```sh
npm install
npm run dev        # measures, then serves on :4321
npm run build      # measures, then builds to dist/
npm run preview    # serves dist/
npm run check      # every page at 360, 390 and 768 px — does one scroll sideways?
npm run audit      # Lighthouse over every page, mobile and desktop
```

Neither needs a Flutter toolchain: the thumbnails and the still in front of the analyzer are
committed, and the compiled analyzer is git-ignored and built by `npm run deploy`. The front page
checks whether it is present and omits the button when it is not.

The last two need Google Chrome and a built `dist/`, which is why neither is part of `npm run
build`. They are the only gates this directory has — no job in `ci.yml` builds or measures it — so
run them before deploying anything that changes how a page is laid out or what it loads.

## The typefaces are served from here

The site is set in Archivo, Source Serif 4 and Google Sans Code, and it serves all three itself:

```sh
npm run fonts      # fetch them from Google Fonts, write public/fonts/ and src/styles/fonts.css
```

They used to be a `<link>` to `fonts.googleapis.com` on every page, which is a render-blocking
stylesheet on a second origin naming files on a third — nothing typographic painted until two
cross-origin round trips had finished, and because `global.css` sets `font-synthesis: none` and
varies Archivo's width axis, the fallback re-wrapped the text rather than merely re-weighting it.
It also meant Google saw the IP address of everybody who opened a page, which
`docs/site/privacy.md` had to disclose and no longer does.

The files and `src/styles/fonts.css` are both **generated and both committed** — `npm run fonts`
needs the network and a build must not. Two things not to undo: the `math` and `symbols` subsets of
Google Sans Code are what draw `⌘ ⇧ ⌃ ⇥ ⌦ ⌫` on the keyboard page and the `→` in every document, so
dropping them redraws those in a system font with no error anywhere; and the filenames carry the
family version, which is what lets `public/_headers` cache them for a year as immutable.

## Deploying to Cloudflare

The site is static. It deploys to Cloudflare Workers using
[static assets](https://developers.cloudflare.com/workers/static-assets/), configured in
`wrangler.jsonc`.

```sh
npx wrangler login          # once
npm run deploy              # build + wrangler deploy
```

### Pointing open-audio-analyzer.com at it

Both custom domains are declared in `wrangler.jsonc`, so `wrangler deploy` attaches them, creates
their DNS records and issues their certificates. Two things are left over, because no file in this
directory can hold either:

1. The domain has to be a zone in the same Cloudflare account as the Worker, with its nameservers
   moved to the pair Cloudflare gives you — that move is at the registrar, not in Cloudflare. A
   domain registered *through* Cloudflare Registrar arrives as both already.
2. To send `www` to the apex, add a **Redirect Rule** (Rules → Redirect Rules): if hostname equals
   `www.open-audio-analyzer.com`, then a 301 to `https://open-audio-analyzer.com` preserving path
   and query. Redirect Rules run ahead of Workers, so `www` being a custom domain does not stop it
   from being redirected.

Two lines in `wrangler.jsonc` do something a Worker serving static assets does not do by itself.
`not_found_handling: "404-page"` is what makes `404.html` serve for unknown paths. And the `routes`
are what give the Worker a URL at all: `workers_dev` is false, so a deploy without them succeeds,
prints a version id, and is reachable at no address — which looks like a broken site rather than an
unconfigured one.

### Deploying from CI instead

`wrangler deploy` in a GitHub Action needs one repository secret, `CLOUDFLARE_API_TOKEN`, with the
**Edit Cloudflare Workers** template scoped to this account — it carries Workers Routes and SSL and
Certificates as well, which is what the custom domains in `wrangler.jsonc` need:

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

Every one is the same 390x256 frame, and the two bar meters are narrower than the frame and sit
centred in it, because a pair of vertical bars stretched to 390 px is a pair of squat slabs.

**Captured at two device pixels per logical one, and the frame sized to where it lands.** More
resolution is not sharper here, which took three tries to see. At 4x the pictures came out 1,440 px
wide and the browser resampled them down to the ~390 px the catalogue gives them — a 3.5x downscale
that averages three and a half source pixels into every destination one, which hairlines and
six-pixel labels do not survive. They got *softer* the more resolution they were given. Drawn at 390
logical pixels and captured at two device pixels each, they land 1:1 on a retina display and nothing
is resampled. Change the column count or the padding in `.cat-shot` and `FRAME_W` has to move with
it. The script drives Chrome over the
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

## The live analyzer

`tools/analyzer-demo` is a Flutter web target that depends on `package:oaa` and runs a canvas of eight
real modules — the same `ModuleHost`, the same painters, the same `GridGeometry`, one `MeterClock` —
against the same mock `MeterSource` the thumbnails use. Depending on the application drags in the
engine, and the engine is a native library reached over `dart:ffi`; it builds anyway, because dart2js
only compiles what `main()` reaches and nothing here reaches `OaaEngine`.

```sh
npm run analyzer                 # build the demo, then shoot the still in front of it
npm run analyzer -- --no-build
```

Two outputs, treated differently:

- `public/analyzer/` is about 5 MB of compiled Flutter and is **git-ignored**. `npm run deploy` builds
  it; `npm run build` alone does not, so working on the site needs no Flutter toolchain. The front
  page checks whether it is there and omits the button when it is not, so a site built without it is
  complete rather than broken.
- `public/analyzer-still.webp` **is committed**, because the facade needs it on every build.

The front page does not load any of it on arrival: it shows the still, and swaps in an iframe when a
reader presses the button, prefetching on hover so the press feels immediate. An iframe rather than
mounting Flutter into the page, because Flutter installs document-level keyboard, scroll and focus
handling that fights an ordinary document — and its own route can carry the COOP/COEP headers the
threaded renderer wants without imposing them site-wide.

CanvasKit is **not** vendored: Flutter fetches it from `www.gstatic.com`, which keeps 12 MB of
WebAssembly out of the repository at the cost of one third-party request, and only for readers who
press the button. To self-host it, keep `canvaskit/` from the build (`render-analyzer.mjs` deletes it)
and set `canvasKitBaseUrl` in the bootstrap.

## The window, both tabs

Every other photograph here is cropped to the meters. The hero still is a Flutter *web* build shot
through headless Chrome, so it has no window around it at all; the catalogue is one module per
picture; and the signal-path desktop plate does show a window, but shows it publishing to a tablet,
because that is what the paragraph beside it is about. None of them contains the tab strip, the file
name, the menu row or the status bar — so nothing on this site shows what opening the application
actually looks like.

`public/window/loudness.webp` and `public/window/spectrum.webp` are that picture, one per tab of the
default canvas. They are photographs of the real macOS window, each taken from a session in which the fake DAW played a
real track through the real VST3 into the application on this Mac, so every reading in them is one the
engine took.

```sh
sh packaging/app_window_shots.sh    # from the repository root: takes both PNGs
npm run window                      # encode them into public/window/
npm run window -- --only=spectrum
```

The first half needs a release build of the application, the plugin build for the fake DAW and its
VST3, Screen Recording, permission to post one key, port 47822 free, and **the machine to itself for
about four minutes**: Flutter pauses its ticker when a window is occluded and this application
consumes the plugin's stream from that one ticker, so a covered canvas stops measuring silently —
with the link still up and the transport sitting at 00:00:00:00. The script polls what is frontmost
through every wait and stops at the first sighting of anything else, rather than publishing a picture
of a meter that had stopped.

**Each tab gets a launch of its own**, and the first version of the script did not. Written as one
session with two shutters it had to resume the application in between, and `kill -STOP` is not a
pause: the plugin goes on filling a socket nobody is draining, so the second picture came back with
the canvas carrying its own notice — *Audio was lost — 3073 frames never reached the measurement* —
which is the application being right, and not a meter anyone should photograph. A freeze is terminal
now, and the tab is selected before the settle rather than between the shutters. The Spectrum run
needs that anyway: the spectrogram accumulates from `engine.generation` and a module that is not
built accumulates nothing, so the tab has to be on screen for the whole wait for its ring to fill.

The two pictures are therefore two sessions, which is said rather than glossed. It costs nothing —
unlike the signal-path pair, which sits under a sentence claiming the two screens agree, these two
share no reading at all, because the Spectrum tab shows no loudness number.

The tab is chosen with one posted key, the bare digit, which is the application's own tab binding.
Nothing with screen coordinates is posted; `packaging/ios/screenshots.sh` chooses its tab the
same way, after its hardcoded taps had drifted twice and pressed the wrong controls.

Committed, like the rest of the photographs, because the `website` job in `ci.yml` has none of what
takes them.

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
