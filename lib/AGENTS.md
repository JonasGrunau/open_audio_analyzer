# lib/

The application. GPL-3.0-or-later.

| Path | Purpose |
|------|---------|
| `main.dart` | Parses the command line, loads the configuration, `runApp(ProviderScope(...))`. Nothing else. |
| `src/app/` | The shell: window, the menu bar across the top and the status bar across the bottom, the keyboard shortcut table, and the launch options. See its own `AGENTS.md`. |
| `src/canvas/` | The grid canvas, the tab strip and the layout controller. See its own `AGENTS.md`. |
| `src/clock/` | `MeterClock` — the only `Ticker` in the app. |
| `src/data/` | Riverpod providers (configuration only), `metric_reader.dart`, `offline_job.dart`, and `mic_permission.dart` — the last being the microphone request Android needs before a capture device will open at all, and which no other platform needs because every other one grants capture through the act of opening one. Its absence is what made Android look display-only for a phase. |
| `src/modules/` | One file per meter module, all fourteen. Bodies only — the frame is the canvas's. |
| `src/panels/` | Settings, presets, the delivery-target editor, the skin editor, the report. See its own `AGENTS.md`. |
| `src/storage/` | Where configuration lives and how it is read and written. See its own `AGENTS.md`. |
| `src/remote/` | Both ends of the remote display — the desktop host and the tablet client — plus mDNS. See its own `AGENTS.md`. |
| `src/plugin/` | The listener the VST3 / AU plugin connects to, the transport it sends, and the scope that carries the link to the two controls offering it as a source. Loopback only. |

## Rules

- **Measurements never pass through Riverpod.** Providers hold configuration:
  things that change when a human does something. Routing a ~47 Hz stream of
  readings through one would rebuild the subtree under every meter forty-seven
  times a second to change numbers a painter could have read for free.
- **One clock.** Modules do not create tickers, timers or stream subscriptions.
  Independent tickers drift, and two meters showing the same quantity could then
  disagree within a single frame — a correctness bug, not a cosmetic one.
- **A module that keeps a record of time reads `MeterClock.measurements`, not
  `paint`.** `notifyListeners` is throttled to the user's fps setting, and the
  engine's snapshot is a seqlock with one slot — so at 30 fps against a 47 Hz
  publish rate, one measurement in three is gone before anybody looks at it.
  A module whose display is *per second* — the oscilloscope — loses the audio
  and draws holes. So does the spectrogram, for a reason that is easy to
  mistake for a merely coarser picture: its columns *are* its time axis, so a
  publish it was not painted for is a measurement the record never gets, and
  the rate it dates the ages by is measured off the columns it appended — which
  made it measure the **repaint** rate and label the same audio 30 Hz at 30 fps
  and 47 Hz at 60. A module whose display is a *shape* rather than an axis (the
  phase trail, the stereo cloud) genuinely does lose resolution and no more, and
  may still advance from paint. `measurements` fires on every tick that carried
  a new generation and marks nothing dirty; pixels still arrive at the rate that
  was asked for.
- **A module is `ModuleFrame` + a painter, and the painter takes
  `repaint: clock`.** That constructor argument is the whole render strategy: it
  re-rasters without rebuilding the widget. The module widget supplies the
  **body only**; `ModuleHost` wraps it in the frame, so the title, border, menu
  affordance and selection state are written once for all fourteen.
- **Every module painter extends `MeterPainter`, never `CustomPainter`
  directly.** `CustomPainter.hitTest` returns null and `RenderCustomPaint` reads
  that as *true*, so a plain painter silently swallows every pointer event that
  lands on the meter — and the canvas's drag and selection layers sit behind the
  module. The symptom is a meter that cannot be selected or dragged by its own
  face, with nothing reported anywhere. **A module that takes input on its face
  lays a translucent `Listener` over the part that does** — the spectrum
  analyser's cursor is the model — rather than overriding `hitTest`, so that
  the canvas's select-and-menu catcher behind it still sees the press. A
  `GestureDetector` there would enter the catcher's arena and win it, and a
  press that places a cursor would stop selecting the module. What such a
  module holds is dismissed by a press *away* from the module through a
  `TapRegion` in the module's `ModuleTapGroup`, and never by geometry of its
  own — see `lib/src/canvas/AGENTS.md`.
- **A module with a plot boxes it with `PlotBorder`, and draws inside
  `PlotBorder.inside`.** Six do: the spectrum analyser, the oscilloscope, the
  spectrogram, the histogram — twice, since its overview strip is a second
  picture — the loudness distribution and the stereo cloud. Each of them used
  to rule whichever one or two sides a scale happened to sit against, in
  whatever weight looked right there, which is four modules' worth of
  unfinished box. **The box goes around the picture and never over it**: the
  outermost pixel belongs to the border and the plot starts inside it, because
  on a rolling display — a spectrogram, a scope, the histogram — the right-hand
  edge is the newest measurement, which is exactly where the eye is.

