// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Amplitude against time: the signal itself, one lane per channel.
///
/// The other thirteen modules answer a question about the audio. This one shows
/// the audio, which is a different job and the reason it is worth having — a
/// number tells you a transient was 3 dB louder, and the waveform tells you it
/// was a click.
///
/// ---------------------------------------------------------------------------
/// One control, two displays, and why that is not two controls
///
/// [ScopeTimeBase] sets how much time the width holds, and that alone decides
/// how the window is found. Below 200 ms the display is **triggered**: the
/// module looks back through the samples it has kept for the most recent rising
/// zero crossing and draws forward from there, so a periodic signal stands
/// still and can be read. Above it the display **rolls**, scrolling right to
/// left the way a DAW draws a waveform.
///
/// Neither works at the other's end of the range. A rolling display advances by
/// one published measurement at a time — 21 ms of audio — so at 200 ms a fifth
/// of the width lands at once and the picture lurches rather than scrolls; and
/// a triggered display has to hold its whole span in memory plus somewhere to
/// search before it, which is not a thing to do with five seconds of audio at
/// 192 kHz. Making the fold automatic is the same call a scope's roll mode
/// makes, for the same reason.
///
/// Independently of that, a column of the display is drawn as a min/max pair
/// when more than one sample lands in it and as a plain trace when fewer than
/// one does. That is arithmetic rather than a mode: at 5 ms across 600 pixels
/// there are 0.4 samples per pixel and the honest picture is the line between
/// them; at 1 s there are eighty, and drawing one of the eighty would be
/// choosing a sample to believe.
///
/// ---------------------------------------------------------------------------
/// It needs nothing from the engine, and that costs it one thing from the clock
///
/// `oaa_snapshot.scope` already carries the last 1024 stereo frames, published
/// once per analysis block — and an analysis block *is* 1024 frames, so
/// consecutive publishes are contiguous: no overlap to deduplicate and no gap
/// to invent. Everything below is built on that buffer, so the module works
/// unchanged on a tablet reading a socket, and adding it moved neither
/// `OAA_ABI_VERSION` nor the wire protocol.
///
/// **A publish nobody reads is gone, though.** `oaa_snapshot_acquire` is a
/// seqlock with one slot, so contiguity holds only for a reader that sees every
/// publish — and the meters repaint at a rate the user chooses. At 30 fps the
/// reader asks every 33 ms against a publish every 21 ms and loses one in
/// three. Folded in from `paint`, this module would have drawn a third of its
/// width as holes and never accumulated enough to fill a window longer than one
/// buffer. So it consumes from `MeterClock.measurements`, which is unthrottled,
/// and paints on the throttled notification like everything else. That channel
/// exists for this module and its comment says why.
///
/// What is left is checked rather than assumed, because three things still
/// break contiguity: a device hands over whatever has arrived, which is usually
/// fewer than 1024 frames; a file or a plugin pushes whatever block size it
/// has, which can be more; and a link that drops a frame loses one outright.
/// [MeterSource.elapsedSeconds] is the engine's own count of measured frames
/// divided by the sample rate, so the difference between two reads is exactly
/// how much new audio there was — fewer frames than the buffer holds means take
/// the newest few, more means the rest was measured and never carried here.
/// Those become blank columns. They are not filled in with what happens to
/// still be sitting in the buffer.
///
/// ---------------------------------------------------------------------------
/// Two lanes, not two colours
///
/// Left over right, each around its own centre line, rather than both traces
/// overlaid in different colours. Overlaid works at 5 ms and turns into mud at
/// one second, which is the setting this module opens on; and a channel told
/// apart by hue stops being told apart in a skin that moves the hues. A mono
/// source draws one lane, because `oaa_scope_append` copies the left channel
/// into both and two identical lanes would be a stereo image nobody has.
///
/// Anything that reached full scale is drawn in the over colour, so a clipped
/// passage is visible as a red band rather than as a flat top somebody has to
/// notice.
class OscilloscopeModule extends StatefulWidget {
  const OscilloscopeModule({
    required this.engine,
    required this.clock,
    this.timeBase = ScopeTimeBase.s1,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// How much time the width holds. See [ScopeTimeBase] — it also decides
  /// whether the window is triggered or rolling.
  final ScopeTimeBase timeBase;

  @override
  State<OscilloscopeModule> createState() => _OscilloscopeModuleState();
}

/// Vertical graticule divisions across the width, the scope convention.
const int _divisions = 10;

/// A division narrower than this is a hatch pattern rather than a graticule.
const double _minDivision = Space.lg;

/// Lane height below which the half-scale lines are more clutter than scale.
const double _halfScaleAbove = Space.xxl;

/// Lane height below which the channel letter has nowhere to sit.
const double _laneLabelAbove = Space.lg;

/// Where a segment the painter is not using is parked.
///
/// The buffers handed to `drawRawPoints` are always passed whole, because
/// `Float32List.sublistView` would allocate a view per call per lane on the
/// paint path. The entries past the last real one are filled with this
/// instead: both ends of the segment are the same point, which draws nothing
/// at all, and the point is outside the module, which draws nothing twice.
const double _parked = -1;

class _OscilloscopeModuleState extends State<OscilloscopeModule> {
  final _ScopeHistory _history = _ScopeHistory();

  ui.Paragraph? _leftLabel;
  ui.Paragraph? _rightLabel;
  ui.Paragraph? _spanLabel;
  Color? _builtColor;
  ScopeTimeBase? _builtSpan;

  @override
  void initState() {
    super.initState();
    widget.clock.measurements.addListener(_measured);
  }

  @override
  void didUpdateWidget(OscilloscopeModule old) {
    super.didUpdateWidget(old);
    if (!identical(old.clock, widget.clock)) {
      old.clock.measurements.removeListener(_measured);
      widget.clock.measurements.addListener(_measured);
    }
    // A different source is a different programme, and its elapsed clock has
    // no relationship to the one on screen — the desktop swaps its engine for
    // a plugin's decoded frames the moment a DAW connects. Keeping the old
    // waveform would draw one session's audio onto the end of another's.
    if (!identical(old.engine, widget.engine)) _history.reset();
  }

  @override
  void dispose() {
    widget.clock.measurements.removeListener(_measured);
    super.dispose();
  }

  /// **Not in `paint`, unlike the other three modules that keep a history.**
  ///
  /// They advance by a column per measurement they were *painted* for, so a
  /// throttled repaint costs them resolution. This one advances by however
  /// much time the measurement carried, so a throttled repaint costs it the
  /// audio itself — at 30 fps one publish in three, which on a time axis is a
  /// hole rather than a coarser picture, and which leaves a window longer than
  /// one buffer unable to fill at all. `MeterClock.measurements` is
  /// unthrottled for exactly this; see its comment.
  ///
  /// Nothing here marks the tree dirty. Pixels still arrive on the clock's
  /// throttled notification, at the rate the user asked for.
  void _measured() => _history.ingest(widget.engine);

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtColor != colors.textFaint || _builtSpan != widget.timeBase) {
      _builtColor = colors.textFaint;
      _builtSpan = widget.timeBase;
      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _leftLabel = layoutParagraph('L', style);
      _rightLabel = layoutParagraph('R', style);
      _spanLabel = layoutParagraph(widget.timeBase.label, style);
    }

    return MeterBody(
      painter: _OscilloscopePainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        timeBase: widget.timeBase,
        repaint: widget.clock,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The history
// ---------------------------------------------------------------------------

/// How much audio the module keeps for the triggered display.
///
/// The longest triggered span plus somewhere to search before it. Sized in
/// seconds rather than frames because the whole point is to hold a span the
/// user chose in seconds, at whatever rate the source turns out to run at: at
/// 48 kHz this is 14,400 frames and at 192 kHz it is 57,600, and both are the
/// same 0.3 s of signal.
const double _keptSeconds = 0.3;

/// The furthest back a trigger may be found, so the picture is never more than
/// a couple of published measurements stale.
const double _searchSeconds = 0.03;

/// Below this peak there is nothing to lock on to and the display free-runs,
/// which is what a scope does rather than triggering on a noise floor.
const double _triggerFloor = 1e-4;

/// The trigger's hysteresis, as a fraction of the peak in the search window.
///
/// Relative rather than absolute so that a quiet passage still triggers and a
/// loud one does not trigger on the ripple riding on it. The *level* stays at
/// zero — a rising zero crossing is what makes the drawn waveform start in the
/// same place every time.
const double _triggerHysteresis = 0.05;

/// What the painter draws, kept between frames.
///
/// Separated from the painter because a painter is rebuilt on every `build` and
/// this is the module's memory. Two things live here: a ring of raw frames,
/// which the triggered display searches and slices; and a ring of min/max
/// columns, which the rolling display scrolls. Only one is fed at a time.
///
/// Both are bounded — the raw ring by [_keptSeconds] and the column ring by the
/// module's own width — because a display that keeps history in proportion to
/// how long it has been open is the defect that once took this application to
/// 266 GB. See the header of `spectrogram.dart`.
class _ScopeHistory {
  /// Interleaved (L, R), oldest at [_rawWrite] once full.
  Float32List _raw = Float32List(0);
  int _rawFrames = 0;
  int _rawWrite = 0;
  int _rawFilled = 0;

  /// One min/max pair per column, per channel. NaN is a column no audio was
  /// published for, and it is drawn as a gap rather than as silence.
  Float32List _minL = Float32List(0);
  Float32List _maxL = Float32List(0);
  Float32List _minR = Float32List(0);
  Float32List _maxR = Float32List(0);

  /// Samples, when a column holds fewer than one of them.
  Float32List _traceL = Float32List(0);
  Float32List _traceR = Float32List(0);

  /// Written by the painter, read back by it. `x, y, x, y` per column.
  Float32List segments = Float32List(0);
  Float32List overSegments = Float32List(0);

  int _columns = 0;
  int _sampleRate = 0;
  ScopeTimeBase? _base;

  /// Next column to write, which in a full ring is also the oldest.
  int _cursor = 0;

  /// Frames folded into the column being built, and its running extremes.
  double _fill = 0;
  double _pMinL = 0;
  double _pMaxL = 0;
  double _pMinR = 0;
  double _pMaxR = 0;
  bool _pEmpty = true;

  /// −1 until the first measurement, so the first difference is not taken
  /// against a zero that means "unknown" rather than "the start".
  double _elapsed = -1;

  bool _dirty = true;

  /// Column `i` from the left edge is at `(origin + i) % columns`.
  int origin = 0;

  /// Points in [_traceL] / [_traceR], or zero when the display is columns.
  int traceCount = 0;

  Float32List get minL => _minL;
  Float32List get maxL => _maxL;
  Float32List get minR => _minR;
  Float32List get maxR => _maxR;
  Float32List get traceL => _traceL;
  Float32List get traceR => _traceR;
  int get columns => _columns;

  /// Frames of audio one column of the rolling display covers.
  double get _framesPerColumn => _columns == 0 || _base == null
      ? 0
      : _base!.seconds * _sampleRate / _columns;

  /// Sizes the buffers, and clears them when the shape of the display changed.
  ///
  /// A different width or a different span is a different set of columns and
  /// none of the old ones mean anything at the new scale. Redrawing them anyway
  /// would show the last screen stretched or squeezed for as long as it took to
  /// scroll off, which reads as the meter having glitched. The spectrogram
  /// clears on a resize for the same reason.
  void configure({
    required int columns,
    required ScopeTimeBase base,
    required int sampleRate,
  }) {
    if (columns == _columns && base == _base && sampleRate == _sampleRate) {
      return;
    }

    final kept = sampleRate <= 0 ? 0 : (sampleRate * _keptSeconds).ceil();
    if (kept != _rawFrames) {
      _raw = Float32List(kept * 2);
      _rawFrames = kept;
      _rawWrite = 0;
      _rawFilled = 0;
    }

    if (columns != _columns) {
      _minL = Float32List(columns);
      _maxL = Float32List(columns);
      _minR = Float32List(columns);
      _maxR = Float32List(columns);
      _traceL = Float32List(columns);
      _traceR = Float32List(columns);
      segments = Float32List(columns * 4);
      overSegments = Float32List(columns * 4);
      _columns = columns;
    }

    _base = base;
    _sampleRate = sampleRate;
    _clearColumns();
    _dirty = true;
  }

  /// Forgets everything, for a source that has no relationship to the last.
  void reset() {
    _rawWrite = 0;
    _rawFilled = 0;
    _elapsed = -1;
    _clearColumns();
    _dirty = true;
  }

  /// Folds one published measurement in.
  void ingest(MeterSource engine) {
    // Measurements arrive before the first paint, which is what configures
    // this. There is nothing yet to fold them into, and nothing on screen for
    // them to be missing from.
    if (_base == null) return;

    final scope = engine.scope;
    final published = scope.length ~/ 2;
    if (_sampleRate <= 0 || _rawFrames == 0 || published == 0) return;

    final elapsed = engine.elapsedSeconds;
    if (elapsed.isNaN) return;

    if (_elapsed < 0 || elapsed < _elapsed) {
      // The first measurement, or the engine was reset under us. Neither can be
      // folded into what is on screen: the arithmetic below turns elapsed time
      // into a count of new frames, and across a reset that count is a negative
      // number of samples nobody played.
      _elapsed = elapsed;
      _rawWrite = 0;
      _rawFilled = 0;
      _clearColumns();
      _dirty = true;
      return;
    }

    final fresh = ((elapsed - _elapsed) * _sampleRate).round();
    _elapsed = elapsed;
    if (fresh <= 0) return;

    final taken = fresh < published ? fresh : published;
    final missed = fresh - taken;
    final first = published - taken;

    if (missed > 0) {
      // More audio was measured than one publish of the scope carries — a file
      // pushed through faster than real time, or a device that overran. Those
      // samples were never published and this module will not pretend they
      // were: the raw ring can no longer claim to be contiguous, and the
      // rolling display gets that many columns of nothing.
      _rawWrite = 0;
      _rawFilled = 0;
      _rollGap(missed);
    }

    _appendRaw(scope, first, taken);
    if (!_base!.isTriggered) _rollAudio(scope, first, taken);
    _dirty = true;
  }

  /// Works out what the painter draws, once per change rather than per frame.
  void resolve() {
    if (!_dirty) return;
    _dirty = false;
    traceCount = 0;

    if (_base == null || _columns == 0) return;

    if (!_base!.isTriggered) {
      // The rolling display is already in the columns; the oldest is the one
      // about to be overwritten.
      origin = _cursor;
      return;
    }

    origin = 0;
    _blankColumns();

    final span = (_base!.seconds * _sampleRate).round();
    // One frame of slack, so the window always has a sample before it for the
    // crossing test rather than starting on the oldest frame there is.
    if (span < 2 || _rawFilled < span + 1) return;

    final latest = _rawFilled - span;
    final search = math.min(
      latest,
      math.max(span, (_sampleRate * _searchSeconds).round()),
    );
    final start = _findTrigger(latest, search);

    if (span < _columns) {
      _readTrace(start, span);
    } else {
      _readColumns(start, span);
    }
  }

  // --- Filling ------------------------------------------------------------

  void _appendRaw(Float32List scope, int first, int count) {
    var from = first;
    var left = count;
    if (left > _rawFrames) {
      // More than the ring holds. Keep the newest of it and drop the rest,
      // which is what the ring was going to do anyway.
      from += left - _rawFrames;
      left = _rawFrames;
    }
    while (left > 0) {
      final room = _rawFrames - _rawWrite;
      final take = left < room ? left : room;
      _raw.setRange(_rawWrite * 2, (_rawWrite + take) * 2, scope, from * 2);
      _rawWrite = (_rawWrite + take) % _rawFrames;
      from += take;
      left -= take;
    }
    _rawFilled = math.min(_rawFilled + count, _rawFrames);
  }

  void _rollAudio(Float32List scope, int first, int count) {
    final perColumn = _framesPerColumn;
    if (perColumn <= 0) return;

    for (var i = 0; i < count; i++) {
      final l = scope[(first + i) * 2];
      final r = scope[(first + i) * 2 + 1];
      if (_pEmpty) {
        _pMinL = _pMaxL = l;
        _pMinR = _pMaxR = r;
        _pEmpty = false;
      } else {
        if (l < _pMinL) {
          _pMinL = l;
        } else if (l > _pMaxL) {
          _pMaxL = l;
        }
        if (r < _pMinR) {
          _pMinR = r;
        } else if (r > _pMaxR) {
          _pMaxR = r;
        }
      }

      _fill += 1;
      if (_fill >= perColumn) {
        _fill -= perColumn;
        _pushColumn();
      }
    }
  }

  void _rollGap(int frames) {
    final perColumn = _framesPerColumn;
    if (perColumn <= 0) return;
    final blank = (frames / perColumn).round();
    if (blank >= _columns) {
      _clearColumns();
      return;
    }
    _pushColumn();
    for (var i = 0; i < blank; i++) {
      _pushBlank();
    }
    _fill = 0;
  }

  void _pushColumn() {
    if (_pEmpty) {
      _pushBlank();
      return;
    }
    _minL[_cursor] = _pMinL;
    _maxL[_cursor] = _pMaxL;
    _minR[_cursor] = _pMinR;
    _maxR[_cursor] = _pMaxR;
    _cursor = (_cursor + 1) % _columns;
    _pEmpty = true;
  }

  void _pushBlank() {
    _minL[_cursor] = double.nan;
    _maxL[_cursor] = double.nan;
    _minR[_cursor] = double.nan;
    _maxR[_cursor] = double.nan;
    _cursor = (_cursor + 1) % _columns;
  }

  void _clearColumns() {
    _blankColumns();
    _cursor = 0;
    _fill = 0;
    _pEmpty = true;
    origin = 0;
    traceCount = 0;
  }

  void _blankColumns() {
    _minL.fillRange(0, _minL.length, double.nan);
    _maxL.fillRange(0, _maxL.length, double.nan);
    _minR.fillRange(0, _minR.length, double.nan);
    _maxR.fillRange(0, _maxR.length, double.nan);
  }

  // --- Reading ------------------------------------------------------------

  /// The ring slot holding the frame [age] positions after the oldest kept one.
  int _slot(int age) =>
      (_rawWrite - _rawFilled + age + _rawFrames * 2) % _rawFrames;

  /// The most recent rising zero crossing at or before [latest], or [latest].
  ///
  /// Two passes rather than one because the hysteresis is a fraction of the
  /// peak and the peak is not known until the window has been walked. Both are
  /// bounded by [_searchSeconds] of audio.
  int _findTrigger(int latest, int search) {
    final from = latest - search;

    var peak = 0.0;
    var at = _slot(from);
    for (var k = from; k <= latest; k++) {
      final mid = (_raw[at * 2] + _raw[at * 2 + 1]) * 0.5;
      final level = mid < 0 ? -mid : mid;
      if (level > peak) peak = level;
      if (++at == _rawFrames) at = 0;
    }
    if (peak < _triggerFloor) return latest;

    final gate = peak * _triggerHysteresis;
    var armed = false;
    var found = -1;
    at = _slot(from);
    for (var k = from; k <= latest; k++) {
      final mid = (_raw[at * 2] + _raw[at * 2 + 1]) * 0.5;
      if (armed) {
        if (mid >= gate) {
          found = k;
          armed = false;
        }
      } else if (mid <= -gate) {
        armed = true;
      }
      if (++at == _rawFrames) at = 0;
    }
    return found < 0 ? latest : found;
  }

  /// [span] frames from [start], one point per sample.
  void _readTrace(int start, int span) {
    var at = _slot(start);
    for (var i = 0; i < span; i++) {
      _traceL[i] = _raw[at * 2];
      _traceR[i] = _raw[at * 2 + 1];
      if (++at == _rawFrames) at = 0;
    }
    traceCount = span;
  }

  /// [span] frames from [start], as one min/max pair per column.
  void _readColumns(int start, int span) {
    var at = _slot(start);
    for (var column = 0; column < _columns; column++) {
      final until = ((column + 1) * span) ~/ _columns;
      var lo = _raw[at * 2];
      var hi = lo;
      var loR = _raw[at * 2 + 1];
      var hiR = loR;

      for (var k = (column * span) ~/ _columns; k < until; k++) {
        final l = _raw[at * 2];
        final r = _raw[at * 2 + 1];
        if (l < lo) {
          lo = l;
        } else if (l > hi) {
          hi = l;
        }
        if (r < loR) {
          loR = r;
        } else if (r > hiR) {
          hiR = r;
        }
        if (++at == _rawFrames) at = 0;
      }

      _minL[column] = lo;
      _maxL[column] = hi;
      _minR[column] = loR;
      _maxR[column] = hiR;
    }
  }
}

// ---------------------------------------------------------------------------
// The painter
// ---------------------------------------------------------------------------

class _OscilloscopePainter extends MeterPainter {
  _OscilloscopePainter({
    required this.engine,
    required this.colors,
    required this.state,
    required this.timeBase,
    required Listenable repaint,
  }) : _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _centre = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline),
       _signal = (Paint()
         ..color = colors.accent
         ..strokeWidth = OaaStroke.hairline
         ..strokeCap = StrokeCap.butt),
       _over = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.hairline
         ..strokeCap = StrokeCap.butt),
       _overMark = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.butt),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _OscilloscopeModuleState state;
  final ScopeTimeBase timeBase;

