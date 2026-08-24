# assets/

What the application bundles that is not code, and the artwork the repository
publishes. GPL-3.0-or-later, except the two font families, which are SIL OFL
1.1 and carry their own licence files.

| File | Purpose |
|------|---------|
| `fonts/Inter-Regular.ttf` | Body text in panels and dialogs. |
| `fonts/Inter-Medium.ttf` | Units and captions. Also every word in the plugin's status panel — see the rule below. |
| `fonts/Inter-SemiBold.ttf` | Module titles and section headers, and the logo's wordmark. |
| `fonts/Inter-LICENSE.txt` | SIL OFL 1.1. Ships with any binary that bundles the family. |
| `fonts/GoogleSansCode-Regular.ttf` | Scale ticks and secondary numbers. |
| `fonts/GoogleSansCode-Medium.ttf` | The one big reading in a module, and every number in the plugin's status panel. |
| `fonts/GoogleSansCode-LICENSE.txt` | SIL OFL 1.1. Ships with any binary that bundles the family. |
| `brand/oaa-logo.svg` | **The drawing.** An Inkscape document: the wave, in white, over the teal ramp, on a 500-unit square. The only artwork in this repository that is edited by hand, and the file every icon and every twin below is generated from. |
| `brand/oaa-logo-background.svg` | Generated. The ramp on its own, full bleed and square. |
| `brand/oaa-mark.svg` | Generated. The wave on its own, white, on nothing. **For a dark surface only** — it is white, so on a pale page it is not there. The plugin compiles this file into its binary; see the rule below. |
| `brand/oaa-icon.svg` | Generated. The app icon: the wave on the ramp in a squircle tile. The one to reach for when the background is not known. `make_icons.dart` writes it out again as `website/public/oaa.svg`, byte for byte, which is the copy the Open Graph card uses. |
| `brand/oaa-icon.png` | Generated. The same icon at 512 px with transparent corners, for `README.md` and anywhere else that wants an image rather than a vector. |
| `brand/oaa-mark-old.svg` | The four-bar mark, retired in 0.10.0. Kept because it is on every release before it. |

## Rules

- **`brand/` is not declared in `pubspec.yaml`, and must not be.** The
  application has no SVG renderer — there is no `flutter_svg` in the dependency
  list and nothing here asks for one — so an `assets:` entry would copy the
  artwork into every pkg, Windows installer, tarball, AppImage and
  flatpak for code that cannot read it. These files are for the README, the
  documentation site and anywhere else the project is shown; the artwork the
  *application* ships is `packaging/icon/`, which is rendered to PNG at build
  time and reaches the platforms through their own icon slots. `fonts/` is the
  opposite case and is declared — in the application's pubspec rather than in
  `oaa_ui`, for a reason written down beside the declaration.

- **Three of these files are compiled into the plugin, and none of them may be
  hand-copied into it.** `plugin/CMakeLists.txt` reads `fonts/Inter-Medium.ttf`,
  `fonts/GoogleSansCode-Medium.ttf` and `brand/oaa-mark.svg` through
  `juce_add_binary_data`, so the VST3, the AU and the Standalone carry the
  application's own two faces and the application's own mark rather than
  whatever the platform offers and a second drawing of the wave. Two
  consequences: **renaming or deleting one of the three breaks the plugin
  build**, which is the good failure — and the mark in particular is
  *generated*, so transcribing its path into C++ would be a copy that the next
  `make_icons.dart` run silently leaves behind. The rest of that argument is in
  the header of `plugin/src/OaaPluginEditor.cpp`.

- **`oaa-logo.svg` is the only file here anybody edits, and the direction of
  that used to be the other way round.** Until 0.10.0 the mark was four rounded
  rectangles whose numbers lived in `_Mark` in
  `packaging/icon/make_icons.dart`, and everything in `brand/` was a hand-copied
  transcription of them under a rule saying the mark changed there first and was
  brought across afterwards. That rule was workable for four rectangles and is
  not for a wave with three hundred control points, so it is gone: the drawing
  is the master, `make_icons.dart` parses the one path and the one gradient out
  of it, and it writes every other file in this directory. **Redraw
  `oaa-logo.svg`, run `dart run packaging/icon/make_icons.dart`, commit what it
  changed.** Nothing here is brought across by hand any more.

