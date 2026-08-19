# assets/

What the application bundles that is not code, and the artwork the repository
publishes. GPL-3.0-or-later, except the two font families, which are SIL OFL
1.1 and carry their own licence files.

| File | Purpose |
|------|---------|
| `fonts/Inter-Regular.ttf` | Body text in panels and dialogs. |
| `fonts/Inter-Medium.ttf` | Units and captions. |
| `fonts/Inter-SemiBold.ttf` | Module titles and section headers, and the logo's wordmark. |
| `fonts/Inter-LICENSE.txt` | SIL OFL 1.1. Ships with any binary that bundles the family. |
| `fonts/GoogleSansCode-Regular.ttf` | Scale ticks and secondary numbers. |
| `fonts/GoogleSansCode-Medium.ttf` | The one big reading in a module. |
| `fonts/GoogleSansCode-LICENSE.txt` | SIL OFL 1.1. Ships with any binary that bundles the family. |
| `brand/oaa-logo.svg` | The logo: mark and name, for dark backgrounds. The primary artwork. |
| `brand/oaa-logo-light.svg` | The same lockup with the name in `background`, for light backgrounds. |
| `brand/oaa-mark.svg` | The mark alone, for anything too small or too square for the name. |

## Rules

- **`brand/` is not declared in `pubspec.yaml`, and must not be.** The
  application has no SVG renderer — there is no `flutter_svg` in the dependency
  list and nothing here asks for one — so an `assets:` entry would copy eight
  kilobytes of artwork into every dmg, msix, AppImage and flatpak for code that
  cannot read it. These files are for the README, the documentation site and
  anywhere else the project is shown; the artwork the *application* ships is
  `packaging/icon/`, which is rendered to PNG at build time and reaches the
  platforms through their own icon slots. `fonts/` is the opposite case and is
  declared — in the application's pubspec rather than in `oaa_ui`, for a reason
  written down beside the declaration.

- **The mark belongs to `packaging/icon/make_icons.dart`.** `brand/` holds a
  third and fourth copy of the same four bars, which is one more duplicate than
  this repository would like and is accepted for the same reason `oaa.svg` is:
  the consumers want a vector and writing an SVG emitter costs more than the
  twenty lines it would save. The consequence is a rule — **the mark changes in
  `make_icons.dart` first, and is brought across afterwards.** A logo and an
  icon that disagree about the shape are two identities, and the one people see
  first is whichever they happen to meet first.

- **The wordmark is outlines, not a `<text>` element.** Inter is not installed
  on the machines that will see the logo, so `<text>` would render in Helvetica
  or DejaVu everywhere except here and the tracking — which is the whole of the
  typography — would be lost. It therefore cannot be edited as text: change the
  name, the face or the tracking and the paths are regenerated, not nudged.

- **There are two colour variants because CSS in an SVG does not survive an
  `<img>` element.** `prefers-color-scheme` inside the file is ignored when it
  is loaded as an image, which is how both GitHub and the documentation site
  load it, so a single self-switching file would be a file that renders in one
  theme and is invisible in the other. Pick by background: `oaa-logo.svg` on
  the application's own graphite, `oaa-logo-light.svg` on white or a pale page.

- **Never put two hyphens in a row inside these files' comments.** It ends an
  XML comment, the parser rejects the whole document, and every renderer that
  loads it through an `<img>` shows a broken-image glyph and reports nothing —
  not to the console, not anywhere. The first cut of `oaa-logo.svg` had rules
  drawn in hyphens across its header and was dead on arrival in a way that
  `flutter analyze` and every test in this repository would have called clean.
  Look at the file in a browser after editing the header.

- **The accent stays on the mark.** `OaaColors.accent` means a measured signal
  and `packages/oaa_ui/lib/src/tokens.dart` is emphatic that nothing else may
  borrow it; a teal wordmark beside a teal mark is the accent meaning two
  things inside one logo. The bars are teal, the tallest is capped in `over`,
  and the name is `textPrimary` on dark or `background` on light.