  final Paint _grid;
  final Paint _centre;
  final Paint _signal;
  final Paint _over;
  final Paint _overMark;

  @override
  void paint(Canvas canvas, Size size) {
    final columns = size.width.floor();
    if (columns < 2 || size.height < _laneLabelAbove) return;

    final history = state._history;
    history.configure(
      columns: columns,
      base: timeBase,
      sampleRate: engine.sampleRate,
    );

    // Note what is *not* here: the audio was folded in by
    // `_OscilloscopeModuleState._measured`, off the clock's unthrottled
    // measurement channel. Paint also runs on a resize and on a theme change,
    // and a display that advanced on those would invent time no audio passed
    // through — the same rule the other history modules reach by gating on
    // `generation`, from the other end.
    history.resolve();

    final lanes = engine.channels >= 2 ? 2 : 1;
    final gap = lanes > 1 ? Space.xs : 0.0;
    final laneHeight = (size.height - gap * (lanes - 1)) / lanes;
    if (laneHeight < OaaStroke.mark * 2) return;

    _paintGrid(canvas, size, lanes, laneHeight, gap);

    for (var lane = 0; lane < lanes; lane++) {
      final centre = lane * (laneHeight + gap) + laneHeight / 2;
      // Inset by the stroke so a full-scale sample is drawn inside the lane
      // rather than half outside it, where the clip takes it.
      final half = laneHeight / 2 - OaaStroke.hairline;
      final low = lane == 0 ? history.minL : history.minR;
      final high = lane == 0 ? history.maxL : history.maxR;

      if (history.traceCount > 0) {
        _paintTrace(
          canvas,
          size,
          history,
          lane == 0 ? history.traceL : history.traceR,
          centre,
          half,
        );
      } else {
        _paintColumns(canvas, history, low, high, centre, half);
      }
    }

    _paintLabels(canvas, size, lanes, laneHeight, gap);
  }

