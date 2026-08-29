// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Loudness against time: how the programme moved, and when it was over target.
///
/// Decibel's name, which is a misnomer in both products and is kept anyway —
/// `ModuleKind.histogram` is written into every saved preset, and a module that
/// renames itself is a layout that stops loading. What it actually draws is a
/// time series, which is what it was specified as from the start.
///
/// Two stacked bands share one axis:
///
///   - **the filled area is short-term loudness**, the 3 s window, which is the
///     reading that answers "how loud is this section";
///   - **the band above it reaches momentary loudness**, the 400 ms window,
///     drawn only where it runs above the short-term line.
///
/// The gap between them is the useful part. A wide band is a section whose
/// transients are far above its body, and a band that collapses to nothing is
/// one that has been flattened — which is a mastering decision you can watch
/// happening rather than infer from two numbers that moved.
///
/// **The band is drawn at a weight you can actually see.** It shipped at 0.05
/// to 0.26 alpha against a fill that reaches 0.85, on the argument that the
/// band is context rather than a second reading — and at that weight the gap,
/// which is the whole reading, was invisible on a real programme. It is a wash
/// now, not a whisper: the same alpha ramp, held back rather than extinguished.
/// The short-term edge is still the strongest line on the module and still the
/// thing the eye lands on, which is what that argument was actually protecting.
///
/// Colour is the target and nothing else, said twice in two registers. The
/// filled area under the calibration's LUFS target is the accent, everything
/// over it [OaaColors.over], and that split is a clip rather than a per-column
/// verdict: it is the *area* over the line that carries the meaning, and a
/// column that straddles the target has no single verdict to be coloured by.
/// The momentary band above the area is the per-column register: each column's
/// band is tinted from the accent towards [OaaColors.over] by how far that
/// column's momentary reading stood over the target, so a section whose
/// transients were flirting with the limit reddens as a shape even while its
/// body stays under the line.
///
/// [OaaColors.over] is the application's one mark for "past the number you set",
/// and every module that draws against the delivery target uses it: the bars
/// of the LUFS Meter, the arcs of the Super Meter, this, and the Loudness
/// Distribution. The target line itself is drawn in the same colour — dashed,
/// with its value printed on the axis beside it, so the one line the user
/// chose cannot be mistaken for one the signal drew.
///
/// ---------------------------------------------------------------------------
/// Not to be confused with the Loudness Distribution
///
/// This module used to draw the 120-bin gated distribution behind LRA. That is
/// a good chart and it is not this one, so it is its own module now — see
/// `loudness_distribution.dart`. The pair are the same measurement asked two
/// questions: *when* was the programme loud, and *how often* was it. They share
/// the target split and the palette on purpose and do not share a scale.
///
/// ---------------------------------------------------------------------------
/// Why the history is kept here, at twenty columns a second
///
/// The engine publishes an instant, not a past, so a time series has to be
/// accumulated by whatever draws it. The engine publishes at about 47 Hz, so
/// two or three publishes are folded into each 50 ms column — the *latest*
/// short-term reading, because a 3 s window barely moves in 50 ms, and the
/// *loudest* momentary, because that band is a statement about what the fast
/// meter reached and a mean would erase exactly the transient it exists to
/// show.
///
/// It was 100 ms a column until the plot could be zoomed. A column is the
/// finest thing the module can ever show, so it is also the floor on what
/// zooming in can reveal: at 100 ms, magnifying a phrase drew a staircase of
/// ten steps a second and no more detail than the unzoomed plot had. 50 ms is
/// half of the shortest window either band measures over, which is the point
/// past which a finer column would be storing the same measurement twice.
///
/// The ring is a fixed 8192 columns — about seven minutes — and it is sized in
/// **columns of measurement, never in pixels**. That is the one thing the
/// spectrogram cannot do: it stores runs in pixel rows, so a resize costs it
/// its whole history. Loudness is resolution-free, so this survives a resize,
/// and the module can be dragged from a corner to full screen without the
/// programme so far disappearing.
///
/// ---------------------------------------------------------------------------
/// The overview strip is the scrollbar, and the plot is a window over the ring
///
/// The **overview strip** along the bottom shows the whole ring at once, with a
/// frame over the slice the plot is showing. It is a map, not a second meter:
/// the whole recorded programme compressed to the strip's width, each pixel
/// taking the loudest column it covers — the same choice, for the same reason,
/// that the engine makes mapping transform bins into spectrum bands, because a
/// mean at a coarser resolution hides exactly the spike worth scrolling back
/// for.
///
/// That frame is a handle. **Drag it and the plot scrolls back through the
/// programme; scroll, pinch or wheel over the strip and the frame changes
/// size**, which is the plot's zoom. Both are view state and neither touches the ring: the
/// module keeps recording at the same rate into the same columns while you are
/// looking at a chorus four minutes ago, and dragging the frame back against
/// the right-hand edge re-attaches it to the newest column.
///
/// The window is held as the **absolute index of its newest visible column**,
/// not as an age. An age would have to be advanced by hand every time a column
/// closed, and a view that forgot to would slide backwards through the
/// programme at twenty columns a second while its user was reading it. An index
/// simply stays where it was put, and *following* is the one case that needs a
/// rule: the anchor tracks the newest column while the frame is against the
/// right edge and stops the moment it is dragged off it.
///
/// **A pixel may cover more than one column, and the two bands fold
/// differently.** Zoomed out far enough that the window is wider than the plot,
/// a pixel's short-term is the *mean* of the columns it covers and its
/// momentary is the *loudest* — the same split, for the same reason, that
/// [_LoudnessHistory.accumulate] makes folding publishes into columns. A level
/// averaged over the span it is drawn across is honest; a maximum averaged with
/// its neighbours is the transient thrown away twice.
///
/// Nothing here accumulates into an image. See the header of `spectrogram.dart`
/// for what that costs — the short version is 266 GB and a dead raster thread.
/// The whole visible history is redrawn every frame out of buffers allocated on
/// resize: the area and its outline from one buffer each, the band through
/// [PointBuckets] — a `drawRawPoints` per tint actually on screen.
///
/// ---------------------------------------------------------------------------
/// Smoothing happens on the way out of the ring, never on the way in
///
/// The ring holds what was measured. [HistogramSmoothing] is applied when the
/// columns are read, every frame, which is what makes the setting a *view*: it
/// redraws the whole programme so far rather than taking effect from the moment
/// it was chosen, and `Off` is the measured columns byte for byte. A smoother
/// applied in [_LoudnessHistory.accumulate] would be cheaper and would leave a
/// module whose history was drawn under two different settings at once.
///
/// **Both bands take the same window.** Smoothing the momentary and not the
/// short-term — or the reverse — would make the *gap* between them a difference
/// between two filters rather than a difference between two measurements, and
/// the gap is the whole reading.
///
/// One consequence worth stating: the colour split is a clip at the target
/// applied to the drawn geometry, so at any setting but `Off` the coloured area
/// is the area of the *smoothed* curve over the target. The area is being read
/// as a shape rather than counted in columns, which is what the split was for.
class HistogramModule extends StatefulWidget {
  const HistogramModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    this.smoothing = HistogramSmoothing.normal,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  /// How much the two bands are averaged over before they are drawn. See
  /// [HistogramSmoothing].
  final HistogramSmoothing smoothing;

