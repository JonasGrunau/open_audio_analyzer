// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Frequency against time, with level as brightness.
///
/// The same bands the analyser draws, one column per published measurement,
/// scrolling left. Frequency runs up the display because that is the axis the
/// analyser uses and two modules on one tab disagreeing about which way is up
/// would be worse than either choice.
///
/// ---------------------------------------------------------------------------
/// Why the history is kept as runs and not as pixels
///
/// The obvious implementation of a scrolling display keeps last frame's image,
/// blits it back one column and draws only the new one: constant cost, however
/// long the session runs. That is what this module used to do, through a
/// `toImageSync` ping-pong, and **it cannot be done in Flutter**. An image from
/// `toImageSync` is a handle to a display list the engine has not rasterised
/// yet, and it holds that display list for its whole life — so the image of
/// frame *n* retains the picture that drew it, which retains the image of frame
/// *n−1*, back to the first frame. Disposing the Dart handle releases nothing;
/// the chain owns it. Open Audio Analyzer leaked one full-size image per
/// published frame this way and died after about seventy seconds, when the
/// chain was finally dropped and the engine recursed 3,286 destructors deep
/// through it and overflowed the raster thread's stack.
///
/// So the past is kept as data. Not as levels — re-deriving a column's runs
/// every frame is width × height work per frame — but as the **run-length
/// columns themselves**, coalesced once when the column arrives and afterwards
/// only re-emitted. A column is a few dozen runs rather than a few hundred
/// pixels, and the whole display is one `drawRawPoints` call per palette step
/// (see [PointBuckets]). Recording a 1200-column display that way takes about
/// 0.3 ms of the UI thread against 5.6 ms for a rect per run — and nothing at
/// all on a repaint that carries no new audio, which is most of them. Both
/// figures are `tool/bench_spectrogram.dart`, which prints the rasterised pair
/// beside them on purpose: recording is not the frame, and the number these
/// replaced was a recording cost that got read as one for a whole phase.
///
/// The price is memory proportional to the module's area — three bytes per
/// logical pixel, about 2 MB for a large spectrogram, allocated once per
/// resize. The image this replaces was *sixteen* bytes per logical pixel, and
/// there was one of those per frame, kept forever.
class SpectrogramModule extends StatefulWidget {
  const SpectrogramModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<SpectrogramModule> createState() => _SpectrogramModuleState();
}

class _SpectrogramModuleState extends State<SpectrogramModule> {
  final _history = _ColumnHistory();

  /// Every stored column, emitted as runs and sorted by brightness step.
  final _marks = PointBuckets(_steps);

  /// One [Paint] per brightness step. Fine enough that the steps are invisible,
  /// coarse enough that there are few enough draw calls for the sorting to be
  /// worth it.
  List<Paint> _palette = const [];
  Color? _builtFor;

  /// Generation 0 is "nothing has been measured yet", not "a measurement that
  /// happens to be zero" — and the arrays behind a fresh source are zeroed,
  /// which as dB is full scale on every band. Starting here rather than at −1
  /// is what stops a column of maximum level being the first thing the
  /// spectrogram ever records, where it then sits until it scrolls off.
  int lastGeneration = 0;