- **`make_icons.dart` insists on one visible `<path>` and at least two gradient
  stops, and stops with a message when it does not find them.** Inkscape keeps
  hidden layers in the document, which is why "visible" is the test — the logo
  file carries objects the export did not want, set to `display:none`. If a
  redraw splits the wave into two paths or converts a corner to an arc, the
  program says so and nothing is written; that is the design, because the
  alternative is sixty wrong files committed in silence.

- **There is still no lockup with the name set beside the mark.** `oaa-logo.svg`
  exists now and is the square logo — the wave on its ramp — not a wordmark
  lockup. This file once listed `oaa-logo.svg` and `oaa-logo-light.svg` as
  though both were drawn when neither was, which sent readers looking for
  artwork that was not there; the row above describes what the file actually
  is. When a lockup is drawn, the three rules below are what it has to satisfy —
  they are requirements, not a description of something that exists.

- **The wordmark must be outlines, not a `<text>` element.** Inter is not
  installed on the machines that will see the logo, so `<text>` would render in
  Helvetica or DejaVu everywhere except here and the tracking — which is the
  whole of the typography — would be lost. It therefore cannot be edited as
  text: change the name, the face or the tracking and the paths are
  regenerated, not nudged.

- **It needs two colour variants, because CSS in an SVG does not survive an
  `<img>` element.** `prefers-color-scheme` inside the file is ignored when it
  is loaded as an image, which is how both GitHub and the documentation site
  load it, so a single self-switching file would be a file that renders in one
  theme and is invisible in the other. Pick by background: one on the
  application's own graphite, one on white or a pale page. The *mark* needed
  neither while it was teal bars, which read on both; it is white now, so it has
  the same problem and `oaa-icon.svg` is the answer to it — the icon brings its
  own ground, so one file covers every background.

- **Never put two hyphens in a row inside these files' comments.** It ends an
  XML comment, the parser rejects the whole document, and every renderer that
  loads it through an `<img>` shows a broken-image glyph and reports nothing —
  not to the console, not anywhere. An early logo draft had rules drawn in
  hyphens across its header and was dead on arrival in a way that
  `flutter analyze` and every test in this repository would have called clean.
  The generated files carry a header written by `_brandHeader` in
  `make_icons.dart`, so the rule now applies there as much as here. Look at the
  file in a browser after editing either.

- **The teal is the ground now, and the mark is white.** It was the other way
  round until 0.10.0: the bars were `OaaColors.accent` on graphite, with the
  tallest capped in `over`. The ramp the wave sits on runs `#6EF2CC` to
  `#20AA92` and passes through `#35E0C4`, which is `OaaColors.accent` exactly,
  so the icon is still built on the palette's one signal hue — it is the field
  rather than the figure. The rule it was protecting is unchanged and now
  applies to the wordmark alone: `packages/oaa_ui/lib/src/tokens.dart` is
  emphatic that nothing borrows the accent to mean anything but a measured
  signal, so the name is `textPrimary` on dark or `background` on light, never
  teal.

- **The white mark cannot go on a pale surface, and the old one could.** Four
  teal bars read on anything, so `oaa-mark.svg` was safe to hand to any
  consumer; the wave is white and on white it is not there. So anything that
  does not know its background takes `oaa-icon.svg`, which brings its own — the
  Open Graph card does, through `website/public/oaa.svg`. Reach for the bare
  mark only where the background is known to be dark.

- **A browser tab is the case where neither of them works, and it has a file of
  its own.** The tile at 16 px is mostly ramp with four grey pixels of wave in
  it, and the white mark on a pale tab strip is not there at all — so
  `website/public/favicon.svg` is a third drawing: the wave cropped out of the
  tile and stroked in the signal colour, which survives a light strip and a dark
  one. It is the only artwork in this repository outside `brand/` that is
  hand-drawn, `make_icons.dart` deliberately does not write it, and it is the
  one file where the rule above this table is suspended.