  /// The overview strip's height inside a module [height] tall, and zero where
  /// there is no room for one — a strip on a module too short to keep a plot
  /// above it would be a map of a territory that is not shown.
  static double overviewHeight(double height) =>
      height > 120 ? (height * 0.12).clamp(16.0, 28.0) : 0.0;

  /// Clear space between the plot's floor and the top of the overview strip.
  ///
  /// Wider than the [Space.xs] it shipped as. The strip is a *different
  /// picture* of the programme, at a different scale, and four pixels below the
  /// plot read as the plot's own bottom margin — so the resting line of one and
  /// the border of the other sat close enough to be taken for a single piece of
  /// furniture. It is the body's own inset now, which is the gap between
  /// unrelated things everywhere else on a module.
  static const double overviewGap = Space.smd;

  /// The bottom of the plot inside a module [height] tall — the strip and the
  /// gap above it, taken off.
  ///
  /// Public because the tests anchor their pixel reads to it; a second copy of
  /// this arithmetic in the test is a copy that silently stops describing the
  /// module.
  static double plotFloor(double height) {
    final overview = overviewHeight(height);
    return height - (overview > 0 ? overview + overviewGap : 0);
  }

  @override
  State<HistogramModule> createState() => _HistogramModuleState();
}

/// One column per 50 ms of measured signal, or 20 Hz. Half the shortest window
/// either band measures over — see the class comment.
const double _secondsPerColumn = 0.05;

/// Columns retained regardless of how small the module is. 8192 of them is
/// 6m 50s, and two `Float32List`s of it is 64 KB.
const int _capacity = 8192;

/// The narrowest window the plot may be zoomed to, in columns. Five seconds:
/// past that the two bands are being read as one transient rather than as a
/// programme, and there are meters on the canvas for that.
const int _minSpan = 100;

/// The tick intervals the time axis may use, in seconds.
///
/// The short rungs exist for a zoomed-in plot and only for one: which rung is
/// chosen is decided against the *measured* spacing in pixels, so a 1 s tick is
/// unreachable at any zoom that would crowd it and is simply never picked.
const _timeLadder = <int>[1, 2, 5, 10, 15, 30, 60, 120, 300];

/// The most ticks the axis carries, however wide the module gets. Without a cap
/// a full-width module on a large display draws two dozen of them and the axis
/// becomes a line of text.
const _maxTimeTicks = 8;

/// How many tints the momentary band is quantised into. Enough that the ramp
/// from accent to over reads as continuous; few enough that a frame is a
/// handful of `drawRawPoints` calls.
const int _bandTints = 8;

/// How far over the target a column's momentary reading has to stand, in LU,
/// to reach the last tint. 12 LU is the span a limiter argument actually
/// happens in; past that the band is simply red.
const double _bandTintSpan = 12;

/// "45s", "1m15s", "1h20m" — how far into the programme a tick's column is.
///
/// Two units at most and never a zero one, which is what keeps the axis a row
/// of short labels rather than a row of timestamps. The seconds are dropped
/// past an hour: at that distance the interval between ticks is minutes and a
/// trailing "07s" is precision about a gridline nobody placed.
String _elapsedText(double seconds) {
  final total = seconds.round();
  final hours = total ~/ 3600;
  final minutes = total % 3600 ~/ 60;
  final rest = total % 60;
  if (hours > 0) return minutes == 0 ? '${hours}h' : '${hours}h${minutes}m';
  if (minutes > 0) return rest == 0 ? '${minutes}m' : '${minutes}m${rest}s';
  return '${rest}s';
}

class _HistogramModuleState extends State<HistogramModule> {
  /// The same tapered scale every level meter draws, reaching a little above
  /// zero because momentary loudness legitimately does. Three modules showing
  /// loudness on one tab against three different mappings is the defect
  /// `MeterScale` exists to prevent; −∞ at the plot's floor comes with it.
  static const _scale = MeterScale.tapered(
    max: 3,
    ticks: [3, 0, -3, -6, -9, -12, -18, -24, -30, -40],
  );

  final _history = _LoudnessHistory();
  final _targetValue = ValueParagraph();

  ScaleGraticule? _graticule;
  ui.Paragraph? _unit;

  /// One cached paragraph per tick of the time axis. The ticks are pinned to
  /// the programme rather than to the right-hand edge, so they slide leftwards
  /// as it plays and the string at a given index changes every time one leaves
  /// the plot; [ValueParagraph] is what keeps that from being a paragraph
  /// layout per frame. One longer than [_maxTimeTicks], because the cap is on
  /// the gaps between ticks and there is a tick at each end of them.
  final List<ValueParagraph> _timeValues = List.generate(
    _maxTimeTicks + 1,
    (_) => ValueParagraph(),
  );
  double _widestTimeLabel = 0;

  /// Generation 0 is "nothing has been measured yet" rather than a measurement
  /// that happens to be zero — see the same field on the spectrogram.
  int lastGeneration = 0;

  // --- The window the plot is showing ---------------------------------------

  /// Columns the plot's window covers, or zero for "one column per pixel" —
  /// what the module does until somebody zooms it, and what makes a wider
  /// module show more of the programme rather than the same slice larger.
  int _span = 0;

  /// Absolute index of the newest visible column, counting from the first
  /// column written since the last reset. See the class comment for why this is
  /// an index and not an age.
  int _anchor = 0;

