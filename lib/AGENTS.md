# lib/

The application. GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `main.dart` | Parses the command line, loads the configuration, `runApp(ProviderScope(...))`. Nothing else. |
| `src/app/` | The shell: window, status bar, the keyboard shortcut table, and the launch options. See its own `AGENTS.md`. |
| `src/canvas/` | The grid canvas, the tab strip and the layout controller. See its own `AGENTS.md`. |
| `src/clock/` | `MeterClock` — the only `Ticker` in the app. |
| `src/data/` | Riverpod providers (configuration only) and `metric_reader.dart`. |
| `src/modules/` | One file per meter module, all twelve. Bodies only — the frame is the canvas's. |
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
  affordance and selection state are written once for all twelve.
- **Every module painter extends `MeterPainter`, never `CustomPainter`
  directly.** `CustomPainter.hitTest` returns null and `RenderCustomPaint` reads
  that as *true*, so a plain painter silently swallows every pointer event that
  lands on the meter — and the canvas's drag and selection layers sit behind the
  module. The symptom is a meter that cannot be selected or dragged by its own
  face, with nothing reported anywhere.
- **`metric_reader.dart` is the only place `bel_core` meets `bel_engine`.**
  There is now a second implementation of the same signature backed by the wire
  protocol — `WireSnapshot`, in `bel_wire` — and every module works unchanged
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
- **A module that accumulates advances on `engine.generation`, never on
  `paint`.** Paint also runs on a resize, a theme change, or an ancestor marking
  the subtree dirty. A spectrogram that scrolled on those would invent time that
  no audio passed through, and it would look completely plausible.
- **Anything from `toImageSync` holds a GPU texture and must be disposed.** The
  garbage collector sees a small handle and feels no pressure, so a layer
  dropped per frame leaks video memory on a machine reporting plenty free. Use
  `PersistenceLayer`, which owns both the ping-pong and the disposal, and call
  its `dispose` from `State.dispose`.
- **Look at the module running before you call it done.** Five defects in the
  first eleven were invisible to `flutter analyze` and to the widget tests, and
  obvious within a second of seeing the app: a right-aligned paragraph offset by
  its own width (so every validator reading sat on top of the limit beside it),
  a target line drawn under the bars that hid it exactly when the programme was
  over target, two arcs whose gap was too small to read as two, a VU face whose
  labels overlapped into a smear, and two percentile labels printed in the same
  place on steady material. None of those are things a test would have been
  written to catch.
