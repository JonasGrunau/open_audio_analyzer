// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Loudness against time: how the programme moved, and when it was over target.
///
/// Decibel's name, which is a misnomer in both products and is kept anyway —
/// `ModuleKind.histogram` is written into every saved preset, and a module that
/// renames itself is a layout that stops loading. What it actually draws is a
/// time series, which is what `docs/PLAN.md` specified from the start.
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
/// Colour is the target and nothing else. Everything under the calibration's
/// LUFS target is drawn in [BelColors.accent], everything over it in
/// [BelColors.over], and the split is a clip rather than a per-column verdict —
/// a short-term reading above target is not a delivery failure and must not be
/// coloured as though somebody had classified it as one. It is the *area* over
/// the line that carries the meaning, and the eye adds that up on its own.
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
/// Why the history is kept here, at ten columns a second
///
/// The engine publishes an instant, not a past, so a time series has to be
/// accumulated by whatever draws it. The engine publishes at about 47 Hz;
/// storing every publish would be six times the resolution a one-pixel column
/// can show, so five or so publishes are folded into each 100 ms column — the
/// *latest* short-term reading, because a 3 s window barely moves in 100 ms,
/// and the *loudest* momentary, because that band is a statement about what the
/// fast meter reached and a mean would erase exactly the transient it exists to
/// show.
///
/// The ring is a fixed 4096 columns — about seven minutes — and it is sized in
/// **columns of measurement, never in pixels**. That is the one thing the
/// spectrogram cannot do: it stores runs in pixel rows, so a resize costs it
/// its whole history. Loudness is resolution-free, so this survives a resize,
/// and the module can be dragged from a corner to full screen without the
/// programme so far disappearing.
///
/// Nothing here accumulates into an image. See the header of `spectrogram.dart`
/// for what that costs — the short version is 266 GB and a dead raster thread.
/// The whole visible history is redrawn every frame out of buffers allocated on
/// resize, which for a 1200-column display is three `drawRawPoints` calls.
class HistogramModule extends StatefulWidget {
  const HistogramModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<HistogramModule> createState() => _HistogramModuleState();
}

/// One column per 100 ms of measured signal — the 10 Hz `docs/PLAN.md` asked
/// for. Fast enough that a short-term line looks continuous, slow enough that
/// a wide module holds minutes rather than seconds.
const double _secondsPerColumn = 0.1;

/// Columns retained regardless of how small the module is. 4096 of them is
/// 6m 50s, and two `Float32List`s of it is 32 KB.
const int _capacity = 4096;

/// The tick intervals the time axis may use, in seconds.
///
/// Nothing below 10 s appears: at 10 columns a second a 5 s tick is 50 px
/// apart, which is narrower than its own label plus a gap, so it could never be
/// chosen and listing it would only suggest it could.
const _timeLadder = <int>[10, 15, 30, 60, 120, 300];

/// The most ticks the axis carries, however wide the module gets. Without a cap
/// a full-width module on a large display draws two dozen of them and the axis
/// becomes a line of text.
const _maxTimeTicks = 8;

/// "45s", "1m", "1m15s" — the label for a tick that many seconds before now.
String _timeText(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '${minutes}m' : '${minutes}m${rest}s';
}

class _HistogramModuleState extends State<HistogramModule> {
  /// The same scale the LUFS Meter and the Super Meter draw. Three modules
  /// showing loudness on one tab against three different ranges is the defect
  /// `MeterScale` exists to prevent.
  static const _scale = MeterScale(min: -48, max: 0, step: 6);

  final _history = _LoudnessHistory();
  final _targetValue = ValueParagraph();

  ScaleGraticule? _graticule;
  ui.Paragraph? _unit;

  /// A label per (interval, tick) pair, laid out once. The axis is labelled in
  /// time *before now* rather than in elapsed time precisely so that it can be:
  /// "1m15s ago" is the same string for the whole session, where "1m15s elapsed"
  /// is a new string every tick and would put a paragraph layout on the frame
  /// path once a second forever.
  List<List<ui.Paragraph>> _timeLabels = const [];
  double _widestTimeLabel = 0;

  /// Generation 0 is "nothing has been measured yet" rather than a measurement
  /// that happens to be zero — see the same field on the spectrogram.
  int lastGeneration = 0;

