// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Frequency against time, with level as brightness.
///
/// The same bands the analyser draws, one column per published measurement —
/// per *measurement*, which is why the record is advanced from
/// `MeterClock.measurements` and not from paint; see `_measured` — scrolling
/// left. Frequency runs up the display because that is the axis the
/// analyser uses and two modules on one tab disagreeing about which way is up
/// would be worse than either choice — and both axes are labelled, because a
/// spectrogram without a frequency axis is a texture: the labels on the left
/// are the analyser's own [kHzGrid] series, and the ages along the top say how
/// far back the record reaches, measured off the engine's clock rather than
/// assumed from a nominal publish rate.
///
/// Which colours the level is drawn in is [ColorRamp]: the skin's ground
/// through `accent` into `warn`, or the spectrogram rainbow — indigo, blue,
/// cyan, green, yellow, orange, red, white. **Both ramps map the
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

/// Seconds of audio per recorded column — the rate the record scrolls at, and
/// separately the rate the age axis over it is laid out at.
///
/// The publish rate is *about* 47 Hz, and "about" is not a number to print an
/// axis in: a display fed over the wire runs at whatever rate the host
/// publishes. So the span is accumulated — elapsed seconds against columns
/// appended — and a discontinuity (a reset, a stalled link) is skipped rather
/// than folded in, because a 30-second gap divided over one column would
/// misdate the whole record.
///
/// [axisSeconds] is not [measured], and that difference is the whole reason
/// this is a class and not two fields. [measured] is a running mean over every
/// column ever appended, so each new column moves it — a long way while the
/// mean is young, a little for ever after — and an axis laid out straight from
/// it moved with it on **every published frame**. The ticks are hairlines
/// drawn with antialiasing off, so a fraction of a pixel of drift snaps one
/// from its pixel column to the next and back again, and the label above it
/// shimmers under the same drift. `test/spectrogram_axis_test.dart` replays
/// the case that produces it — a 47 Hz publish fed by 512-frame device
/// callbacks, which is what makes the per-column span jitter, since a publish
/// is paced by a monotonic clock and takes however many whole blocks have
/// arrived — and the sixth tick of a 2 s rung travelled about 3 px per frame
/// through the first second and was still not quite still a minute later. That is a picture of the estimator settling, not of the
/// record, and it is the only thing on the display that moves for a reason the
/// audio did not give it.
///
/// So the drawn rate is adopted in steps: it follows the mean only once the
/// mean has moved [deadband] away from what is already on screen. The error
/// that leaves is bounded by the deadband — a tick labelled 10s standing over
/// a column 9.8 s old — which is well inside what an axis over a scrolling
/// record claims in the first place, and far inside what an axis that will not
/// hold still costs the person reading it.
///
/// **The nominal rate is one of the rates the deadband defends**, and that is
/// the difference between an axis that holds still within a run and one that
/// is the same picture on the next run. Adopting unconditionally the first
/// time the mean was worth anything made the axis a photograph of the device's
/// spin-up: `elapsed` is an audio clock advancing in whole device callbacks —
/// 10.67 ms of it at 512 frames — so a mean taken over the first columns lands
/// on one of a handful of quantised values depending on where those callbacks
/// happened to fall against the publish clock, and the deadband then defended
/// that value for the rest of the session rather than correcting it. Across
/// launches differing in nothing but that phase the adopted rate spread 2.2%
/// and never converged, which at a 2 s rung stands the sixth tick anywhere in
/// a 12 px band: the axis moved every time the application was restarted, and
/// where the spread crossed [kAgePixels] the rung itself flipped and the
/// number of labels changed. Measuring the mean against the rate on screen —
/// nominal included — makes a local engine, which is 0.3% off nominal, draw
/// the identical axis on every launch, while a 30 Hz wire host is 36% away and
/// still corrects inside a few seconds. `test/spectrogram_axis_test.dart`
/// replays both.
///
/// Nothing is adopted at all until [_settleColumns] columns have been
/// measured, because a mean over three of them is worth less than the nominal
/// rate it would replace — and because the spin-up is what that number is
/// sized to clear: the same replay spreads 9.2% over the first twenty columns
/// and 2.2% over the first hundred.
class ColumnRate {
  /// What the axis is drawn at before anything has been measured, and the rate
  /// it keeps unless a measurement disagrees by more than [deadband]. The
  /// engine's own publish rate; a wire display corrects to the host's.
  static const double nominal = 1 / 47;

