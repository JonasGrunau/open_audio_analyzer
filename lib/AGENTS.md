# lib/

The application. GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `main.dart` | Parses the command line, loads the configuration, `runApp(ProviderScope(...))`. Nothing else. |
| `src/app/` | The shell: window, status bar, the keyboard shortcut table, and the launch options. See its own `AGENTS.md`. |
| `src/canvas/` | The grid canvas, the tab strip and the layout controller. See its own `AGENTS.md`. |
| `src/clock/` | `MeterClock` — the only `Ticker` in the app. |
| `src/data/` | Riverpod providers (configuration only) and `metric_reader.dart`. |
| `src/modules/` | One file per meter module, all thirteen. Bodies only — the frame is the canvas's. |
| `src/panels/` | Settings, presets, the delivery-target editor, the report. See its own `AGENTS.md`. |
| `src/storage/` | Where configuration lives and how it is read and written. See its own `AGENTS.md`. |
| `src/remote/` | Both ends of the remote display — the desktop host and the tablet client — plus mDNS. See its own `AGENTS.md`. |
| `src/plugin/` | The listener the VST3 / AU plugin connects to, and the transport it sends. Loopback only. |

## Rules

- **Measurements never pass through Riverpod.** Providers hold configuration:
  things that change when a human does something. Routing a ~47 Hz stream of
  readings through one would rebuild the subtree under every meter forty-seven
  times a second to change numbers a painter could have read for free.
- **One clock.** Modules do not create tickers, timers or stream subscriptions.
  Independent tickers drift, and two meters showing the same quantity could then
  disagree within a single frame — a correctness bug, not a cosmetic one.
- **A module is `ModuleFrame` + a painter, and the painter takes
  `repaint: clock`.** That constructor argument is the whole render strategy: it
  re-rasters without rebuilding the widget. The module widget supplies the
  **body only**; `ModuleHost` wraps it in the frame, so the title, border, menu
  affordance and selection state are written once for all thirteen.
- **Every module painter extends `MeterPainter`, never `CustomPainter`
  directly.** `CustomPainter.hitTest` returns null and `RenderCustomPaint` reads
  that as *true*, so a plain painter silently swallows every pointer event that
  lands on the meter — and the canvas's drag and selection layers sit behind the
  module. The symptom is a meter that cannot be selected or dragged by its own
  face, with nothing reported anywhere.
- **`metric_reader.dart` is the only place `oaa_core` meets `oaa_engine`.**
  There is now a second implementation of the same signature backed by the wire
  protocol — `WireSnapshot`, in `oaa_wire` — and every module works unchanged
  against either. That is what lets a tablet with no engine draw the desktop's
  meters with the desktop's painters. Keep the seam narrow: a module reads
  `MeterSource`, never a concrete engine, and if something cannot be drawn from
  a `MeterSource` the fix is to widen the interface rather than to write a
  second painter.
- **Nothing allocates inside `paint()`** — no `Paint`, `Path`, `TextPainter`,
  list or string concatenation. Cache in the `State`. In practice that means:
  `Paint`s built in the painter's constructor; static labels laid out once with
  `layoutParagraph`; changing readouts through `ValueParagraph`, which re-lays
  out only when the *formatted string* differs; and bulk geometry written into a
  preallocated `Float32List` and drawn with one `drawRawPoints`. A filled
  spectrum is 512 vertical segments in a single call, not a `Path`.
- **Readings scale with the module; labels do not.** A bar, an arc and a dial
  are already sized off the box they are handed, and the number beside them has
  to be too — the same canvas is a 960 px window on a laptop and a 2560 px one
  on a desktop, so a font size written as a constant is legible at exactly one
  of them. Derive it from the module (`size.height * k`, or the gauge's
  diameter) and clamp it, taking the *width* into the minimum wherever a long
  reading could run off the side. What stays fixed is everything that is not a
  measurement: a scale's tick labels, a column heading, a unit, PASS and FAIL.
  Those are the same size in all thirteen modules, and scaling them is how thirteen
  modules end up with thirteen type scales.
- **A module never guards its own minimum size.** Declare it as
  `minBodyWidth`/`minBodyHeight` on `ModuleKind` and let the frame substitute
  the placeholder. A painter that returns early draws nothing, and nothing with
  a title bar over it is a panel the user reads as broken rather than as small.
- **A module that accumulates advances on `engine.generation`, never on
  `paint`.** Paint also runs on a resize, a theme change, or an ancestor marking
  the subtree dirty. A spectrogram that scrolled on those would invent time that
  no audio passed through, and it would look completely plausible.
- **An image from `toImageSync` may never be drawn into the picture that makes
  the next one.** It is a handle to a display list the engine has not
  rasterised yet and it keeps that display list alive for as long as it lives,
  so a ping-pong retains every frame back to the first — and `dispose()`
  releases the Dart handle, not the chain. The spectrogram, phase scope and
  stereo cloud were all built this way and took the application to 266 GB
  before killing the raster thread with a 3,286-deep destructor recursion.
  There is no way to accumulate into a GPU surface from `dart:ui`: a module
  that needs history keeps the history as data, and either redraws it — with
  `PointBuckets` to keep the redraw to a few dozen calls — or renders it to an
  RGBA buffer uploaded whole as a pixel-backed `ImageDescriptor.raw` image each
  published frame, which holds bytes and no display list and replaces a
  predecessor disposed on the spot. The spectrogram takes the second route; its
  header says why the first one, budgeted on smooth columns, did not survive
  contact with real material.
- **Look at the module running before you call it done.** Five defects in the
  first eleven were invisible to `flutter analyze` and to the widget tests, and
  obvious within a second of seeing the app: a right-aligned paragraph offset by
  its own width (so every validator reading sat on top of the limit beside it),
  a target line drawn under the bars that hid it exactly when the programme was
  over target, two arcs whose gap was too small to read as two, a VU face whose
  labels overlapped into a smear, and two percentile labels printed in the same
  place on steady material. None of those are things a test would have been
  written to catch.