  // --- Buffers, allocated on resize and never on a frame --------------------

  Float32List _shortBars = Float32List(0);
  Float32List _momentaryBars = Float32List(0);
  Float32List _curve = Float32List(0);
  Float32List _dashes = Float32List(0);
  int _builtColumns = -1;

  void _ensureColumns(int columns) {
    if (columns == _builtColumns) return;
    _builtColumns = columns;
    _shortBars = Float32List(columns * 4);
    _momentaryBars = Float32List(columns * 4);
    _curve = Float32List(columns * 2);
    _dashes = Float32List((columns / _dashPeriod).ceil() * 4);
  }

  // --- The four fills, and the gradient they share --------------------------

  Paint? _fillUnder;
  Paint? _fillOver;
  Paint? _bandUnder;
  Paint? _bandOver;
  Rect? _shadedPlot;
  BelColors? _shadedColors;

  /// Bright along the top edge and nearly gone at the floor, which is what stops
  /// a filled area reading as a block of paint and lets the shape of the curve
  /// carry the information. Same reasoning, and the same trick, as the spectrum
  /// analyser: a shader on the `Paint` is evaluated in canvas space, so a
  /// thousand butt-capped vertical strokes drawn through it produce exactly the
  /// gradient one filled `Path` would — without the path.
  void _ensureFills(Rect plot, BelColors colors) {
    if (_shadedPlot == plot && _shadedColors == colors) return;
    _shadedPlot = plot;
    _shadedColors = colors;

    Paint fill(Color color, double top, double bottom) => Paint()
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = _HistogramPainter.columnWidth
      // The columns are one pixel wide and tile the plot exactly, so there is
      // no edge for antialiasing to soften — only cost. Widening them to
      // overlap instead, the way the spectrum analyser's wider bands are, would
      // blend each column's alpha into its neighbour twice and stripe the fill.
      ..isAntiAlias = false
      ..shader = ui.Gradient.linear(plot.topCenter, plot.bottomCenter, <Color>[
        color.withValues(alpha: top),
        color.withValues(alpha: bottom),
      ]);

    _fillUnder = fill(colors.accent, 0.70, 0.16);
    _fillOver = fill(colors.over, 0.70, 0.16);
    // The momentary band is the same two colours held well back. It is context
    // for the short-term line, not a second reading, and at equal weight the
    // eye reads the *top* of the band as the measurement — which is the fast
    // meter, the one a loudness display exists to look past.
    _bandUnder = fill(colors.accent, 0.26, 0.05);
    _bandOver = fill(colors.over, 0.26, 0.05);
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _targetValue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.left, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = BelType.tick.copyWith(color: colors.textFaint);
      _unit = layoutParagraph('LUFS', style);
      _widestTimeLabel = 0;
      _timeLabels = [
        for (final interval in _timeLadder)
          [
            for (var tick = 1; tick <= _maxTimeTicks; tick++)
              layoutParagraph(_timeText(interval * tick), style),
          ],
      ];
      for (final row in _timeLabels) {
        for (final label in row) {
          if (label.longestLine > _widestTimeLabel) {
            _widestTimeLabel = label.longestLine;
          }
        }
      }
    }

    return MeterBody(
      painter: _HistogramPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        graticule: _graticule!,
        history: _history,
        state: this,
        repaint: widget.clock,
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

  /// The column being accumulated, and the elapsed second it closes at.
  double _shortAcc = double.nan;
  double _momentaryAcc = double.nan;
  double _boundary = _secondsPerColumn;
  double _lastElapsed = 0;

  void clear() {
    _next = 0;
    filled = 0;
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

  double shortAt(int age) => _short[_slot(age)];
  double momentaryAt(int age) => _momentary[_slot(age)];
}

/// Dash geometry for the target line: six pixels on, five off.
const double _dashOn = 6;
const double _dashPeriod = 11;

class _HistogramPainter extends MeterPainter {
  _HistogramPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.history,
    required this.state,
    required Listenable repaint,
  }) : _curve = (Paint()
         // The same colour the spectrum analyser strokes its curve in, over the
         // same translucent fill: opaque accent against a fill that reaches
         // 0.70 of it reads as an edge without becoming a second object. The
         // reading colour was tried here and is too loud — a white line over a
         // filled area is the first thing the eye lands on, and on this module
         // the thing worth landing on is where the area crosses the target.
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.mark),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       // Dashed, so that the one line on the display the user chose cannot be
       // mistaken for one the signal drew.
       _target = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = BelStroke.mark
         ..strokeCap = StrokeCap.butt
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _LoudnessHistory history;
  final _HistogramModuleState state;