  /// The size [_marks] was filled at. Runs are emitted in pixels, so a resize
  /// invalidates them even when no new audio has arrived.
  Size builtFor = Size.zero;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      _palette = [
        for (var step = 0; step < _steps; step++)
          Paint()
            ..color = _rampColor(step / (_steps - 1), colors)
            ..strokeWidth = _SpectrogramPainter.columnWidth
            // The columns tile the display exactly, so there is no edge for
            // antialiasing to soften — only cost, on every run of every
            // column, and a seam wherever two runs of the same colour meet.
            ..isAntiAlias = false,
      ];
    }

    return MeterBody(
      painter: _SpectrogramPainter(
        engine: widget.engine,
        colors: colors,
        history: _history,
        marks: _marks,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

const int _steps = 48;

/// Background to accent to warn, in that order.
///
/// Deliberately not a rainbow. A hue ramp reads as more precise than it is —
/// the eye finds edges between hues that are not edges in the data — and it
/// stops working entirely for the eight percent of men who cannot separate red
/// from green. Brightness within the palette's own colours is monotonic, which
/// is the property that makes a spectrogram legible.
Color _rampColor(double level, OaaColors colors) {
  if (level < 0.55) {
    return Color.lerp(colors.panel, colors.accent, level / 0.55)!;
  }
  return Color.lerp(colors.accent, colors.warn, (level - 0.55) / 0.45)!;
}

/// The spectrogram's past, as run-length columns.
///
/// A ring of [columns] columns, each holding up to [rows] runs as an end row
/// and a brightness step — a run begins where the previous one ended, so its
/// start is not stored. Sized for the worst case of every row differing from
/// the one below it, which costs three bytes per logical pixel and means there
/// is no overflow case to get wrong.
class _ColumnHistory {
  int columns = 0;
  int rows = 0;

  Uint16List _end = Uint16List(0);
  Uint8List _step = Uint8List(0);
  Uint16List _runs = Uint16List(0);

  int _next = 0;

  /// How many columns of the ring hold audio. Never more than [columns].
  int filled = 0;

  /// Reallocates when the module's size changes, and reports whether it did.
  ///
  /// The history is dropped on a resize: the runs are stored in pixel rows, so
  /// a new height would mean re-deriving every column from levels this class
  /// does not keep. The previous implementation dropped its history on a resize
  /// too — a stretched image left a blurred band travelling across the display.
  bool resize(int columns, int rows) {
    if (columns == this.columns && rows == this.rows) return false;
    this.columns = columns;
    this.rows = rows;
    _end = Uint16List(columns * rows);
    _step = Uint8List(columns * rows);
    _runs = Uint16List(columns);
    _next = 0;
    filled = 0;
    return true;
  }

  /// Coalesces one column of [stepAt] into runs and stores it as the newest.
  void append(int Function(int row) stepAt) {
    if (columns == 0 || rows == 0) return;
    final base = _next * rows;
    var runs = 0;
    var current = stepAt(0);

    for (var row = 1; row <= rows; row++) {
      // −1 past the end, so the last run is closed by the loop rather than
      // after it.
      final step = row < rows ? stepAt(row) : -1;
      if (step == current) continue;
      _end[base + runs] = row;
      _step[base + runs] = current;
      runs++;
      current = step;
    }

    _runs[_next] = runs;
    _next = (_next + 1) % columns;
    if (filled < columns) filled++;
  }

  /// Emits every stored column into [marks], newest at the right edge.
  void emit(PointBuckets marks, double width, double rowHeight) {
    for (var age = 0; age < filled; age++) {
      final x = width - (age + 0.5) * _SpectrogramPainter.columnWidth;
      if (x < 0) break;

      final slot = (_next - 1 - age + columns * 2) % columns;
      final base = slot * rows;
      var top = 0;

      for (var run = 0; run < _runs[slot]; run++) {
        final end = _end[base + run];
        final step = _step[base + run];
        // Step 0 is the panel colour, which the painter has already laid down.
        if (step > 0) marks.run(step, x, top * rowHeight, end * rowHeight);
        top = end;
      }
    }
  }
}

class _SpectrogramPainter extends MeterPainter {
  _SpectrogramPainter({
    required this.engine,
    required this.colors,
    required this.history,
    required this.marks,
    required this.state,
    required Listenable repaint,
  }) : _background = (Paint()..color = colors.panel),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _ColumnHistory history;
  final PointBuckets marks;
  final _SpectrogramModuleState state;

  final Paint _background;

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
    if (state._palette.isEmpty) return;

    final columns = (size.width / columnWidth).floor();
    final rows = size.height.round();
    if (columns <= 0 || rows <= 0) return;

    var stale = history.resize(columns, rows);

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      // Silence still scrolls. The display is a record of time, and holding it
      // still while audio runs would misdate everything already on it.
      history.append(engine.hasSpectrum ? _stepAt : _silence);
      stale = true;
    }

    if (stale || size != state.builtFor) {
      state.builtFor = size;
      marks.clear();
      history.emit(marks, size.width, size.height / rows);
    }

    canvas.drawRect(Offset.zero & size, _background);
    marks.draw(canvas, ui.PointMode.lines, state._palette);
  }

  int _silence(int row) => 0;

  /// The palette step for a pixel row. Row 0 is the top of the display, which
  /// is the top of the frequency range.
  int _stepAt(int row) {
    final rows = history.rows;
    final band = (rows > 1)
        ? ((rows - 1 - row) / (rows - 1) * (kOaaSpectrumBands - 1))
              .round()
              .clamp(0, kOaaSpectrumBands - 1)
        : 0;
    final db = engine.spectrum[band];
    if (db <= _floorDb) return 0;
    final level = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(0.0, 1.0);
    return (level * (_steps - 1)).round();
  }

  @override
  bool shouldRepaint(_SpectrogramPainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