  // --- Chrome -------------------------------------------------------------

  void _paintGrid(
    Canvas canvas,
    Size size,
    int lanes,
    double laneHeight,
    double gap,
  ) {
    if (size.width / _divisions >= _minDivision) {
      for (var i = 1; i < _divisions; i++) {
        final x = (size.width * i / _divisions).roundToDouble();
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), _grid);
      }
    }

    for (var lane = 0; lane < lanes; lane++) {
      final centre = lane * (laneHeight + gap) + laneHeight / 2;
      canvas.drawLine(Offset(0, centre), Offset(size.width, centre), _centre);
      if (laneHeight >= _halfScaleAbove) {
        final quarter = laneHeight / 4;
        canvas.drawLine(
          Offset(0, centre - quarter),
          Offset(size.width, centre - quarter),
          _grid,
        );
        canvas.drawLine(
          Offset(0, centre + quarter),
          Offset(size.width, centre + quarter),
          _grid,
        );
      }
    }
  }

  void _paintLabels(
    Canvas canvas,
    Size size,
    int lanes,
    double laneHeight,
    double gap,
  ) {
    // Below this there is nowhere for a letter or a number to sit that is not
    // on top of the waveform, and a module this small has already given up its
    // graticule for the same reason. What it loses is chrome; what it keeps is
    // the signal, which is the right way round.
    if (laneHeight < _laneLabelAbove) return;

    // Only when there are two of them. The letter distinguishes one lane from
    // the other, and a mono source draws one lane — labelling it `L` would
    // name a channel rather than the sum it is actually showing.
    if (lanes > 1) {
      for (var lane = 0; lane < lanes; lane++) {
        final label = lane == 0 ? state._leftLabel : state._rightLabel;
        if (label == null) continue;
        canvas.drawParagraph(
          label,
          Offset(Space.xs, lane * (laneHeight + gap) + Space.xxs),
        );
      }
    }

    // The span, bottom right, over the graticule rather than in an axis row of
    // its own — a three-row module has no vertical space to spend on one, and
    // the number it would carry is the only thing an axis row would say.
    final span = state._spanLabel;
    if (span != null) {
      canvas.drawParagraph(
        span,
        Offset(
          size.width - span.longestLine - Space.xs,
          size.height - span.height - Space.xxs,
        ),
      );
    }
  }

  // --- The signal ---------------------------------------------------------

  void _paintColumns(
    Canvas canvas,
    _ScopeHistory history,
    Float32List low,
    Float32List high,
    double centre,
    double half,
  ) {
    final columns = history.columns;
    final segments = history.segments;
    final over = history.overSegments;
    var drawn = 0;
    var clipped = 0;

    for (var i = 0; i < columns; i++) {
      final slot = (history.origin + i) % columns;
      final hi = high[slot];
      // A column no audio was published for. Left as a gap, because the
      // alternative is drawing whatever the neighbouring samples were doing
      // across a stretch of time nobody measured.
      if (hi.isNaN) continue;
      final lo = low[slot];

      final x = i + 0.5;
      final top = centre - hi.clamp(-1.0, 1.0) * half;
      var bottom = centre - lo.clamp(-1.0, 1.0) * half;
      // A column whose extremes are equal — silence, or a held DC level — is a
      // zero-length segment, which draws nothing at all. A flat line is the
      // correct picture of a flat signal, so give it a pixel to be drawn in.
      if (bottom - top < OaaStroke.hairline) {
        bottom = top + OaaStroke.hairline;
      }

      if (hi >= 1.0 || lo <= -1.0) {
        over[clipped * 4] = x;
        over[clipped * 4 + 1] = top;
        over[clipped * 4 + 2] = x;
        over[clipped * 4 + 3] = bottom;
        clipped++;
      } else {
        segments[drawn * 4] = x;
        segments[drawn * 4 + 1] = top;
        segments[drawn * 4 + 2] = x;
        segments[drawn * 4 + 3] = bottom;
        drawn++;
      }
    }

    segments.fillRange(drawn * 4, segments.length, _parked);
    canvas.drawRawPoints(ui.PointMode.lines, segments, _signal);
    if (clipped > 0) {
      over.fillRange(clipped * 4, over.length, _parked);
      canvas.drawRawPoints(ui.PointMode.lines, over, _over);
    }
  }

  /// One point per sample, joined — the picture when a column holds fewer than
  /// one sample and there is nothing to take a minimum and a maximum of.
  ///
  /// Drawn as separate segments rather than as a `PointMode.polygon`, so that
  /// the unused tail of the buffer can be parked off-canvas and the whole
  /// buffer passed. A polygon would join the last real point to whatever the
  /// padding was and stroke a line across the module to get there.
  void _paintTrace(
    Canvas canvas,
    Size size,
    _ScopeHistory history,
    Float32List samples,
    double centre,
    double half,
  ) {
    final count = history.traceCount;
    if (count < 2) return;

    final line = history.segments;
    final marks = history.overSegments;
    final step = (size.width - 1) / (count - 1);
    var clipped = 0;
    var previousX = 0.0;
    var previousY = centre - samples[0].clamp(-1.0, 1.0) * half;

    for (var i = 1; i < count; i++) {
      final value = samples[i].clamp(-1.0, 1.0);
      final x = i * step;
      final y = centre - value * half;

      line[(i - 1) * 4] = previousX;
      line[(i - 1) * 4 + 1] = previousY;
      line[(i - 1) * 4 + 2] = x;
      line[(i - 1) * 4 + 3] = y;
      previousX = x;
      previousY = y;

      // A tick rather than a point, so that the parked tail of the buffer is
      // a run of zero-length lines the rasteriser drops rather than a run of
      // squares it has to draw and clip.
      if (value <= -1.0 || value >= 1.0) {
        marks[clipped * 4] = x;
        marks[clipped * 4 + 1] = y - OaaStroke.mark;
        marks[clipped * 4 + 2] = x;
        marks[clipped * 4 + 3] = y + OaaStroke.mark;
        clipped++;
      }
    }

    line.fillRange((count - 1) * 4, line.length, _parked);
    canvas.drawRawPoints(ui.PointMode.lines, line, _signal);
    if (clipped > 0) {
      marks.fillRange(clipped * 4, marks.length, _parked);
      canvas.drawRawPoints(ui.PointMode.lines, marks, _overMark);
    }
  }

  @override
  bool shouldRepaint(_OscilloscopePainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.timeBase != timeBase ||
      !identical(oldDelegate.engine, engine);
}