  final Paint _curve;
  final Paint _grid;
  final Paint _target;

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
    final targetLabel = state._targetValue.of(
      Metric.lufsIntegrated.format(calibration.lufsTarget),
      BelType.tick.copyWith(color: colors.textMuted),
    );

    // ...and it is dropped rather than allowed to collide with a tick.
    //
    // A target usually lands between two ticks, and on a short module the
    // ticks are close enough together that "between" is not far enough. The
    // obvious repair — a plate of panel colour under the number — cannot work:
    // with −14 sitting 6 px from −12 and 11 px from −18 there is no plate size
    // that covers one without slicing the other in half, and a tick with its
    // top cut off reads as a rendering fault where a missing one reads as a
    // scale you can still count in sixes. So the annotation gives way to the
    // scale, which is the order of precedence a measuring instrument has to
    // have. Where there is room — the default size and anything larger — the
    // number is drawn.
    final labelHeight = BelType.tick.fontSize! + Space.sm;
    final plotHeight = size.height - labelHeight;
    final scale = graticule.scale;
    final target = calibration.lufsTarget.clamp(scale.min, scale.max);
    final nearestTick = (target / scale.step).roundToDouble() * scale.step;
    final showTarget =
        (target - nearestTick).abs() / scale.span * plotHeight >
        targetLabel.height * 0.75;

    final plot = Rect.fromLTRB(
      showTarget
          ? math.max(graticule.gutter, targetLabel.longestLine + Space.xs)
          : graticule.gutter,
      labelHeight,
      size.width,
      size.height,
    );
    if (plot.width < 80 || plot.height < 40) return;

    final columns = (plot.width / columnWidth).floor();
    state._ensureColumns(columns);
    state._ensureFills(plot, colors);

    graticule.paint(canvas, plot);

    // The axis unit shares the band the time labels are in, hard against the
    // left edge — which the widened gutter now has room for. Anywhere inside
    // the plot it would sit over the programme, and at the top of the plot it
    // sat under the oldest time tick.
    final unit = state._unit!;
    canvas.drawParagraph(unit, Offset(0, plot.top - unit.height - Space.xs));

    _paintTimeAxis(canvas, plot, unit.longestLine + Space.sm);