  /// How far the mean must move from the drawn rate before the axis follows
  /// it, as a fraction of the drawn rate. Public because it is also the error
  /// the axis is allowed to carry, which is what a test asserting the rate
  /// has to state its tolerance in.
  static const double deadband = 0.02;

  /// Columns the mean must be taken over before it is drawn from at all — two
  /// seconds of them at [nominal], which is what it takes for the quantised
  /// spin-up to average out. It was sixteen, a third of a second, and a mean
  /// over that many is a measurement of where the device's callbacks fell.
  static const int _settleColumns = 94;

  double _lastElapsed = double.nan;
  double _spanSeconds = 0;
  int _spanColumns = 0;
  double _axisSeconds = 0;

  /// The running mean, which moves on every column.
  double get measured =>
      _spanColumns > 0 ? _spanSeconds / _spanColumns : nominal;

  /// Columns the mean has been taken over.
  int get columns => _spanColumns;

  /// Forgets everything measured, for a source the previous rate says nothing
  /// about. A plugin connecting replaces the engine underneath the module, and
  /// its clock has no relationship to the one these spans were taken against.
  void reset() {
    _lastElapsed = double.nan;
    _spanSeconds = 0;
    _spanColumns = 0;
    _axisSeconds = 0;
  }

  /// Records that a column was appended at [elapsed] on the engine's clock.
  void note(double elapsed) {
    final dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (dt > 0 && dt < 1) {
      _spanSeconds += dt;
      _spanColumns++;
    }
  }

  /// The rate the axis is laid out at, which holds still between adoptions.
  /// Called from paint, and it is where an adoption happens.
  ///
  /// The comparison is against what is currently *drawn*, which before any
  /// adoption is [nominal] rather than a sentinel — see the class header. A
  /// first measurement that agrees with nominal to within the deadband is a
  /// measurement that has nothing to correct, and adopting it anyway is what
  /// made the axis different on every launch.
  double axisSeconds() {
    final drawn = _axisSeconds == 0 ? nominal : _axisSeconds;
    if (_spanColumns >= _settleColumns) {
      final mean = _spanSeconds / _spanColumns;
      if ((mean - drawn).abs() > drawn * deadband) {
        _axisSeconds = mean;
        return mean;
      }
    }
    return drawn;
  }
}

/// Which rung the ages along a spectrogram are labelled at — **held between
/// frames rather than solved afresh**, and taken with a margin the bare
/// comparison did not have.
///
/// [kAgePixels] is a legibility minimum and the rate it is tested against
/// carries error by construction — [ColumnRate.deadband] of it, deliberately.
/// A bare `>=` therefore decides the whole labelling of the axis on the last
/// digit of an estimate: 2 s at 60.1 px and 2 s at 59.9 px are the same
/// picture of the same audio, and they print `2s 4s 6s` and `5s 10s 15s`.
///
/// **And the rates that land on the threshold are the ordinary ones, not the
/// exotic ones.** A column is one pixel and one published measurement, so a
/// rung falls on exactly [kAgePixels] whenever the publish rate is a round
/// number that divides into it: a 30 Hz wire host stands the 2 s rung at
/// exactly 60 px and a 60 Hz one stands the 1 s rung at exactly 60, which are
/// two of the three rates `kRemoteFpsOptions` offers — and the spectrogram
/// measured 30 Hz on any machine set to 30 fps for as long as it advanced its
/// record from paint. Which side of the coin a launch landed on was then a
/// property of the estimator, so the axis was labelled one way on one run and
/// the other way on the next.
///
/// So the comparison is made with the tolerance the rate carries — a rung
/// within [kAgeSlack] of the minimum is taken, because 60 px is not knowable
/// to better than that in the first place — and the rung already on screen is
/// then *kept* on a looser threshold still. Both rates above land on the
/// finest legible rung, the same one on every launch. [held] is the rung the
/// display is already labelled at, or 0 for one that has not labelled any yet.
int ageInterval(double secondsPerPixel, {int held = 0}) {
  for (final rung in kAgeRungs) {
    // Taking a rung and giving one up are different thresholds, and the gap
    // between them is wider than the rate is allowed to move: a rate sitting
    // on either number has to move further than [ColumnRate.deadband] permits
    // before the axis is relabelled.
    final room = kAgePixels * (1 - (rung == held ? 3 : 1) * kAgeSlack);
    if (rung / secondsPerPixel >= room) return rung;
  }
  return 0;
}

