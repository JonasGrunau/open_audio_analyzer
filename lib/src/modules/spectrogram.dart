// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Frequency against time, with level as brightness.
///
/// The same bands the analyser draws, one column per published measurement,
/// scrolling left. Frequency runs up the display because that is the axis the
/// analyser uses and two modules on one tab disagreeing about which way is up
/// would be worse than either choice — and both axes are labelled, because a
/// spectrogram without a frequency axis is a texture: the labels on the left
/// are the analyser's own [kHzGrid] series, and the ages along the top say how
/// far back the record reaches, measured off the engine's clock rather than
/// assumed from a nominal publish rate.
///
/// Which colours the level is drawn in is [ColorRamp]: the skin's ground
/// through `accent` to a bright accent tip, or the spectrogram rainbow —
/// indigo, blue, cyan, green, yellow, orange, red, white. **Both ramps map the
/// same quantity**, and it is the level rather than the frequency, because the
/// frequency is already up the y axis: a hue per row would say nothing a
/// glance at the axis does not, and it would leave the level with only
/// brightness to be read from. [ColorRamp] owns the other half of that
/// argument — the oscilloscope, which has no frequency axis, so colour there
/// is the only thing that can carry one.
///
/// Only [_lut] changes between the two. The record, the floor, the ceiling and
/// the step recorded per cell are identical at either setting, which is why
/// switching re-renders the history in place rather than dropping it.
///
/// ---------------------------------------------------------------------------
/// Why the history is pixels uploaded as an image — and why that is not the
/// image accumulation that once crashed the application
///
/// This module has now had three designs, and each replaced a cost the previous
/// one measured wrongly.
///
/// The first kept last frame's picture as a `toImageSync` image and drew it
/// back one column to the left. **That cannot be done in Flutter**: an image
/// from `toImageSync` is a handle to a display list the engine has not
/// rasterised yet, and it holds that display list for its whole life — so the
/// image of frame *n* retains the picture that drew it, which retains the
/// image of frame *n−1*, back to the first frame. Open Audio Analyzer leaked
/// one full-size image per published frame this way and died after about
/// seventy seconds, when the chain was finally dropped and the engine recursed
/// 3,286 destructors deep through it and overflowed the raster thread's stack.
///
/// The second kept the history as run-length columns and redrew every stored
/// run every frame through [PointBuckets]. Bounded and safe — but its cost was
/// budgeted against *smooth* data, about 25 runs per column, and a real signal
/// is not smooth: the engine takes the peak bin per band, so broadband
/// material jitters a step or more between most adjacent rows.
/// `tool/bench_spectrogram.dart` measures both cases: at ±1–2 dB of band
/// jitter a 1200×300 display coalesces to 120–190 runs per column — 150,000 to
/// 230,000 marks re-recorded on the UI thread and re-tessellated on the raster
/// thread on **every published frame**, 2–4 MB of display list each time. The
/// cost ramped for the ~25 seconds the ring took to fill after a mount and
/// then sat there, dragging every module on the shared clock with it — which
/// read as "the app gets slower the longer I watch it", reset by anything that
/// remounted the module.
///
/// So the past is kept as **pixels**: one byte of palette step per cell (the
/// measurement record, what a skin or ramp change re-renders from) and one RGBA
/// buffer
/// beside it, shifted left a column per published frame and uploaded as a
/// `ui.Image` that paint draws with a single `drawImageRect`. Recording is one
/// op; rasterising is one textured quad. The same benchmark puts the whole of
/// it — shift, column write, copy out, instantiate — at about a quarter of a
/// millisecond per published frame for that same 1200×300 display, bounded by
/// the module's area (~1.4 MB, the bandwidth of a small video) and
/// **independent of what the signal does**, which neither earlier design was.
///
/// Three properties keep this out of the trap the first design died in:
///
///   * The images are **pixel-backed** — `ImageDescriptor.raw` over an
///     `ImmutableBuffer` copy — and hold no display list, no picture, no chain.
///   * Each image **replaces** the previous one, which is disposed on the
///     spot. At most two are alive: the one on screen and the one being built.
///   * The build is asynchronous, so at most one is in flight; frames that
///     arrive while it runs coalesce into one rebuild of the newest buffer.
///     The buffer itself never skips a column — only the picture of it can lag
///     one published frame (~21 ms) behind, which on a scrolling record is
///     invisible.
class SpectrogramModule extends StatefulWidget {
  const SpectrogramModule({
    required this.engine,
    required this.clock,
    this.source = SpectrumSource.all,
    this.ramp = ColorRamp.skin,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// Which signal the bands are measured on. See [SpectrumSource]. Changing
  /// it **clears the record**: a spectrogram whose left half is one signal
  /// and right half another, under one label, is a picture of a measurement
  /// nobody took — unlike the ramp, which re-colours the same record.
  final SpectrumSource source;

  /// Which colours the display is drawn in. See [ColorRamp] — [_lut] is sampled
  /// from it, and a change to it re-renders every cell from the record without
  /// touching the record.
  final ColorRamp ramp;

  @override
  State<SpectrogramModule> createState() => _SpectrogramModuleState();
}

const int _steps = 48;

class _SpectrogramModuleState extends State<SpectrogramModule> {
  int _columns = 0;
  int _rows = 0;

  /// The palette step of every cell, row-major, newest column rightmost. This
  /// is the record; the RGBA beside it is just the current palette's rendering
  /// of it, re-derived in place when the skin or the ramp changes.
  Uint8List _stepOf = Uint8List(0);

  /// The same cells as straight RGBA bytes, the layout `ImageDescriptor.raw`
  /// takes. Written incrementally — a shift and one new column per published
  /// frame — never re-derived except on a skin or ramp change.
  Uint8List _pixels = Uint8List(0);

  /// What [_upload] hands to `ImmutableBuffer`. A copy, so the working buffer
  /// can take the next column while a build is still reading this one.
  Uint8List _staging = Uint8List(0);

  /// RGBA bytes per palette step, rewritten when the skin or the ramp moves.
  final Uint8List _lut = Uint8List(_steps * 4);

  /// What [_lut] was sampled from.
  ///
  /// The whole palette rather than its accent alone — `panel` and
  /// `textPrimary` feed the skin ramp too. [OaaColors] has value equality, so
  /// this costs a field comparison per build and catches a skin whose accent
  /// did not move.
  OaaColors? _lutColors;
  ColorRamp? _lutRamp;

  /// The axis text, rebuilt only when the palette moves.
  ///
  /// The frequency labels are static paragraphs; the ages along the top are
  /// [ValueParagraph]s because their strings move as the window fills and as
  /// the measured column rate settles.
  Color? _axisColor;
  List<ui.Paragraph> _hzLabels = const [];
  double _hzInk = 0;

  /// Which [kHzGrid] values carry a label at the current plot height — solved
  /// by [fitHzLabels] when the plot resizes, not per frame.
  List<bool> _hzLabelled = const [];
  double _hzLabelledFor = -1;

  void solveAxis(double plotHeight) {
    if (_hzLabelledFor == plotHeight || _hzLabels.isEmpty) return;
    _hzLabelledFor = plotHeight;
    final labelHeight = _hzLabels.first.height;
    _hzLabelled = fitHzLabels(plotHeight, (_) => labelHeight);
  }

  final List<ValueParagraph> _ageLabels = [];

  /// What a source the signal cannot provide is drawn over — the same words
  /// the stereo cloud and the phase scope use for the same fact.
  ui.Paragraph? _mono;

  void _buildAxisText(OaaColors colors) {
    if (_axisColor == colors.textFaint) return;
    _axisColor = colors.textFaint;
    final style = OaaType.tick.copyWith(color: colors.textFaint);
    _hzLabels = [
      for (final hz in kHzGrid) layoutParagraph(formatHz(hz), style),
    ];
    _hzInk = 0;
    for (final label in _hzLabels) {
      if (label.longestLine > _hzInk) _hzInk = label.longestLine;
    }
    _mono = layoutParagraph(
      'MONO SOURCE',
      OaaType.label.copyWith(color: colors.textMuted),
    );
  }

  /// Drops the record and shows the ramp's ground, for a change of source.
  void clear() {
    if (_stepOf.isEmpty) return;
    _stepOf.fillRange(0, _stepOf.length, 0);
    _fillWithStepZero();
    _upload();
  }

  @override
  void didUpdateWidget(SpectrogramModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) clear();
  }

  /// Seconds of audio per recorded column, measured off the engine's clock.
  ///
  /// The publish rate is *about* 47 Hz, and "about" is not a number to print
  /// an axis in: a display fed over the wire runs at whatever rate the host
  /// publishes. So the span is accumulated — elapsed seconds against columns
  /// appended — and a discontinuity (a reset, a stalled link) is skipped
  /// rather than folded in, because a 30-second gap divided over one column
  /// would misdate the whole record.
  double _lastElapsed = double.nan;
  double _spanSeconds = 0;
  int _spanColumns = 0;

  double get secondsPerColumn =>
      _spanColumns > 0 ? _spanSeconds / _spanColumns : 1 / 47;

  void noteAppend(double elapsed) {
    final dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (dt > 0 && dt < 1) {
      _spanSeconds += dt;
      _spanColumns++;
    }
  }

  /// What paint draws. Pixel-backed, at most one predecessor alive while its
  /// replacement is in flight.
  ui.Image? _image;
  bool _building = false;
  bool _dirty = false;
  bool _disposed = false;

  /// Bumped on every resize, so a build that was in flight when the buffers
  /// were reallocated throws its result away instead of publishing an image of
  /// a size paint no longer draws.
  int _epoch = 0;

  /// Generation 0 is "nothing has been measured yet", not "a measurement that
  /// happens to be zero" — and the arrays behind a fresh source are zeroed,
  /// which as dB is full scale on every band. Starting here rather than at −1
  /// is what stops a column of maximum level being the first thing the
  /// spectrogram ever records, where it then sits until it scrolls off.
  int lastGeneration = 0;

  /// Reallocates when the module's size changes. The history is dropped, as it
  /// always has been on a resize: the cells are pixel rows, and the same cell
  /// means a different band once the plot has moved under it.
  void resize(int columns, int rows) {
    if (columns == _columns && rows == _rows) return;
    _columns = columns;
    _rows = rows;
    _epoch++;
    _stepOf = Uint8List(columns * rows);
    _pixels = Uint8List(columns * rows * 4);
    _staging = Uint8List(_pixels.length);
    _image?.dispose();
    _image = null;
    _fillWithStepZero();
  }

  /// Samples [ColorRamp] into [_lut], a colour per step of level.
  ///
  /// Called from `build`, so the palette is always there before the first paint
  /// asks for it, and it returns at once when neither the skin nor the ramp has
  /// moved.
  void _buildLut(OaaColors colors, ColorRamp ramp) {
    if (_lutColors == colors && _lutRamp == ramp) return;
    _lutColors = colors;
    _lutRamp = ramp;
    for (var step = 0; step < _steps; step++) {
      final color = ramp.colorAt(step / (_steps - 1), colors);
      _lut[step * 4] = (color.r * 255).round();
      _lut[step * 4 + 1] = (color.g * 255).round();
      _lut[step * 4 + 2] = (color.b * 255).round();
      _lut[step * 4 + 3] = (color.a * 255).round();
    }
  }

  /// Every cell to the ramp's ground — a blank record, which is what both a
  /// fresh module and a resized one show until audio arrives.
  void _fillWithStepZero() {
    for (var p = 0; p < _pixels.length; p += 4) {
      _pixels[p] = _lut[0];
      _pixels[p + 1] = _lut[1];
      _pixels[p + 2] = _lut[2];
      _pixels[p + 3] = _lut[3];
    }
  }

  /// Shifts the record one column left and writes the newest at the right
  /// edge. `setRange` on typed data is a `memmove`, so the shift handles its
  /// own overlap; the seam it smears from each row's start into the previous
  /// row's end is overwritten by the new column before anything reads it.
  void append(int Function(int row) stepAt) {
    if (_columns == 0 || _rows == 0) return;

    _stepOf.setRange(0, _stepOf.length - 1, _stepOf, 1);
    _pixels.setRange(0, _pixels.length - 4, _pixels, 4);

    final last = _columns - 1;
    for (var row = 0; row < _rows; row++) {
      final step = stepAt(row);
      _stepOf[row * _columns + last] = step;
      final p = (row * _columns + last) * 4;
      final l = step * 4;
      _pixels[p] = _lut[l];
      _pixels[p + 1] = _lut[l + 1];
      _pixels[p + 2] = _lut[l + 2];
      _pixels[p + 3] = _lut[l + 3];
    }

    _upload();
  }

  /// Re-renders every cell from its recorded step, for a skin or ramp change.
  void _repaintAll() {
    for (var cell = 0; cell < _stepOf.length; cell++) {
      final p = cell * 4;
      final l = _stepOf[cell] * 4;
      _pixels[p] = _lut[l];
      _pixels[p + 1] = _lut[l + 1];
      _pixels[p + 2] = _lut[l + 2];
      _pixels[p + 3] = _lut[l + 3];
    }
    _upload();
  }

  /// Builds a fresh image of the buffer and swaps it in, disposing the one it
  /// replaces. One in flight at a time; anything that changes the buffer
  /// meanwhile coalesces into a single rebuild of its newest state.
  void _upload() {
    if (_building) {
      _dirty = true;
      return;
    }
    _building = true;
    _buildLoop();
  }

  Future<void> _buildLoop() async {
    do {
      _dirty = false;
      final epoch = _epoch;
      final columns = _columns;
      final rows = _rows;
      _staging.setAll(0, _pixels);

      final buffer = await ui.ImmutableBuffer.fromUint8List(_staging);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: columns,
        height: rows,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();

      if (_disposed || epoch != _epoch) {
        frame.image.dispose();
        if (_disposed) break;
        continue;
      }
      _image?.dispose();
      _image = frame.image;
    } while (_dirty);
    _building = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    for (final label in _ageLabels) {
      label.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    _buildAxisText(colors);
    if (_lutColors != colors || _lutRamp != widget.ramp) {
      _buildLut(colors, widget.ramp);
      if (_stepOf.isNotEmpty) _repaintAll();
    }

    return MeterBody(
      painter: _SpectrogramPainter(
        engine: widget.engine,
        colors: colors,
        source: widget.source,
        ramp: widget.ramp,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _SpectrogramPainter extends MeterPainter {
  _SpectrogramPainter({
    required this.engine,
    required this.colors,
    required this.source,
    required this.ramp,
    required this.state,
    required Listenable repaint,
    // The ramp's own ground, not the module's panel: the cells no signal
    // reached are drawn in it, and a background that disagreed with them would
    // put a seam down the display at the sliver the column flooring leaves.
  }) : _background = (Paint()..color = ramp.groundOf(colors)),
       // Nearest-neighbour on purpose: the columns are 1 logical pixel and the
       // usual display scales are integer, so filtering would only blur the
       // newest edge. Antialiasing has no edge to work on either.
       _bitmap = (Paint()
         ..filterQuality = FilterQuality.none
         ..isAntiAlias = false),
       // The graticule is drawn *over* the picture — there is nowhere else —
       // so it is the hairline let down far enough not to read as signal.
       _grid = (Paint()
         ..color = colors.hairline.withValues(alpha: 0.6)
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _ageStyle = OaaType.tick.copyWith(color: colors.textFaint),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final SpectrumSource source;
  final ColorRamp ramp;
  final _SpectrogramModuleState state;

  final Paint _background;
  final Paint _bitmap;
  final Paint _grid;
  final TextStyle _ageStyle;

  /// One published measurement is one column. At ~47 Hz that is about 21 ms of
  /// audio per column, so a 600 px module holds roughly thirteen seconds.
  static const double columnWidth = 1;

  /// The level range mapped onto the palette. Below the floor is background;
  /// a spectrogram scaled to the full 96 dB the analyser shows would be almost
  /// entirely dark.
  static const double _floorDb = -84;
  static const double _ceilingDb = -6;

  @override
  void paint(Canvas canvas, Size size) {
    // The axes cost a gutter and a band, and a module at its size floor cannot
    // spare either — below this the record is the whole body, exactly as it
    // was before the axes existed. Decided from the size alone, so nothing
    // about the signal can flip the layout.
    final axes = size.width >= 140 && size.height >= 80;
    final gutter = axes ? state._hzInk + Space.xs : 0.0;
    final band = axes ? OaaType.tick.fontSize! + Space.xs : 0.0;
    final plot = Rect.fromLTRB(gutter, band, size.width, size.height);

    final columns = (plot.width / columnWidth).floor();
    final rows = plot.height.round();
    if (columns <= 0 || rows <= 0) return;

    state.resize(columns, rows);

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      state.noteAppend(engine.elapsedSeconds);
      // Silence still scrolls. The display is a record of time, and holding it
      // still while audio runs would misdate everything already on it.
      state.append(_available ? _stepAt : _silence);
    }

    canvas.drawRect(plot, _background);

    final image = state._image;
    if (image != null && image.width == columns && image.height == rows) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, columns.toDouble(), rows.toDouble()),
        // Anchored to the right edge, where the newest column lands. The
        // sliver the flooring left over stays background, exactly as it
        // always has.
        Rect.fromLTWH(
          plot.right - columns * columnWidth,
          plot.top,
          columns * columnWidth,
          plot.height,
        ),
        _bitmap,
      );
    }

    if (axes) {
      _paintFrequencyAxis(canvas, plot);
      _paintTimeAxis(canvas, plot);
    }

    // The record keeps scrolling under it — see `append` — and the notice
    // says what the ground it is scrolling is.
    if (engine.hasSpectrum && !_available) {
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          plot.left + (plot.width - mono.longestLine) / 2,
          plot.top + (plot.height - mono.height) / 2,
        ),
      );
    }
  }

  /// Whether the chosen source is measured on this signal at all. NaN
  /// throughout when it is not — the right, mid or side of a one-channel
  /// input — see `MeterSource.spectrumOf`.
  bool get _available =>
      engine.hasSpectrum && !engine.spectrumOf(source)[0].isNaN;

  /// The analyser's [kHzGrid] series down the left edge, each label beside a
  /// hairline drawn over the picture at its band's row — every value that
  /// fits, by the one rule every frequency axis fits by. See [fitHzLabels].
  void _paintFrequencyAxis(Canvas canvas, Rect plot) {
    state.solveAxis(plot.height);
    final labels = state._hzLabels;

    for (var i = 0; i < kHzGrid.length; i++) {
      if (i >= state._hzLabelled.length || !state._hzLabelled[i]) continue;
      final label = labels[i];
      final y =
          plot.bottom -
          bandOfHz(kHzGrid[i]) / MeterShape.spectrumBands * plot.height;
      if (y < plot.top || y > plot.bottom) continue;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), _grid);
      canvas.drawParagraph(
        label,
        Offset(
          plot.left - Space.xs - label.longestLine,
          (y - label.height / 2).clamp(plot.top, plot.bottom - label.height),
        ),
      );
    }
  }

  /// How far back the record reaches, as ages along the top: 0 at the right
  /// edge where the newest column lands, a label every rung that keeps them
  /// legibly apart. The rate under it is measured, not assumed — see
  /// `secondsPerColumn` on the state.
  void _paintTimeAxis(Canvas canvas, Rect plot) {
    final secondsPerPixel = state.secondsPerColumn / columnWidth;
    var interval = 0;
    for (final rung in _ageRungs) {
      if (rung / secondsPerPixel >= _agePixels) {
        interval = rung;
        break;
      }
    }
    if (interval == 0) return;

    for (var tick = 1; ; tick++) {
      final x = plot.right - tick * interval / secondsPerPixel;
      if (x < plot.left + Space.sm) break;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);

      while (state._ageLabels.length < tick) {
        state._ageLabels.add(ValueParagraph());
      }
      final label = state._ageLabels[tick - 1].of(
        _ageText(tick * interval),
        _ageStyle,
      );
      canvas.drawParagraph(
        label,
        Offset(
          (x - label.longestLine / 2).clamp(
            plot.left,
            plot.right - label.longestLine,
          ),
          plot.top - label.height - Space.xxs,
        ),
      );
    }
  }

  /// The intervals an age axis may be labelled at, and the room a label must
  /// have. The finest rung whose labels stay [_agePixels] apart wins.
  static const List<int> _ageRungs = [1, 2, 5, 10, 15, 30, 60, 120, 300];
  static const double _agePixels = 60;

  static String _ageText(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m${rest}s';
  }

  int _silence(int row) => 0;

  /// The palette step for a pixel row. Row 0 is the top of the display, which
  /// is the top of the frequency range.
  int _stepAt(int row) {
    final rows = state._rows;
    final band = (rows > 1)
        ? ((rows - 1 - row) / (rows - 1) * (MeterShape.spectrumBands - 1))
              .round()
              .clamp(0, MeterShape.spectrumBands - 1)
        : 0;
    final db = engine.spectrumOf(source)[band];
    if (db <= _floorDb) return 0;
    final level = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(0.0, 1.0);
    return (level * (_steps - 1)).round();
  }

  @override
  bool shouldRepaint(_SpectrogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.source != source ||
      oldDelegate.ramp != ramp ||
      !identical(oldDelegate.engine, engine);
}