    final targetY = _y(plot, calibration.lufsTarget);
    _paintProgramme(canvas, plot, columns, targetY);
    _paintTarget(canvas, plot, targetY, showTarget ? targetLabel : null);
  }

  /// Vertical gridlines, labelled with how long before now they are.
  ///
  /// [leftLimit] is where the axis unit ends; a tick whose label would reach it
  /// is the oldest one drawn. The ticks run right to left from *now*, so the
  /// one that gets dropped is always the least interesting.
  void _paintTimeAxis(Canvas canvas, Rect plot, double leftLimit) {
    // The finest interval whose ticks are far enough apart to label and few
    // enough to read. Measured against the widest label rather than guessed at,
    // for the same reason the spectrum analyser measures its own.
    var rung = _timeLadder.length - 1;
    for (var i = 0; i < _timeLadder.length; i++) {
      final spacing = _timeLadder[i] / _secondsPerColumn * columnWidth;
      if (spacing >= state._widestTimeLabel + Space.lg &&
          plot.width / spacing <= _maxTimeTicks) {
        rung = i;
        break;
      }
    }

    final spacing = _timeLadder[rung] / _secondsPerColumn * columnWidth;
    final labels = state._timeLabels[rung];

    for (var tick = 1; tick <= _maxTimeTicks; tick++) {
      final x = plot.right - tick * spacing;
      final label = labels[tick - 1];
      final left = x - label.longestLine / 2;
      if (x < plot.left || left < leftLimit) break;

      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);
      canvas.drawParagraph(
        label,
        Offset(left, plot.top - label.height - Space.xs),
      );
    }
  }

  /// The two bands and the short-term curve, newest column at the right edge.
  void _paintProgramme(Canvas canvas, Rect plot, int columns, double targetY) {
    final visible = math.min(history.filled, columns);

    final shortBars = state._shortBars;
    final momentaryBars = state._momentaryBars;
    final curve = state._curve;

    // The curve is stroked, so a reading pinned to either end of the scale has
    // half its width outside the plot and is clipped to a thread. That is worst
    // exactly where it is most visible — a display at rest is nothing but the
    // line along the floor — so the *curve* is held half a stroke inside. The
    // bars are not: they carry the extent of the reading and keep it exact.
    final curveTop = plot.top + BelStroke.mark / 2;
    final curveBottom = plot.bottom - BelStroke.mark / 2;

    for (var i = 0; i < columns; i++) {
      final x = plot.right - (i + 0.5) * columnWidth;

      // Past the oldest measured column the line rests on the floor of the
      // scale and runs flat to the left edge, so the curve spans the plot from
      // the first frame and survives a reset. It used to stop where the history
      // did — which on an empty display is nowhere at all, and a module with no
      // line in it reads as one that has failed rather than one that is waiting.
      //
      // Resting is not reading. The floor is the bottom of the scale, the bars
      // are zero length there so nothing is filled beneath it, and it is drawn
      // exactly where measured silence would put it — which it has to be, or
      // the display would claim to know the difference between "no signal yet"
      // and "signal below −48 LUFS" at a resolution it does not have.
      //
      // Every slot is written either way, which is what lets the whole buffer
      // be handed over as it is; a `sublistView` would be an allocation per
      // frame.
      final measured = i < visible;
      final shortY = measured ? _y(plot, history.shortAt(i)) : plot.bottom;
      var momentaryY = measured
          ? _y(plot, history.momentaryAt(i))
          : plot.bottom;
      // Momentary quieter than short-term is an ordinary reading, not an error,
      // and it has no band — the area is only ever drawn upwards from the line.
      if (momentaryY > shortY) momentaryY = shortY;

      shortBars[i * 4] = x;
      shortBars[i * 4 + 1] = plot.bottom;
      shortBars[i * 4 + 2] = x;
      shortBars[i * 4 + 3] = shortY;

      momentaryBars[i * 4] = x;
      momentaryBars[i * 4 + 1] = shortY;
      momentaryBars[i * 4 + 2] = x;
      momentaryBars[i * 4 + 3] = momentaryY;

      curve[i * 2] = x;
      curve[i * 2 + 1] = shortY.clamp(curveTop, curveBottom);
    }

    // Under the target and over it, as two clipped passes of the same buffers.
    // The alternative — sorting the columns by which side they fall on — would
    // colour a *column* by its verdict, and a column that straddles the line
    // has no single answer. Clipping puts the boundary exactly where the target
    // is, which is the only place it is true.
    void pass(Rect region, Paint band, Paint fill) {
      if (region.height <= 0) return;
      canvas.save();
      canvas.clipRect(region);
      canvas.drawRawPoints(ui.PointMode.lines, momentaryBars, band);
      canvas.drawRawPoints(ui.PointMode.lines, shortBars, fill);
      canvas.restore();
    }

    pass(
      Rect.fromLTRB(plot.left, targetY, plot.right, plot.bottom),
      state._bandUnder!,
      state._fillUnder!,
    );
    pass(
      Rect.fromLTRB(plot.left, plot.top, plot.right, targetY),
      state._bandOver!,
      state._fillOver!,
    );

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRawPoints(ui.PointMode.polygon, curve, _curve);
    canvas.restore();
  }

  void _paintTarget(
    Canvas canvas,
    Rect plot,
    double targetY,
    ui.Paragraph? label,
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
    if (label == null) return;

    // Right-aligned against the same edge the graticule aligns its ticks to,
    // and centred on the line rather than sitting above it — a reader looking
    // for the target reads across from the number, so the number has to be at
    // the height of the thing it names. Drawn in [BelColors.textMuted] where
    // the ticks are [BelColors.textFaint], because it is a statement about the
    // delivery target and not another mark on the scale.
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

  double _y(Rect plot, double lufs) =>
      plot.bottom - graticule.scale.fractionOf(lufs) * plot.height;

  @override
  bool shouldRepaint(_HistogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
