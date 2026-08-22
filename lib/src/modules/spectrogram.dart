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
/// measurement record, what a skin change re-renders from) and one RGBA buffer
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
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<SpectrogramModule> createState() => _SpectrogramModuleState();
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

class _SpectrogramModuleState extends State<SpectrogramModule> {
  int _columns = 0;
  int _rows = 0;

  /// The palette step of every cell, row-major, newest column rightmost. This
  /// is the record; the RGBA beside it is just the current skin's rendering of
  /// it, re-derived in place when the skin changes.
  Uint8List _stepOf = Uint8List(0);

  /// The same cells as straight RGBA bytes, the layout `ImageDescriptor.raw`
  /// takes. Written incrementally — a shift and one new column per published
  /// frame — never re-derived except on a skin change.
  Uint8List _pixels = Uint8List(0);

  /// What [_upload] hands to `ImmutableBuffer`. A copy, so the working buffer
  /// can take the next column while a build is still reading this one.
  Uint8List _staging = Uint8List(0);

  /// RGBA bytes per palette step, rewritten on a skin change.
  final Uint8List _lut = Uint8List(_steps * 4);
  Color? _builtFor;

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

  /// Every cell to the panel colour — a blank record, which is what both a
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

  /// Re-renders every cell from its recorded step, for a skin change.
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      for (var step = 0; step < _steps; step++) {
        final color = _rampColor(step / (_steps - 1), colors);
        _lut[step * 4] = (color.r * 255).round();
        _lut[step * 4 + 1] = (color.g * 255).round();
        _lut[step * 4 + 2] = (color.b * 255).round();
        _lut[step * 4 + 3] = (color.a * 255).round();
      }
      if (_stepOf.isNotEmpty) _repaintAll();
    }

    return MeterBody(
      painter: _SpectrogramPainter(
        engine: widget.engine,
        colors: colors,
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
    required this.state,
    required Listenable repaint,
  }) : _background = (Paint()..color = colors.panel),
       // Nearest-neighbour on purpose: the columns are 1 logical pixel and the
       // usual display scales are integer, so filtering would only blur the
       // newest edge. Antialiasing has no edge to work on either.
       _bitmap = (Paint()
         ..filterQuality = FilterQuality.none
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _SpectrogramModuleState state;

  final Paint _background;
  final Paint _bitmap;

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
    final columns = (size.width / columnWidth).floor();
    final rows = size.height.round();
    if (columns <= 0 || rows <= 0) return;

    state.resize(columns, rows);

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      // Silence still scrolls. The display is a record of time, and holding it
      // still while audio runs would misdate everything already on it.
      state.append(engine.hasSpectrum ? _stepAt : _silence);
    }

    canvas.drawRect(Offset.zero & size, _background);

    final image = state._image;
    if (image == null || image.width != columns || image.height != rows) {
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, columns.toDouble(), rows.toDouble()),
      // Anchored to the right edge, where the newest column lands. The sliver
      // the flooring left over stays background, exactly as it always has.
      Rect.fromLTWH(
        size.width - columns * columnWidth,
        0,
        columns * columnWidth,
        size.height,
      ),
      _bitmap,
    );
  }

  int _silence(int row) => 0;

  /// The palette step for a pixel row. Row 0 is the top of the display, which
  /// is the top of the frequency range.
  int _stepAt(int row) {
    final rows = state._rows;
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