- **A module's settings are menu rows, unless the setting is a number.** The
  canvas's menu is where a closed set of named choices belongs — a time base, a
  stereo arrangement, a metric — and thirteen of the fourteen modules have
  nothing else. The oscilloscope has two settings that are *values* over a wide
  range, its height and its trigger threshold, and both are chosen by looking at
  the picture while they move: a menu that closes over the waveform on every step
  cannot be used for that. They are `OaaSlider`s in a strip along the bottom of
  the module, written back through `ModuleHost.onOption`, and the threshold
  carries an `OaaCheck` — `AUTO`, which hands the level to the audio and is the
  one control in the strip that is not a value.
  **A third is a named choice and is still not a menu row**, which is the one
  exception to the rule above: the overlaid arrangement's legend, `L R` at the
  leading edge of the strip, and clicking it swaps which trace is drawn in front.
  It is here for the same reason the other two are — you choose it by looking at
  the picture — and it is a *control* rather than the caption it used to be
  because a legend painted into a meter's face is unreachable by pointer, by
  keyboard and by a screen reader: `MeterPainter` deliberately takes no hits.
  The strip's other end carries the span, right-aligned on the first row,
  because a number about the x axis reads better on the row under it than over
  the waveform it is describing — and it is flush with the body's right-hand
  edge, where that axis ends. **The corner grip's clearance is taken from
  controls only**: the grip's ticks are drawn in the frame's padding and it is
  its *touch* target that reaches into the body, so a slider must stop short of
  it and a label, which takes no gesture, must not.
  Four properties of that arrangement are not optional. The strip is **absent
  where `onOption` is null**, which is the remote display — the same signal
  `onMenu` already uses, and a control that cannot change anything is worse than
  no control. It is **dropped when the plot cannot spare the room**, like the
  graticule and the lane letters before it, and its two end cells go one step
  before the sliders do: a module too narrow for both hands the legend and the
  span back to the painter's corners, which is where they were drawn before
  there was a strip and where every remote display still draws them. Dropping a
  *control* to keep a caption is the one order that would be wrong. And a drag **reports continuously
  and commits once**: the undo history is a stack of whole workspaces and the
  autosave and every attached display watch the same provider, so a write per
  pointer event costs sixty history entries, sixty JSON encodings and sixty
  layout frames for one gesture. **A level that follows the audio never writes
  at all** — `AUTO` persists the checkbox and not the number, so the level it
  found is state in the module and is committed to the layout once, on the click
  that switches it off. The same arithmetic as a drag, with the publish rate in
  place of the pointer.
  A setting a mode makes inert is **greyed in the menu rather than dropped**:
  `Trigger` under `Sync: Tempo` and `Grid` under `Sync: Free` are the two, one
  the mirror of the other, and a row that vanishes is a row somebody hunts for
  while suspecting the wrong setting. `Time base` and `Division` are the
  exception and not a third case — they are one setting spelled in whichever
  unit the sync makes meaningful, so only one of them is ever a row.
  The two controls stand **side by side, one `Space.md` apart**, and each cell
  in a control is cut to what *that* control needs rather than to the widest in
  the strip. What makes two sliders agree is the track length, which is one
  number handed to both; padding the shorter label and the shorter readout out
  to the longer ones does not align anything, it just moves 85 px of nothing
  into the gutter between the pair — which is where it was, and which read as
  one control at each end of the module rather than as a strip of two.
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
  Those are the same size in all fourteen modules, and scaling them is how fourteen
  modules end up with fourteen type scales.
- **A module never guards its own minimum size.** Declare it as
  `minBodyWidth`/`minBodyHeight` on `ModuleKind` and let the frame substitute
  the placeholder. A painter that returns early draws nothing, and nothing with
  a title bar over it is a panel the user reads as broken rather than as small.
- **A display whose picture would be a tautology names the reason instead.**
  The engine copies channel 0 into the right slot of the scope and reports every
  spectrum band at dead centre when there is only one channel — both are true and
  both are documented in `docs/METRICS.md` — but *drawing* them gives the Phase
  Scope a hard vertical line that never moves and the Stereo Cloud a bright
  column down the middle of its face, and a display that cannot change is read as
  one that has stuck. The cloud's version was reported as a broken module. Both
  say **MONO SOURCE** across the middle now, keep their graticule drawn, and
  break the guides around the words rather than striking through them. The phase
  scope's correlation and balance markers go with the scatter — withheld,
  because a marker pinned at the mono end of its edge is the same tautology one
  stroke over — while the *numbers* stay measured and available in a Number Box. Not the
  `ModuleTooSmall` placeholder and not an em dash: the module is not
  unavailable, it is showing everything a one-channel signal has.
- **A module that stops plotting has to keep ageing what it has already
  plotted.** The two above accumulate, so *not writing* is not the same as
  writing nothing: a trail that simply stopped being filled would hold the last
  stereo frame at full brightness for the rest of the session — a Lissajous
  figure of audio that is no longer playing. The cloud's fade runs anyway and the
  scope's ring is advanced with `blank()` frames, so switching to a mono input
  dissolves what was there over the display's own length.
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