  /// Whether [_anchor] tracks the newest column there is. True until the strip
  /// is dragged off the right-hand edge, and true again as soon as it is
  /// dragged back against it.
  bool _following = true;

  /// The span and the strip's own mapping, as the last frame resolved them.
  /// Written by the painter and read by the strip's gestures, which have to
  /// turn a pointer's pixels into columns and cannot recompute either without
  /// the plot's width.
  int _spanShown = _minSpan;
  int _overviewColumns = 1;

  /// Columns a drag has moved that have not been spent yet. A drag delivers
  /// fractions of a column at a time and [_anchor] is an integer; rounding each
  /// delta on its own loses the whole gesture on a zoomed-out strip, where one
  /// pixel is several columns and every delta rounds to zero.
  double _dragColumns = 0;

  // --- Buffers, allocated on resize and never on a frame --------------------

  Float32List _shortBars = Float32List(0);
  Float32List _curve = Float32List(0);
  Float32List _dashes = Float32List(0);

  /// The momentary band's segments, sorted by tint. Buffers grow to the widest
  /// frame and are then reused — see [PointBuckets].
  final _bands = PointBuckets(_bandTints);

  /// The two bands as they are drawn — the window's columns through the
  /// smoothing window, newest first. Sized to the ring rather than to the plot,
  /// because a zoomed-out window is wider than the module is.
  final Float32List _shortShown = Float32List(_capacity);
  final Float32List _momentaryShown = Float32List(_capacity);
  int _builtPixels = -1;

  /// The whole ring, read raw for the overview strip, and the strip's own
  /// polyline. The ring buffer is fixed-size and allocated once; the polyline
  /// follows the strip's width.
  final Float32List _overviewShown = Float32List(_capacity);
  Float32List _overview = Float32List(0);
  int _overviewPixels = -1;

  void _ensurePixels(int pixels) {
    if (pixels == _builtPixels) return;
    _builtPixels = pixels;
    _shortBars = Float32List(pixels * 4);
    _curve = Float32List(pixels * 2);
    _dashes = Float32List((pixels / _dashPeriod).ceil() * 4);
  }

  /// Settles the window over the ring for this frame and returns its span in
  /// columns. Clamps [_anchor] into what the ring still holds, which is what
  /// makes a reset — where the ring empties under a view scrolled back into it
  /// — re-attach to the newest column instead of drawing an empty plot.
  int _resolveWindow(int pixels, _LoudnessHistory history) {
    final span = _span == 0 ? pixels : _span;
    final written = history.written;
    if (_following || _anchor > written - 1) _anchor = written - 1;
    // The oldest column the ring still holds, and the oldest the window's left
    // edge may reach without running off the end of it.
    final oldest = written - history.filled;
    final floor = math.min(written - 1, oldest + span - 1);
    if (_anchor < floor) _anchor = floor;
    _spanShown = span;
    return span;
  }

  // --- The overview strip's gestures ----------------------------------------

  /// Moves the window by [dx] pixels of the strip. Right is newer.
  void _panBy(double dx, double stripWidth) {
    if (stripWidth <= 0) return;
    _dragColumns += dx * _overviewColumns / stripWidth;
    final whole = _dragColumns.truncate();
    if (whole == 0) return;
    _dragColumns -= whole;
    setState(() {
      _anchor += whole;
      _following = _anchor >= _history.written - 1;
    });
  }

  /// Changes how much of the programme the plot shows. [dy] is a scroll
  /// delta — down widens the window, which is zooming out.
  ///
  /// Multiplicative, so a notch covers the same *proportion* of the window at
  /// every zoom: additive columns would crawl at a seven-minute span and jump
  /// the whole window at a five-second one. The newest visible column is the
  /// anchor either way, so the right-hand edge of the plot holds still.
  void _zoomBy(double dy) => _zoomTo(_spanShown * math.pow(1.0025, dy));

  /// The window a pinch began at. A trackpad reports a pinch's `scale`
  /// cumulatively from where the gesture started, so it has to be applied to
  /// the span the fingers went down on and not to the current one — compounding
  /// it frame by frame squares it, and the plot arrives at its stop in three
  /// updates.
  int _pinchSpan = _minSpan;

  void _pinchStart() => _pinchSpan = _spanShown;

  void _pinchTo(double scale) {
    if (scale > 0) _zoomTo(_pinchSpan / scale);
  }

  void _zoomTo(num span) {
    final next = span.round().clamp(_minSpan, _capacity);
    if (next == _spanShown) return;
    setState(() => _span = next);
  }

  // --- The fills, and the gradients they share -------------------------------

  Paint? _fillUnder;
  Paint? _fillOver;
  List<Paint> _bandPaints = const [];
  Rect? _shadedPlot;
  OaaColors? _shadedColors;