/// The intervals an age axis may be labelled at, and the room a label must
/// have. The finest rung whose labels stay [kAgePixels] apart wins — with the
/// margin and the hold that [ageInterval] applies.
const List<int> kAgeRungs = [1, 2, 5, 10, 15, 30, 60, 120, 300];
const double kAgePixels = 60;

/// The tolerance [ageInterval] reads [kAgePixels] with: the error the rate
/// carries by construction, which is the error the pixel figure derived from
/// it carries too. A rung is taken one of these below the minimum and given up
/// three below it, so a rung changes only after the rate has moved twice as
/// far as its deadband allows.
const double kAgeSlack = ColumnRate.deadband;

/// What a tick that many seconds back is labelled.
String ageLabel(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '${minutes}m' : '${minutes}m${rest}s';
}

/// The [ColumnRate] a mounted [SpectrogramModule] is dating its record by.
///
/// The state is private and the rate is not something the widget takes or
/// reports, but it is the whole of what the time axis is laid out from, so a
/// test that cannot read it can only assert on pixels.
@visibleForTesting
ColumnRate columnRateOf(State<SpectrogramModule> state) =>
    (state as _SpectrogramModuleState).rate;

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

  /// The rung the ages are currently labelled at, held across frames so that
  /// the axis keeps a labelling it already has. Solved by [ageInterval], which
  /// is where the reasoning is.
  int ageInterval = 0;

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
  void initState() {
    super.initState();
    widget.clock.measurements.addListener(_measured);
  }

  @override
  void didUpdateWidget(SpectrogramModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) {
      oldWidget.clock.measurements.removeListener(_measured);
      widget.clock.measurements.addListener(_measured);
    }
    // A different source is a different programme, and its elapsed clock has
    // no relationship to the one the record was dated against — the desktop
    // swaps its engine for a plugin's decoded frames the moment a DAW
    // connects. Keeping the record would draw one session's audio onto the end
    // of another's, and keeping the rate would date it at a publish rate
    // nothing is publishing at any more.
    if (!identical(oldWidget.engine, widget.engine)) {
      lastGeneration = 0;
      rate.reset();
      clear();
    }
    if (oldWidget.source != widget.source) clear();
  }

  /// How fast the record scrolls, and how fast the axis over it says it does.
  /// See [ColumnRate] — they are deliberately not the same number.
  final ColumnRate rate = ColumnRate();

  /// **Not in `paint`, and that is the whole of what dates the record
  /// correctly.**
  ///
  /// One column is one published measurement, so a column has to be appended
  /// per publish and not per repaint — and repaints are throttled to the
  /// user's frame rate, which at 30 fps against the engine's ~47 Hz drops one
  /// publish in three. Advancing from paint cost two things at once. The
  /// record lost those measurements outright: a spectrogram is a record of
  /// what the signal did, and a column that was never appended is audio the
  /// display cannot be redrawn from later. And [ColumnRate] then measured the
  /// *repaint* rate rather than the publish rate, so the axis over the record
  /// read 30 Hz at 30 fps and 47 Hz at 60 — the same audio dated differently
  /// depending on a display setting, which is the twitch this listener exists
  /// to remove. Worse, 30 Hz stands a 2 s rung at 60.1 px against the 60 px a
  /// label needs, so a quarter of a percent either way changed the whole
  /// labelling from 2 s to 5 s. See [ageInterval].
  ///
  /// [MeterClock.measurements] is unthrottled for exactly this; see its
  /// comment. Nothing here marks the tree dirty — the buffer takes the column
  /// and the image is rebuilt asynchronously, and pixels still arrive on the
  /// clock's throttled notification at the rate the user asked for.
  void _measured() {
    final engine = widget.engine;
    // Generation 0 is "nothing has been measured yet" — see [lastGeneration].
    if (engine.generation == 0 || engine.generation == lastGeneration) return;
    lastGeneration = engine.generation;
    rate.note(engine.elapsedSeconds);
    // Silence still scrolls. The display is a record of time, and holding it
    // still while audio runs would misdate everything already on it.
    append(available ? _stepAt : _silence);
  }

  /// Whether the chosen source is measured on this signal at all. NaN
  /// throughout when it is not — the right, mid or side of a one-channel
  /// input — see `MeterSource.spectrumOf`.
  bool get available =>
      widget.engine.hasSpectrum &&
      !widget.engine.spectrumOf(widget.source)[0].isNaN;

  int _silence(int row) => 0;

  /// The palette step for a pixel row. Row 0 is the top of the display, which
  /// is the top of the frequency range.
  int _stepAt(int row) {
    final band = (_rows > 1)
        ? ((_rows - 1 - row) / (_rows - 1) * (MeterShape.spectrumBands - 1))
              .round()
              .clamp(0, MeterShape.spectrumBands - 1)
        : 0;
    final db = widget.engine.spectrumOf(widget.source)[band];
    if (db <= _floorDb) return 0;
    final level = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(0.0, 1.0);
    return (level * (_steps - 1)).round();
  }

  /// The level range mapped onto the palette. Below the floor is background;
  /// a spectrogram scaled to the full 96 dB the analyser shows would be almost
  /// entirely dark.
  static const double _floorDb = -84;
  static const double _ceilingDb = -6;

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
      // Premultiplied, because `PixelFormat.rgba8888` is — which cost nothing
      // while every ramp entry was opaque and premultiplying was the identity.
      // The skin ramp's floor is transparent now, so its low steps carry real
      // alpha, and straight bytes would draw them at the accent's full strength
      // over a ground that is meant to show through.
      _lut[step * 4] = (color.r * color.a * 255).round();
      _lut[step * 4 + 1] = (color.g * color.a * 255).round();
      _lut[step * 4 + 2] = (color.b * color.a * 255).round();
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
    widget.clock.measurements.removeListener(_measured);
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
    // Transparent at [ColorRamp.skin], where the ground *is* the panel: the
    // rect then paints nothing, and the light `ModuleFrame` lays across the
    // corner reaches the floor of the record the way it reaches the plot of
    // every other module. An opaque copy of the unlit panel cut a rectangle
    // out of that light, and the field read as a lid on the module.
  }) : _background = (Paint()..color = ramp.groundOf(colors)),
       // Nearest-neighbour on purpose: the columns are 1 logical pixel and the
       // usual display scales are integer, so filtering would only blur the
       // newest edge. Antialiasing has no edge to work on either.
       _bitmap = (Paint()
         ..filterQuality = FilterQuality.none
         ..isAntiAlias = false),
       // Ticks in the gutter and the band, never lines across the field. The
       // field *is* the measurement — every pixel of it is a level somebody
       // may read — and a hairline drawn over it is a stripe no audio made,
       // which on a spectrogram is indistinguishable from a tone. The ticks
       // wear the labels' ink, because they are part of the labels.
       _tick = (Paint()
         ..color = colors.textFaint
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _ageStyle = OaaType.tick.copyWith(color: colors.textFaint),
       _border = PlotBorder(colors),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final SpectrumSource source;
  final ColorRamp ramp;
  final _SpectrogramModuleState state;

  final Paint _background;
  final Paint _bitmap;
  final Paint _tick;
  final TextStyle _ageStyle;
  final PlotBorder _border;

  /// How far a tick reaches out from the field, and the gap between it and
  /// its label. Both axes use the same two, so a label sits the same distance
  /// from the field whichever edge it is on.
  static const double _tickLength = Space.xs;
  static const double _tickGap = Space.xxs;

  /// One published measurement is one column. At ~47 Hz that is about 21 ms of
  /// audio per column, so a 600 px module holds roughly thirteen seconds.
  static const double columnWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    // The axes cost a gutter and a band, and a module at its size floor cannot
    // spare either — below this the record is the whole body, exactly as it
    // was before the axes existed. Decided from the size alone, so nothing
    // about the signal can flip the layout.
    final axes = size.width >= 140 && size.height >= 80;
    final gutter = axes ? state._hzInk + _tickGap + _tickLength : 0.0;
    final band = axes
        ? OaaType.tick.fontSize! + _tickGap + _tickLength + Space.xxs
        : 0.0;
    final plot = Rect.fromLTRB(gutter, band, size.width, size.height);

    // The record gives up a hairline on every side and the box sits in what it
    // gave up — see [PlotBorder]. It matters most here: the right-hand edge is
    // where the newest column lands, and a border over it would hide the one
    // column the eye goes to.
    final field = PlotBorder.inside(plot);

    final columns = (field.width / columnWidth).floor();
    final rows = field.height.round();
    if (columns <= 0 || rows <= 0) return;

    state.resize(columns, rows);

    canvas.drawRect(field, _background);

    final image = state._image;
    if (image != null && image.width == columns && image.height == rows) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, columns.toDouble(), rows.toDouble()),
        // Anchored to the right edge, where the newest column lands. The
        // sliver the flooring left over stays background, exactly as it
        // always has.
        Rect.fromLTWH(
          field.right - columns * columnWidth,
          field.top,
          columns * columnWidth,
          field.height,
        ),
        _bitmap,
      );
    }

    // Before the ticks rather than after them: a tick is brighter than the box
    // and runs into it, and the two meeting is what says the tick belongs to
    // the axis it labels.
    _border.paint(canvas, plot);

    if (axes) {
      _paintFrequencyAxis(canvas, field);
      _paintTimeAxis(canvas, field);
    }

    // The record keeps scrolling under it — see `append` — and the notice
    // says what the ground it is scrolling is.
    if (engine.hasSpectrum && !state.available) {
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          field.left + (field.width - mono.longestLine) / 2,
          field.top + (field.height - mono.height) / 2,
        ),
      );
    }
  }

  /// The analyser's [kHzGrid] series down the left edge, each label beside a
  /// tick into the gutter at its band's row — every value that fits, by the
  /// one rule every frequency axis fits by. See [fitHzLabels].
  void _paintFrequencyAxis(Canvas canvas, Rect field) {
    state.solveAxis(field.height);
    final labels = state._hzLabels;

    for (var i = 0; i < kHzGrid.length; i++) {
      if (i >= state._hzLabelled.length || !state._hzLabelled[i]) continue;
      final label = labels[i];
      final y =
          field.bottom -
          bandOfHz(kHzGrid[i]) / MeterShape.spectrumBands * field.height;
      if (y < field.top || y > field.bottom) continue;
      canvas.drawLine(
        Offset(field.left - _tickLength, y),
        Offset(field.left, y),
        _tick,
      );
      canvas.drawParagraph(
        label,
        Offset(
          field.left - _tickLength - _tickGap - label.longestLine,
          (y - label.height / 2).clamp(field.top, field.bottom - label.height),
        ),
      );
    }
  }

  /// How far back the record reaches, as ages along the top: 0 at the right
  /// edge where the newest column lands, a label every rung that keeps them
  /// legibly apart. The rate under it is measured, not assumed, and it is the
  /// *settled* rate rather than the last one measured — see [ColumnRate].
  void _paintTimeAxis(Canvas canvas, Rect field) {
    final secondsPerPixel = state.rate.axisSeconds() / columnWidth;
    final interval = ageInterval(secondsPerPixel, held: state.ageInterval);
    state.ageInterval = interval;
    if (interval == 0) return;

    for (var tick = 1; ; tick++) {
      final x = field.right - tick * interval / secondsPerPixel;
      if (x < field.left + Space.sm) break;
      canvas.drawLine(
        Offset(x, field.top - _tickLength),
        Offset(x, field.top),
        _tick,
      );

      while (state._ageLabels.length < tick) {
        state._ageLabels.add(ValueParagraph());
      }
      final label = state._ageLabels[tick - 1].of(
        ageLabel(tick * interval),
        _ageStyle,
      );
      canvas.drawParagraph(
        label,
        Offset(
          (x - label.longestLine / 2).clamp(
            field.left,
            field.right - label.longestLine,
          ),
          field.top - _tickLength - _tickGap - label.height,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_SpectrogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.source != source ||
      oldDelegate.ramp != ramp ||
      !identical(oldDelegate.engine, engine);
}
