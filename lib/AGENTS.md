# lib/

The application. GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `main.dart` | `runApp(ProviderScope(...))` and nothing else. |
| `src/app/` | The shell: window, status bar, canvas. |
| `src/clock/` | `MeterClock` — the only `Ticker` in the app. |
| `src/data/` | Riverpod providers (configuration only) and `metric_reader.dart`. |
| `src/modules/` | One file per meter module. |

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
  re-rasters without rebuilding the widget.
- **`metric_reader.dart` is the only place `bel_core` meets `bel_engine`.**
  Phase 6 adds a second implementation of the same signature backed by the wire
  protocol, and every module keeps working unchanged. Keep that seam narrow.
- **Nothing allocates inside `paint()`** — no `Paint`, `Path`, `TextPainter`,
  list or string concatenation. Cache in the `State`.