  /// Bright along the top edge and nearly gone at the floor, which is what
  /// stops a filled area reading as a block of paint and lets the shape of the
  /// curve carry the information. The ramp runs in hue as well as in alpha —
  /// towards [OaaColors.textPrimary] at the reading, towards the background at
  /// the floor, the same recipe as `MeterFill` — so the brightest paint on the
  /// module is the edge that *is* the measurement. Same trick as the spectrum
  /// analyser: a shader on the `Paint` is evaluated in canvas space, so a
  /// thousand butt-capped vertical strokes drawn through it produce exactly the
  /// gradient one filled `Path` would — without the path.
  void _ensureFills(Rect plot, OaaColors colors) {
    if (_shadedPlot == plot && _shadedColors == colors) return;
    _shadedPlot = plot;
    _shadedColors = colors;

    Paint fill(List<Color> ramp, List<double> stops) => Paint()
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = _HistogramPainter.columnWidth
      // The columns are one pixel wide and tile the plot exactly, so there is
      // no edge for antialiasing to soften — only cost. Widening them to
      // overlap instead, the way the spectrum analyser's wider bands are, would
      // blend each column's alpha into its neighbour twice and stripe the fill.
      ..isAntiAlias = false
      ..shader = ui.Gradient.linear(
        plot.topCenter,
        plot.bottomCenter,
        ramp,
        stops,
      );

    Paint area(Color base) => fill(
      <Color>[
        Color.lerp(base, colors.textPrimary, 0.35)!.withValues(alpha: 0.85),
        base.withValues(alpha: 0.45),
        Color.lerp(base, colors.background, 0.40)!.withValues(alpha: 0.14),
      ],
      const [0.0, 0.35, 1.0],
    );

    _fillUnder = area(colors.accent);
    _fillOver = area(colors.over);

    // The momentary band is the same alpha ramp held back. It is context for
    // the short-term line, not a second reading, and at equal weight the eye
    // reads the *top* of the band as the measurement — which is the fast meter,
    // the one a loudness display exists to look past. One paint per tint of the
    // accent-to-over ramp; which tint a column takes is decided when its
    // segment is bucketed, not here.
    //
    // Held back is not extinguished, and the first attempt was: 0.26 fading to
    // 0.05 across the plot, under a fill that reaches 0.85, put the band below
    // the noise floor of the display it was drawn on. The ramp is shallow now
    // as well as stronger — the band is a *short* segment sitting at whatever
    // height the programme put it, so a steep canvas-space gradient does not
    // shade the band, it decides whether a quiet passage has one at all.
    _bandPaints = [
      for (var tint = 0; tint < _bandTints; tint++)
        fill(
          <Color>[
            Color.lerp(
              colors.accent,
              colors.over,
              tint / (_bandTints - 1),
            )!.withValues(alpha: 0.52),
            Color.lerp(
              colors.accent,
              colors.over,
              tint / (_bandTints - 1),
            )!.withValues(alpha: 0.28),
          ],
          const [0.0, 1.0],
        ),
    ];
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _targetValue.dispose();
    for (final value in _timeValues) {
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(
          _scale,
          ScaleSide.left,
          colors.textFaint,
          avoiding: widget.calibration.lufsTarget,
        )) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
        // The target's own number is printed on the axis in its own colour;
        // ticks whose labels would collide with it give way — the annotation
        // yields to the scale everywhere else, but the target is the one
        // number the user chose, and a scale you can still count in threes
        // survives a missing tick where a target you cannot find does not.
        avoid: widget.calibration.lufsTarget,
      );

      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _unit = layoutParagraph('LUFS', style);
      // Measured once from the widest string [_elapsedText] can produce; the
      // live labels are laid out into [_timeValues] as they change.
      _widestTimeLabel = layoutParagraph('88m88s', style).longestLine;
    }

    final body = MeterBody(
      painter: _HistogramPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        graticule: _graticule!,
        history: _history,
        smoothing: widget.smoothing,
        state: this,
        repaint: widget.clock,
      ),
    );

    // The strip's handle is the one place on this module that takes input, and
    // it is laid over the strip rather than around the whole body on purpose:
    // the canvas puts a module's select, drag and context-menu affordances
    // *behind* it, so every pixel a module claims is a pixel the canvas loses.
    // A `LayoutBuilder` rather than a fraction of the body, because the strip's
    // height is not linear in the module's — see [HistogramModule.overviewHeight]
    // — and because the strip's own width is what a drag has to be measured in.
    return LayoutBuilder(
      builder: (context, constraints) {
        final overview = HistogramModule.overviewHeight(constraints.maxHeight);
        if (overview <= 0) return body;
        return Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: overview,
              child: _OverviewHandle(
                width: constraints.maxWidth,
                onPanStart: () => _dragColumns = 0,
                onPan: _panBy,
                onZoom: _zoomBy,
                onPinchStart: _pinchStart,
                onPinch: _pinchTo,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The overview strip, as something you can grab.
///
/// Nothing is drawn here — the strip and the frame over it are the painter's,
/// and a widget that redrew either would be a second opinion about where the
/// window is. This is the hit target and the two gestures over it.
class _OverviewHandle extends StatelessWidget {
  const _OverviewHandle({
    required this.width,
    required this.onPanStart,
    required this.onPan,
    required this.onZoom,
    required this.onPinchStart,
    required this.onPinch,
  });

  final double width;
  final VoidCallback onPanStart;
  final void Function(double dx, double stripWidth) onPan;
  final void Function(double dy) onZoom;
  final VoidCallback onPinchStart;
  final void Function(double scale) onPinch;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Listener(
        // **A trackpad does not send a scroll event, and neither does a Magic
        // Mouse.** macOS marks a scroll that came off a touch surface with a
        // phase, and Flutter turns those into pan-zoom events instead — so a
        // [PointerScrollEvent] arrives from a click-wheel mouse and from
        // nothing else on this platform. Wiring the signal alone left the zoom
        // working on hardware most of the people using this do not own, which
        // is indistinguishable from it not being wired at all.
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) onZoom(event.scrollDelta.dy);
        },
        onPointerPanZoomStart: (_) => onPinchStart(),
        onPointerPanZoomUpdate: (event) {
          // A pinch and a two-finger scroll arrive down the same channel and
          // are told apart by which field moved. `scale` is cumulative over the
          // gesture and `panDelta` is not, which is why they are handled by two
          // different calls rather than one.
          if (event.scale != 1.0) {
            onPinch(event.scale);
          } else {
            // Negated: `panDelta` follows the fingers, where `scrollDelta`
            // opposes them. Both directions then mean the same thing, which is
            // the only way one module can be zoomed by both.
            onZoom(-event.panDelta.dy);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Or the window trails the pointer by the drag slop for the whole
          // gesture — the same reason the canvas's own handles set it.
          dragStartBehavior: DragStartBehavior.down,
          // Or a two-finger gesture over the strip scrolls the plot, including
          // the one macOS sends as a right click. See [kDragDevices].
          supportedDevices: kDragDevices,
          onHorizontalDragStart: (_) => onPanStart(),
          onHorizontalDragUpdate: (details) => onPan(details.delta.dx, width),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The programme so far, as columns of loudness.
///
/// A ring of [_capacity] columns holding the short-term and momentary readings
/// for each 100 ms of measured signal, newest last.
class _LoudnessHistory {
  final Float32List _short = Float32List(_capacity);
  final Float32List _momentary = Float32List(_capacity);

  int _next = 0;

  /// How many columns of the ring hold audio. Never more than [_capacity].
  int filled = 0;

  /// How many columns have been closed since the last [clear], including the
  /// ones that have already scrolled out of the ring. The view's anchor is an
  /// index into this rather than an age — see the class comment — so it has to
  /// keep counting past [_capacity].
  int written = 0;

  /// The elapsed second column zero begins at. Zero for a programme played
  /// from its start, and *not* zero for one that fell so far behind that the
  /// ring was resynchronised — see [accumulate]. The time axis is labelled from
  /// this, so a ring that forgot it would print an elapsed time the transport
  /// never showed.
  double origin = 0;

  /// The column being accumulated, and the elapsed second it closes at.
  double _shortAcc = double.nan;
  double _momentaryAcc = double.nan;
  double _boundary = _secondsPerColumn;
  double _lastElapsed = 0;

  void clear() {
    _next = 0;
    filled = 0;
    written = 0;
    origin = 0;
    _shortAcc = double.nan;
    _momentaryAcc = double.nan;
    _boundary = _secondsPerColumn;
    _lastElapsed = 0;
  }

  /// Folds one published measurement into the current column, closing columns
  /// as [elapsed] crosses their boundaries.
  ///
  /// Driven by *seconds of signal measured* rather than by wall-clock time or
  /// by a count of publishes. A stopped engine then holds the display still
  /// instead of scrolling silence across it, and a file analysed offline — where
  /// four minutes of audio go through in seconds — lays its columns out at the
  /// rate the audio actually had rather than at the rate the loop managed.
  void accumulate(double short, double momentary, double elapsed) {
    // A reset restarts the clock. Without this the new programme is drawn onto
    // the end of the old one, which reads as one continuous take.
    if (elapsed < _lastElapsed) clear();
    _lastElapsed = elapsed;

    // Further behind than the ring can hold: everything stored would scroll off
    // before the loop finished writing it. Resynchronise instead of spending
    // the frame committing columns nobody will see.
    if (elapsed - _boundary > _capacity * _secondsPerColumn) {
      clear();
      _boundary = elapsed + _secondsPerColumn;
      origin = elapsed;
    }

    _shortAcc = short;
    if (!momentary.isNaN &&
        (_momentaryAcc.isNaN || momentary > _momentaryAcc)) {
      _momentaryAcc = momentary;
    }

    while (elapsed >= _boundary) {
      _short[_next] = _shortAcc;
      _momentary[_next] = _momentaryAcc;
      _next = (_next + 1) % _capacity;
      written++;
      if (filled < _capacity) filled++;
      // Short-term carries into the next column — it is a level, and the level
      // did not stop existing. Momentary does not: it is a maximum *over the
      // column*, and carrying it would smear one transient across the rest of
      // the display.
      _momentaryAcc = double.nan;
      _boundary += _secondsPerColumn;
    }
  }

  /// Age 0 is the newest column.
  int _slot(int age) => (_next - 1 - age + _capacity * 2) % _capacity;

  /// The elapsed second the column at absolute [index] begins at.
  double secondsAt(int index) => origin + index * _secondsPerColumn;

  /// [count] short-term columns from age [from], each averaged over ±[radius].
  void shortInto(Float32List out, int from, int count, int radius) =>
      _average(_short, out, from, count, radius);

  /// [count] momentary columns from age [from], each averaged over ±[radius].
  void momentaryInto(Float32List out, int from, int count, int radius) =>
      _average(_momentary, out, from, count, radius);

  /// Fills `out[0..count)` with a centred mean of [source] over ±[radius]
  /// columns, for ages [from] to `from + count - 1`, newest first.
  ///
  /// Two pointers over one running sum, so the cost is the number of columns
  /// drawn and not that times the window — a wide module at the broadest
  /// setting would otherwise be thirty thousand adds a frame for a picture
  /// nobody could tell from this one. Nothing is allocated: both buffers belong
  /// to the state and are sized on resize.
  ///
  /// Three rules the arithmetic has to keep:
  ///
  ///   - **NaN is skipped, not averaged in.** A column with no momentary
  ///     reading in it is a column the source did not measure momentary for,
  ///     and it counts towards neither the sum nor the divisor. A window with
  ///     nothing finite in it stays NaN, so a source that measures no momentary
  ///     at all still draws no band rather than a band at zero.
  ///   - **The window may reach past what is drawn**, as far as [filled]. The
  ///     oldest visible column is averaged against history that has already
  ///     scrolled off the left edge, so widening the module reveals more of the
  ///     programme instead of changing the columns already on screen.
  ///   - **A radius of zero copies.** `Off` has to be the measured columns
  ///     exactly, not a one-tap filter that rounds like one.
  void _average(
    Float32List source,
    Float32List out,
    int from,
    int count,
    int radius,
  ) {
    if (count <= 0) return;
    if (radius == 0) {
      for (var i = 0; i < count; i++) {
        out[i] = source[_slot(from + i)];
      }
      return;
    }

    var sum = 0.0;
    var finite = 0;

    // The window over ages [low, high], both inclusive and both monotonic in
    // age, which is what lets one pass do it. `high` starts one short of the
    // first window so that the loop's own advance fills it.
    var low = math.max(0, from - radius);
    var high = low - 1;

    for (var i = 0; i < count; i++) {
      final age = from + i;
      final wanted = age + radius >= filled ? filled - 1 : age + radius;
      while (high < wanted) {
        high++;
        final value = source[_slot(high)];
        if (!value.isNaN) {
          sum += value;
          finite++;
        }
      }
      final oldest = age - radius;
      while (low < oldest) {
        final value = source[_slot(low)];
        if (!value.isNaN) {
          sum -= value;
          finite--;
        }
        low++;
      }
      out[i] = finite == 0 ? double.nan : sum / finite;
    }
  }
}

/// Dash geometry for the target line: four pixels on, four off.
const double _dashOn = 4;
const double _dashPeriod = 8;

class _HistogramPainter extends MeterPainter {
  _HistogramPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.history,
    required this.smoothing,
    required this.state,
    required Listenable repaint,
  }) : _curve = (Paint()
         // The same colour the spectrum analyser strokes its curve in, over the
         // same translucent fill: opaque accent against a fill that reaches
         // 0.85 of it reads as an edge without becoming a second object. The
         // reading colour was tried here and is too loud — a white line over a
         // filled area is the first thing the eye lands on, and on this module
         // the thing worth landing on is where the area crosses the target.
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       // The same edge past the target, in [OaaColors.over]. The fill under it
       // already splits there; an outline that did not would run one colour
       // straight through the boundary and read as the line the eye lands on
       // *disagreeing* with the area it bounds. The Loudness Distribution has
       // split its own silhouette this way from the start — see `_edgeOver`.
       _curveOver = (Paint()
         ..color = colors.over
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       // Dashed, so that the one line on the display the user chose cannot be
       // mistaken for one the signal drew — and in [OaaColors.over], because
       // the target is the limit itself and the readings past it are drawn in
       // the same statement's colour.
       _target = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.butt
         ..isAntiAlias = false),
       _overviewFill = (Paint()..color = colors.panelRaised),
       // The overview's trace is the accent held back: it is the same
       // measurement as the plot above it, at a size where it is a map rather
       // than a meter.
       _overviewLine = (Paint()
         ..color = colors.accent.withValues(alpha: 0.60)
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _window = (Paint()
         ..color = colors.hairlineStrong
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _windowFill = (Paint()
         ..color = colors.hairlineStrong.withValues(alpha: 0.10)
         ..isAntiAlias = false),
       _tickStyle = OaaType.tick.copyWith(color: colors.textFaint),
       _targetStyle = OaaType.tick.copyWith(color: colors.over),
       _border = PlotBorder(colors),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final _LoudnessHistory history;
  final HistogramSmoothing smoothing;
  final _HistogramModuleState state;

  final Paint _curve;
  final Paint _curveOver;
  final Paint _grid;
  final Paint _target;
  final Paint _overviewFill;
  final Paint _overviewLine;
  final Paint _window;
  final Paint _windowFill;
  final TextStyle _tickStyle;
  final TextStyle _targetStyle;

  /// Drawn twice: around the plot, and around the overview strip. The strip is
  /// a second picture of the same recording rather than the plot's footer, and
  /// two pictures with one box between them read as one.
  final PlotBorder _border;

  /// One 100 ms column is one logical pixel. A 1200 px module holds two
  /// minutes.
  static const double columnWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    // Before the size guard. A module dragged down to a placeholder still has
    // to keep recording, or its history has a hole in it exactly where somebody
    // was busy rearranging the canvas.
    if (engine.hasLoudness &&
        engine.generation != 0 &&
        engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      history.accumulate(
        engine.lufsShort,
        engine.lufsMomentary,
        engine.elapsedSeconds,
      );
    }

    // The target's own label lives in the scale gutter, beside the line it
    // belongs to, so the gutter has to be wide enough for a five-character
    // reading rather than for the graticule's three-character ticks. Printed
    // inside the plot instead it lands on top of the programme — legible on an
    // empty display, unreadable on a full one, which is the one that matters.
    // The ticks its label would collide with are the graticule's problem, and
    // it already yields — see `avoid` on it.
    final targetLabel = state._targetValue.of(
      Metric.lufsIntegrated.format(calibration.lufsTarget),
      _targetStyle,
    );

    final labelHeight = OaaType.tick.fontSize! + Space.sm;
    final overview = HistogramModule.overviewHeight(size.height);
    // The box, and the plot inside it — see [PlotBorder]. The newest column of
    // the programme lands against the right-hand edge, so the box goes round
    // it rather than over it.
    final box = Rect.fromLTRB(
      math.max(graticule.gutter, targetLabel.longestLine + Space.xs),
      labelHeight,
      size.width,
      HistogramModule.plotFloor(size.height),
    );
    final plot = PlotBorder.inside(box);
    if (plot.width < 80 || plot.height < 40) return;

    final pixels = (plot.width / columnWidth).floor();
    state._ensurePixels(pixels);
    state._ensureFills(plot, colors);

    // The window over the ring: how many columns the plot covers, and how far
    // behind the newest column its right-hand edge sits.
    final span = state._resolveWindow(pixels, history);
    final firstAge = history.written - 1 - state._anchor;

    graticule.paint(canvas, plot);

    // The axis unit shares the band the time labels are in, hard against the
    // left edge — which the widened gutter now has room for. Anywhere inside
    // the plot it would sit over the programme, and at the top of the plot it
    // sat under the oldest time tick.
    final unit = state._unit!;
    canvas.drawParagraph(unit, Offset(0, plot.top - unit.height - Space.xs));

    _paintTimeAxis(canvas, plot, unit.longestLine + Space.sm, pixels, span);

    final targetY = _y(plot, calibration.lufsTarget);
    _paintProgramme(canvas, plot, pixels, span, firstAge, targetY);
    _paintTarget(canvas, plot, targetY, targetLabel);
    // After the programme; before the strip, which is boxed separately.
    _border.paint(canvas, box);
    // Edge to edge, under the axis gutter as well: the strip is a map of the
    // whole recording, not a part of the plot above it, and a map that starts
    // where the plot's first column does reads as the plot's footer.
    if (overview > 0) {
      _paintOverview(
        canvas,
        Rect.fromLTRB(0, size.height - overview, size.width, size.height),
        span,
        firstAge,
      );
    }
  }

  /// Vertical gridlines, labelled with **how far into the programme** the
  /// column under them is — "45s", "1m15s" — which is Decibel's axis and the
  /// one a scrollable plot can keep.
  ///
  /// It was the wall-clock time the column was recorded at, on the argument
  /// that "the chorus was loud at 10:30:58" outlives "28 seconds ago". That
  /// argument survives only while the plot is pinned to the newest column: the
  /// moment it can be scrolled, a clock counting back from `DateTime.now()`
  /// labels a chorus four minutes ago with the time it is being *looked* at.
  /// Elapsed time is a property of the column, so it is right at every scroll
  /// position and at every zoom, and it is the number the transport shows.
  ///
  /// The ticks are pinned to the programme rather than to the right-hand edge,
  /// which is why they are placed by walking back from the newest **multiple of
  /// the interval** rather than from the edge itself: a gridline at a round
  /// number that slides with the material is a mark you can read a position
  /// off, where one nailed to the edge is a ruler that renumbers itself every
  /// frame.
  ///
  /// [leftLimit] is where the axis unit ends; a tick whose label would reach it
  /// is the oldest one drawn.
  void _paintTimeAxis(
    Canvas canvas,
    Rect plot,
    double leftLimit,
    int pixels,
    int span,
  ) {
    // The finest interval whose ticks are far enough apart to label and few
    // enough to read. Measured against the widest label rather than guessed at,
    // for the same reason the spectrum analyser measures its own — and against
    // the *zoom*, which is what decides how many seconds a pixel is worth.
    final secondsPerPixel = span * _secondsPerColumn / pixels;
    var rung = _timeLadder.length - 1;
    for (var i = 0; i < _timeLadder.length; i++) {
      final spacing = _timeLadder[i] / secondsPerPixel;
      if (spacing >= state._widestTimeLabel + Space.lg &&
          plot.width / spacing <= _maxTimeTicks) {
        rung = i;
        break;
      }
    }

    final interval = _timeLadder[rung];
    final rightSeconds = history.secondsAt(state._anchor);

    // The newest round number at or before the plot's right-hand edge, then
    // leftwards one interval at a time. Nothing before the start of the
    // programme: the resting line to the left of the history is a convention
    // and not a time anything was measured at.
    var tick = (rightSeconds / interval).floor();
    for (var drawn = 0; drawn <= _maxTimeTicks && tick >= 0; drawn++, tick--) {
      final seconds = (tick * interval).toDouble();
      final x = plot.right - (rightSeconds - seconds) / secondsPerPixel;
      final label = state._timeValues[drawn].of(
        _elapsedText(seconds),
        _tickStyle,
      );
      // Centred on its gridline, but kept inside the plot: the newest tick can
      // land on the right-hand edge itself, and half a label past it is half a
      // label the module's own clip takes off.
      var left = x - label.longestLine / 2;
      if (left + label.longestLine > plot.right) {
        left = plot.right - label.longestLine;
      }
      if (x < plot.left || left < leftLimit) break;

      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);
      canvas.drawParagraph(
        label,
        Offset(left, plot.top - label.height - Space.xs),
      );
    }
  }

  /// The two bands and the short-term curve, the window's newest column at the
  /// right edge.
  void _paintProgramme(
    Canvas canvas,
    Rect plot,
    int pixels,
    int span,
    int firstAge,
    double targetY,
  ) {
    // How much of the window the ring actually holds. Everything past it is
    // programme that has not happened yet — a window scrolled to the very start
    // of a short recording has its left-hand columns unmeasured, exactly as an
    // unzoomed plot does before the first minute is over.
    final visible = (history.filled - firstAge).clamp(0, span);

    // The ring through the smoothing window, once for each band, before
    // anything is positioned. Only the measured columns go through it: the
    // resting floor to the left of the history is a convention rather than a
    // measurement, and averaging against it would ramp the oldest columns of a
    // loud programme down towards the floor as though the programme had faded
    // in.
    final radius = smoothing.radiusInColumns(_secondsPerColumn);
    final shortShown = state._shortShown;
    final momentaryShown = state._momentaryShown;
    history.shortInto(shortShown, firstAge, visible, radius);
    history.momentaryInto(momentaryShown, firstAge, visible, radius);

    final shortBars = state._shortBars;
    final curve = state._curve;
    final bands = state._bands..clear();

    // The curve is stroked, so a reading pinned to either end of the scale has
    // half its width outside the plot and is clipped to a thread. That is worst
    // exactly where it is most visible — a display at rest is nothing but the
    // line along the floor — so the *curve* is held half a stroke inside. The
    // bars are not: they carry the extent of the reading and keep it exact.
    final curveTop = plot.top + OaaStroke.mark / 2;
    final curveBottom = plot.bottom - OaaStroke.mark / 2;

    for (var i = 0; i < pixels; i++) {
      final x = plot.right - (i + 0.5) * columnWidth;

      // The columns this pixel covers. One of them at a zoom of a column to the
      // pixel or finer, several when the window is wider than the plot — and
      // then the short-term is their mean and the momentary their loudest. See
      // the class comment for why the two fold differently.
      final from = i * span ~/ pixels;
      final to = math.max(from, ((i + 1) * span / pixels).ceil() - 1);
      var sum = 0.0;
      var finite = 0;
      var loudest = double.nan;
      for (var column = from; column <= to && column < visible; column++) {
        final level = shortShown[column];
        if (!level.isNaN) {
          sum += level;
          finite++;
        }
        final peak = momentaryShown[column];
        if (!peak.isNaN && (loudest.isNaN || peak > loudest)) loudest = peak;
      }

      // Past the oldest measured column the line rests on the floor of the
      // scale and runs flat to the left edge, so the curve spans the plot from
      // the first frame and survives a reset. It used to stop where the history
      // did — which on an empty display is nowhere at all, and a module with no
      // line in it reads as one that has failed rather than one that is waiting.
      //
      // Resting is not reading. The floor is the bottom of the scale — −∞, now
      // literally — the bars are zero length there so nothing is filled beneath
      // it, and it is drawn exactly where measured silence would put it.
      //
      // Every slot is written either way, which is what lets the whole buffer
      // be handed over as it is; a `sublistView` would be an allocation per
      // frame.
      final shortY = finite == 0 ? plot.bottom : _y(plot, sum / finite);
      var momentaryY = loudest.isNaN ? plot.bottom : _y(plot, loudest);
      // Momentary quieter than short-term is an ordinary reading, not an error,
      // and it has no band — the area is only ever drawn upwards from the line.
      if (momentaryY > shortY) momentaryY = shortY;

      shortBars[i * 4] = x;
      shortBars[i * 4 + 1] = plot.bottom;
      shortBars[i * 4 + 2] = x;
      shortBars[i * 4 + 3] = shortY;

      // The band, bucketed by its own column's tint — how far the momentary
      // reading stood over the target. At or under the target the tint is the
      // accent itself; the ramp to [OaaColors.over] tops out [_bandTintSpan]
      // LU past it.
      if (momentaryY < shortY) {
        final over = ((loudest - calibration.lufsTarget) / _bandTintSpan).clamp(
          0.0,
          1.0,
        );
        bands.run((over * (_bandTints - 1)).round(), x, momentaryY, shortY);
      }

      curve[i * 2] = x;
      curve[i * 2 + 1] = shortY.clamp(curveTop, curveBottom);
    }

    // The band first, so the area's own edge stays the strongest line.
    bands.draw(canvas, ui.PointMode.lines, state._bandPaints);

    // Under the target and over it, as two clipped passes of the same buffer.
    // The alternative — sorting the columns by which side they fall on — would
    // colour a *column* by its verdict, and a column that straddles the line
    // has no single answer. Clipping puts the boundary exactly where the target
    // is, which is the only place it is true.
    void pass(Rect region, Paint fill) {
      if (region.height <= 0) return;
      canvas.save();
      canvas.clipRect(region);
      canvas.drawRawPoints(ui.PointMode.lines, shortBars, fill);
      canvas.restore();
    }

    pass(
      Rect.fromLTRB(plot.left, targetY, plot.right, plot.bottom),
      state._fillUnder!,
    );
    pass(
      Rect.fromLTRB(plot.left, plot.top, plot.right, targetY),
      state._fillOver!,
    );

    // The curve, split at the target like everything under it. Two clipped
    // passes of the same buffer rather than two polylines: a column that
    // straddles the line has no single verdict, and cutting where the target
    // actually is means the outline changes colour on exactly the pixel row the
    // fill does.
    void edge(Rect region, Paint paint) {
      if (region.height <= 0) return;
      canvas.save();
      canvas.clipRect(region);
      canvas.drawRawPoints(ui.PointMode.polygon, curve, paint);
      canvas.restore();
    }

    edge(Rect.fromLTRB(plot.left, targetY, plot.right, plot.bottom), _curve);
    edge(Rect.fromLTRB(plot.left, plot.top, plot.right, targetY), _curveOver);
  }

  void _paintTarget(
    Canvas canvas,
    Rect plot,
    double targetY,
    ui.Paragraph label,
  ) {
    final dashes = state._dashes;
    for (var i = 0; i < dashes.length ~/ 4; i++) {
      final x = plot.left + i * _dashPeriod;
      dashes[i * 4] = x;
      dashes[i * 4 + 1] = targetY;
      dashes[i * 4 + 2] = math.min(x + _dashOn, plot.right);
      dashes[i * 4 + 3] = targetY;
    }
    canvas.drawRawPoints(ui.PointMode.lines, dashes, _target);

    // Right-aligned against the same edge the graticule aligns its ticks to,
    // and centred on the line rather than sitting above it — a reader looking
    // for the target reads across from the number, so the number has to be at
    // the height of the thing it names. In [OaaColors.over] like the line it
    // names, because it is a statement about the delivery target and not
    // another mark on the scale; the ticks it displaces are the graticule's
    // `avoid`.
    canvas.drawParagraph(
      label,
      Offset(
        plot.left - Space.xs - label.longestLine,
        (targetY - label.height / 2).clamp(
          plot.top,
          plot.bottom - label.height,
        ),
      ),
    );
  }

  /// The whole ring at a glance, with a frame over the slice the plot shows.
  ///
  /// Each strip pixel takes the **loudest** short-term column it covers — a
  /// mean at this resolution hides a spike, and a spike here is the section
  /// worth finding. Pixels older than the recording repeat the oldest point,
  /// which draws nothing: a polyline cannot carry a gap, and a resting line
  /// across territory nobody measured would claim silence at −∞ was recorded.
  ///
  /// The frame is the handle the strip is dragged and zoomed by — see
  /// [_OverviewHandle], which is the same rectangle as a hit target.
  void _paintOverview(Canvas canvas, Rect strip, int span, int firstAge) {
    // The surface fills the strip; everything drawn on it lives inside the box
    // — see [PlotBorder]. The window frame in particular: it is a control, it
    // is drawn in the strong hairline, and it used to run along the strip's
    // own top and bottom edges, so a box on those edges would be dimmed by it
    // wherever the window happened to be and would read as a broken rule.
    canvas.drawRect(strip, _overviewFill);
    final inner = PlotBorder.inside(strip);

    // The strip spans the recording so far — the whole ring once it has
    // filled, and never less than the plot's own window. Mapped to the ring's
    // *capacity*, as it was at first, a session's first minute was a sliver
    // at the strip's right end with seven blank minutes beside it, which is a
    // map of time that has not happened.
    final filled = history.filled;
    final columns = math.max(filled, span).clamp(1, _capacity);
    state._overviewColumns = columns;

    // The frame over what the plot is showing. Age 0 is the strip's right-hand
    // edge, so a window scrolled back sits further left by exactly the columns
    // it is behind. Drawn on an empty strip too: the window is a statement
    // about the plot, and the plot is there.
    final right = inner.right - inner.width * firstAge / columns;
    final window = Rect.fromLTRB(
      right - inner.width * span / columns,
      inner.top,
      right,
      inner.bottom,
    );
    // Filled as well as outlined, faintly. An outline alone is a *marker*, and
    // this one is a control: the fill is what says the rectangle is the thing
    // to grab rather than a note about where you are.
    canvas.drawRect(window, _windowFill);
    canvas.drawRect(window, _window);

    if (filled == 0) {
      _border.paint(canvas, strip);
      return;
    }

    final pixels = inner.width.floor();
    if (pixels <= 0) return;
    if (state._overviewPixels != pixels) {
      state._overviewPixels = pixels;
      state._overview = Float32List(pixels * 2);
    }

    // The ring raw — the overview is a map, and smoothing a map redraws the
    // territory. One read per stored column and a pass over the strip's width,
    // per frame.
    history.shortInto(state._overviewShown, 0, filled, 0);

    final line = state._overview;
    final top = inner.top + 2;
    final trackHeight = inner.height - 4;
    var lastX = inner.right - 0.5;
    var lastY = inner.bottom - 2;
    for (var px = 0; px < pixels; px++) {
      final from = px * columns ~/ pixels;
      final to = ((px + 1) * columns / pixels).ceil() - 1;
      var loudest = double.nan;
      for (var age = from; age <= to && age < filled; age++) {
        final value = state._overviewShown[age];
        if (!value.isNaN && (loudest.isNaN || value > loudest)) {
          loudest = value;
        }
      }
      if (!loudest.isNaN) {
        lastX = inner.right - px - 0.5;
        lastY = top + (1 - graticule.scale.fractionOf(loudest)) * trackHeight;
      }
      line[px * 2] = lastX;
      line[px * 2 + 1] = lastY;
    }
    canvas.drawRawPoints(ui.PointMode.polygon, line, _overviewLine);
    _border.paint(canvas, strip);
  }

  double _y(Rect plot, double lufs) =>
      plot.bottom - graticule.scale.fractionOf(lufs) * plot.height;

  @override
  bool shouldRepaint(_HistogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      oldDelegate.smoothing != smoothing ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
