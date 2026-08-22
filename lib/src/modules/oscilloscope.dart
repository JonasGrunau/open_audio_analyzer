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
/// unchanged on a tablet reading a socket.
///
/// **Read [MeterSource.scopeFrames], never `scope.length`.** Over a wire the
/// list is allocated at the protocol's maximum and only partly filled. That
/// coincidence of 1024 with 1024 is also exactly what a remote display cannot
/// have: its link runs at 15, 30 or 60 Hz against an engine measuring at about
/// 47, so a frame stands for more audio than one block holds and the host sends
/// what actually elapsed. This module was the reason that had to change — it
/// detected the shortfall correctly and cleared its ring every single frame,
/// which reads as a scope that will not draw rather than as a link that is
/// starving it.
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
/// Two lanes by default, and never two hues
///
/// Left over right, each around its own centre line, is what the module opens
/// on: two traces around one line are one thick trace until somebody has been
/// told otherwise, and at a second across the width they turn into mud.
/// [ScopeStereo] offers the overlaid arrangement anyway, because at 5 ms it is
/// the one that answers the question — what is the *difference* between the
/// channels — and it buys the trace twice the height. The two are told apart
/// by weight and never by hue: a skin moves the hues, and a picture that
/// depends on one stops working in a skin somebody chose.
///
/// A mono source draws one trace either way, because `oaa_scope_append` copies
/// the left channel into both and two identical traces would be a stereo image
/// nobody has.
///
/// [ScopeZoom] scales what is drawn and nothing that is measured. Anything that
/// reached full scale is drawn in the over colour whatever the zoom is set to,
/// so a clipped passage is visible as a red band rather than as a flat top
/// somebody has to notice — and a trace running off the lane is a trace that is
/// zoomed, which is a different thing and looks like one.
class OscilloscopeModule extends StatefulWidget {
  const OscilloscopeModule({
    required this.engine,
    required this.clock,
    this.timeBase = ScopeTimeBase.s1,
    this.sync = ScopeSync.free,
    this.division = ScopeDivision.bar1,
    this.grid = ScopeGrid.straight,
    this.stereo = ScopeStereo.lanes,
    this.zoom = ScopeZoom.x1,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// How much time the width holds. See [ScopeTimeBase] — it also decides
  /// whether the window is triggered or rolling.
  final ScopeTimeBase timeBase;

  /// What the window is locked to. See [ScopeSync].
  final ScopeSync sync;

  /// The musical width, when [sync] is [ScopeSync.tempo]. See [ScopeDivision].
  final ScopeDivision division;

  /// Straight, triplet or dotted, applied to [division]. See [ScopeGrid].
  final ScopeGrid grid;

  /// Two lanes or one. See [ScopeStereo].
  final ScopeStereo stereo;

  /// How tall full scale is drawn. See [ScopeZoom].
  final ScopeZoom zoom;

  @override
  State<OscilloscopeModule> createState() => _OscilloscopeModuleState();
}

/// Vertical graticule divisions across the width, the scope convention.
const int _divisions = 10;

/// The most beats a tempo-locked window is divided into. Four bars of 4/4 is
/// sixteen lines; past that they are hatching rather than a graticule, and the
/// width check below drops them anyway.
const int _maxBeatDivisions = 16;

/// A division narrower than this is a hatch pattern rather than a graticule.
const double _minDivision = Space.lg;

/// Lane height below which the half-scale lines are more clutter than scale.
const double _halfScaleAbove = Space.xxl;

/// Lane height below which the channel letter has nowhere to sit.
const double _laneLabelAbove = Space.lg;

/// The weight the second of two overlaid channels is drawn at.
///
/// Alpha and not a hue — see [ScopeStereo]. Enough of a step that the two
/// traces are separable where they cross, and not so much that the right
/// channel reads as a shadow of the left.
const double _dim = 0.55;

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

  /// The same two letters in the two inks the traces are drawn in, for the
  /// overlaid arrangement.
  ///
  /// Two traces around one centre line need a legend or they are one thick
  /// trace, and the legend has to be the thing that tells them apart — which
  /// here is weight, because a hue would not survive a change of skin. Faint
  /// letters beside each other would name the channels without saying which is
  /// which.
  ui.Paragraph? _leftKey;
  ui.Paragraph? _rightKey;

  ui.Paragraph? _spanLabel;

  /// The same corner, saying what a tempo-locked window is a window *of*.
  ///
  /// Both are laid out, and `paint` picks — because which one is true depends
  /// on whether the host is offering a tempo *this frame*, and a label built in
  /// `build` would still say `1 bar` for as long as it took something else to
  /// rebuild the tree after a DAW went away.
  ui.Paragraph? _divisionLabel;

  Color? _builtColor;
  Color? _builtAccent;
  ScopeTimeBase? _builtSpan;
  String? _builtDivision;

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

    final division = widget.grid == ScopeGrid.straight
        ? widget.division.label
        : '${widget.division.label} ${widget.grid.label.substring(0, 1)}';

    if (_builtColor != colors.textFaint ||
        _builtAccent != colors.accent ||
        _builtSpan != widget.timeBase ||
        _builtDivision != division) {
      _builtColor = colors.textFaint;
      _builtAccent = colors.accent;
      _builtSpan = widget.timeBase;
      _builtDivision = division;
      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _leftLabel = layoutParagraph('L', style);
      _rightLabel = layoutParagraph('R', style);
      _leftKey = layoutParagraph(
        'L',
        OaaType.tick.copyWith(color: colors.accent),
      );
      _rightKey = layoutParagraph(
        'R',
        OaaType.tick.copyWith(color: colors.accent.withValues(alpha: _dim)),
      );
      _spanLabel = layoutParagraph(widget.timeBase.label, style);
      _divisionLabel = layoutParagraph(division, style);
    }

    return MeterBody(
      painter: _OscilloscopePainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        timeBase: widget.timeBase,
        sync: widget.sync,
        division: widget.division,
        grid: widget.grid,
        stereo: widget.stereo,
        zoom: widget.zoom,
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

  /// Written by the painter, read back by it. `x, y, x, y` per column when
  /// the display is columns; `x, y` per sample when it is a trace.
  Float32List segments = Float32List(0);
  Float32List overSegments = Float32List(0);

  /// The used prefix of [segments], for the trace's single polyline.
  ///
  /// A polyline has no tail to park — every point in the buffer is joined to
  /// the next, so a parked one would be stroked to and back. The view is cut
  /// once and kept, because the length only changes when the span, the width
  /// or the sample rate does; cutting it per lane per frame is the allocation
  /// on the paint path this module does not make.
  Float32List _polyline = Float32List(0);

  Float32List polyline(int points) {
    if (_polyline.length != points * 2) {
      _polyline = Float32List.sublistView(segments, 0, points * 2);
    }
    return _polyline;
  }

  int _columns = 0;
  int _sampleRate = 0;
  ScopeTimeBase? _base;

  /// The width of a tempo-locked window in quarter notes, or null when the
  /// display is free-running.
  ///
  /// Quarters and not seconds, deliberately: the column a sample lands in is
  /// its *musical* position, so a tempo that drifts moves the audio through the
  /// window without moving the window. Seconds here would re-cut the display
  /// every time the host nudged its tempo.
  double? _quarters;

  /// The column the phase-locked display is currently filling, or -1.
  int _syncedColumn = -1;

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
    required double? quarters,
  }) {
    if (columns == _columns &&
        base == _base &&
        sampleRate == _sampleRate &&
        quarters == _quarters) {
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
      // The view above is into the buffer that has just been replaced.
      _polyline = Float32List(0);
      _columns = columns;
    }

    _base = base;
    _sampleRate = sampleRate;
    _quarters = quarters;
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
    // Not `scope.length`: over a wire the list is allocated at the protocol's
    // maximum and only partly filled, and how much of it is this measurement's
    // is the difference between a contiguous trace and one that resets every
    // frame. See `MeterSource.scopeFrames`.
    final published = engine.scopeFrames;
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

    // A phase-locked display searches for nothing and scrolls nowhere, so it
    // needs neither the raw ring nor the rolling cursor — every sample goes
    // straight to the column its musical position falls in.
    if (_quarters != null) {
      _rollSynced(engine, scope, first, taken);
      _dirty = true;
      return;
    }

    _appendRaw(scope, first, taken);
    if (!_base!.isTriggered) _rollAudio(scope, first, taken);
    _dirty = true;
  }

  /// Folds new audio into the columns its *musical* position falls in.
  ///
  /// The whole of tempo sync. Each sample's position in quarter notes is the
  /// playhead at the start of the block plus however many samples into it the
  /// sample is; the column is where that lands inside one window of the chosen
  /// division. A pass over the window therefore overwrites the previous pass in
  /// place, and anything periodic with the bar — a kick, a gate, the attack of
  /// a loop — is drawn in the same column every time and stands still.
  ///
  /// **Nothing is written while the transport is parked.** A stopped playhead
  /// reports the same position for every block, so every sample would land in
  /// one column and pile the room tone of a stopped session into a single
  /// stripe. A frozen picture is the honest one: it is what was last played.
  void _rollSynced(
    MeterSource engine,
    Float32List scope,
    int first,
    int count,
  ) {
    final transport = engine.transport;
    if (!transport.isPlaying) return;

    final quartersPerFrame = transport.bpm / 60 / _sampleRate;
    final window = _quarters!;
    if (!(quartersPerFrame > 0) || !(window > 0)) return;

    for (var i = 0; i < count; i++) {
      final ppq = transport.ppqPosition + (first + i) * quartersPerFrame;
      var phase = (ppq % window) / window;
      if (phase < 0) phase += 1;
      var column = (phase * _columns).floor();
      if (column < 0) column = 0;
      if (column >= _columns) column = _columns - 1;

      if (column != _syncedColumn) {
        _writeSynced();
        _syncedColumn = column;
      }

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
    }
    // **The column being filled is deliberately left unwritten.** A column is a
    // few hundred frames wide and a published block is about a thousand, so the
    // column the block ends in is usually only part measured — and writing it
    // here would finalise it, only for the next block's samples to land in the
    // same column and *replace* it rather than extend it. Every transient that
    // happened to fall in the last column of a block was drawn once and erased
    // a block later, which reads as a display that loses a beat now and again.
    // The extremes stay in the accumulator until the head moves on.
  }

  /// The accumulated extremes into the column they belong to, in place.
  ///
  /// Unlike [_pushColumn] this does not advance a cursor and does not blank an
  /// empty column: a column nothing arrived for this pass keeps what the last
  /// pass put there, which is what makes the display persist rather than chase
  /// a write head round an empty ring.
  void _writeSynced() {
    if (_pEmpty || _syncedColumn < 0) return;
    _minL[_syncedColumn] = _pMinL;
    _maxL[_syncedColumn] = _pMaxL;
    _minR[_syncedColumn] = _pMinR;
    _maxR[_syncedColumn] = _pMaxR;
    _pEmpty = true;
  }

  /// Works out what the painter draws, once per change rather than per frame.
  void resolve() {
    if (!_dirty) return;
    _dirty = false;
    traceCount = 0;

    if (_base == null || _columns == 0) return;

    // Phase-locked: column zero is the start of the window, always. Nothing to
    // search for and nothing to scroll.
    if (_quarters != null) {
      origin = 0;
      return;
    }

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
    _syncedColumn = -1;
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
    required this.sync,
    required this.division,
    required this.grid,
    required this.stereo,
    required this.zoom,
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
       // The second channel of an overlaid pair. A second `Paint` rather than
       // a colour set per draw, because the two are alive at the same time and
       // one of them is mutated mid-frame — see `_paintTrace`.
       _second = (Paint()
         ..color = colors.accent.withValues(alpha: _dim)
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
  final ScopeSync sync;
  final ScopeDivision division;
  final ScopeGrid grid;
  final ScopeStereo stereo;
  final ScopeZoom zoom;

  final Paint _grid;
  final Paint _centre;
  final Paint _signal;
  final Paint _second;
  final Paint _over;
  final Paint _overMark;

  @override
  void paint(Canvas canvas, Size size) {
    final columns = size.width.floor();
    if (columns < 2 || size.height < _laneLabelAbove) return;

    // **A window can only be locked to a tempo somebody is reporting.** A
    // sound card has no playhead and neither does a DAW that never mentions
    // one, and a display that quietly drew a free window while its label said
    // `1 bar` would be the most convincing kind of wrong. When there is nothing
    // to lock to the module falls back to the free window *and to its label*,
    // so what is written in the corner is always what is drawn above it.
    final transport = engine.transport;
    final locked =
        sync == ScopeSync.tempo &&
        transport.hasBpm &&
        transport.bpm > 0 &&
        transport.hasPpq;
    final quarters = locked
        ? division.quartersIn(transport) * grid.factor
        : null;

    final history = state._history;
    history.configure(
      columns: columns,
      base: timeBase,
      sampleRate: engine.sampleRate,
      quarters: quarters,
    );

    // Note what is *not* here: the audio was folded in by
    // `_OscilloscopeModuleState._measured`, off the clock's unthrottled
    // measurement channel. Paint also runs on a resize and on a theme change,
    // and a display that advanced on those would invent time no audio passed
    // through — the same rule the other history modules reach by gating on
    // `generation`, from the other end.
    history.resolve();

    // What there is to draw, and how many rows it is drawn in. A mono source
    // is one of each whatever the arrangement says — `oaa_scope_append` copies
    // the left channel into both, and two identical traces are not a stereo
    // image, overlaid or otherwise.
    final channels = engine.channels >= 2 ? 2 : 1;
    final rows = stereo == ScopeStereo.overlay ? 1 : channels;
    final gap = rows > 1 ? Space.xs : 0.0;
    final laneHeight = (size.height - gap * (rows - 1)) / rows;
    if (laneHeight < OaaStroke.mark * 2) return;

    _paintGrid(canvas, size, rows, laneHeight, gap, quarters);

    for (var channel = 0; channel < channels; channel++) {
      final row = rows == 1 ? 0 : channel;
      final centre = row * (laneHeight + gap) + laneHeight / 2;
      // Inset by the stroke so a full-scale sample is drawn inside the lane
      // rather than half outside it, where the clip takes it.
      final half = laneHeight / 2 - OaaStroke.hairline;
      final low = channel == 0 ? history.minL : history.minR;
      final high = channel == 0 ? history.maxL : history.maxR;
      // Only the second of two channels sharing a row is dimmed. In lanes it
      // is on its own centre line and there is nothing to tell it apart from.
      final ink = rows == 1 && channel == 1 ? _second : _signal;

      if (history.traceCount > 0) {
        _paintTrace(
          canvas,
          size,
          history,
          channel == 0 ? history.traceL : history.traceR,
          centre,
          half,
          ink,
        );
      } else {
        _paintColumns(canvas, history, low, high, centre, half, ink);
      }
    }

    _paintLabels(canvas, size, rows, laneHeight, gap, channels, locked);
  }

  // --- Chrome -------------------------------------------------------------

  void _paintGrid(
    Canvas canvas,
    Size size,
    int lanes,
    double laneHeight,
    double gap,
    double? quarters,
  ) {
    // **A tempo-locked window is divided into beats, not into tenths.** The
    // graticule is what says where in the bar something happened, and ten
    // equal columns across four beats puts a line at 2.4 of them. A window
    // narrower than a beat gets no internal lines at all, which is correct:
    // there is no beat inside it to mark.
    final divisions = quarters == null
        ? _divisions
        : quarters.round().clamp(1, _maxBeatDivisions);

    if (size.width / divisions >= _minDivision) {
      for (var i = 1; i < divisions; i++) {
        final x = (size.width * i / divisions).roundToDouble();
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
    int rows,
    double laneHeight,
    double gap,
    int channels,
    bool locked,
  ) {
    // Below this there is nowhere for a letter or a number to sit that is not
    // on top of the waveform, and a module this small has already given up its
    // graticule for the same reason. What it loses is chrome; what it keeps is
    // the signal, which is the right way round.
    if (laneHeight < _laneLabelAbove) return;

    // Only when there are two of them. The letter distinguishes one channel
    // from the other, and a mono source draws one trace — labelling it `L`
    // would name a channel rather than the sum it is actually showing.
    if (channels > 1 && rows > 1) {
      for (var row = 0; row < rows; row++) {
        final label = row == 0 ? state._leftLabel : state._rightLabel;
        if (label == null) continue;
        canvas.drawParagraph(
          label,
          Offset(Space.xs, row * (laneHeight + gap) + Space.xxs),
        );
      }
    } else if (channels > 1) {
      // Overlaid: the two letters side by side, each in the ink its trace is
      // drawn in. A legend rather than a label — see `_leftKey`.
      final left = state._leftKey;
      final right = state._rightKey;
      if (left != null && right != null) {
        canvas.drawParagraph(left, const Offset(Space.xs, Space.xxs));
        canvas.drawParagraph(
          right,
          Offset(Space.xs + left.longestLine + Space.xxs, Space.xxs),
        );
      }
    }

    // The span, bottom right, over the graticule rather than in an axis row of
    // its own — a three-row module has no vertical space to spend on one, and
    // the number it would carry is the only thing an axis row would say.
    final span = locked ? state._divisionLabel : state._spanLabel;
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
    Paint ink,
  ) {
    final columns = history.columns;
    final segments = history.segments;
    final over = history.overSegments;
    var drawn = 0;
    var clipped = 0;

    // The previous column's drawn extent, or NaN across a gap and at the left
    // edge. See the overlap below.
    var previousTop = double.nan;
    var previousBottom = double.nan;

    for (var i = 0; i < columns; i++) {
      final slot = (history.origin + i) % columns;
      final hi = high[slot];
      // A column no audio was published for. Left as a gap, because the
      // alternative is drawing whatever the neighbouring samples were doing
      // across a stretch of time nobody measured.
      if (hi.isNaN) {
        previousTop = previousBottom = double.nan;
        continue;
      }
      final lo = low[slot];

      final x = i + 0.5;
      // **Snapped to the pixel grid, and drawn without antialiasing.** A
      // column is one pixel wide and as tall as the samples in it, and at a
      // short time base that is often a fraction of a pixel: the rasteriser
      // then spreads a third of the ink over one row and two thirds over the
      // next, and a run of such columns arrives as a line whose density
      // flickers sample by sample. Whole rows at full coverage are the same
      // measurement drawn so that a person can see it, and they are what a
      // waveform display has always been.
      var top = (centre - (hi * zoom.scale).clamp(-1.0, 1.0) * half)
          .roundToDouble();
      var bottom = (centre - (lo * zoom.scale).clamp(-1.0, 1.0) * half)
          .roundToDouble();
      // A column whose extremes are equal — silence, or a held DC level — is a
      // zero-length segment, which draws nothing at all. A flat line is the
      // correct picture of a flat signal, so give it a pixel to be drawn in.
      if (bottom - top < OaaStroke.hairline) {
        bottom = top + OaaStroke.hairline;
      }

      // **Consecutive columns are made to overlap, or the trace comes apart.**
      // A column is drawn as the bar between the extremes of the samples that
      // landed in it, and at a short time base only one or two do — so on a
      // steep edge each bar is a dot a pixel tall, sitting several pixels above
      // or below its neighbour with nothing between them. The waveform then
      // reads as a dashed line, which is what the display looked like at every
      // span from 20 ms to about 100 ms: correct arithmetic, a picture of a
      // signal that was never there.
      //
      // Reaching to the neighbour's edge invents nothing. The samples either
      // side of a column boundary are consecutive samples of a continuous
      // waveform, so the signal did pass through every value between them;
      // what the extension draws is the connecting line a per-sample trace
      // would have drawn anyway. Only the *outermost* edges are measurements,
      // and neither of those moves.
      if (!previousTop.isNaN) {
        if (top > previousBottom) {
          top = previousBottom;
        } else if (bottom < previousTop) {
          bottom = previousTop;
        }
      }
      previousTop = top;
      previousBottom = bottom;

      // **The zoom is not part of this test.** A clip is a sample that reached
      // full scale, and a display that called one at 0.25 a clip because the
      // module is zoomed four times would be reporting something nobody
      // measured. What the zoom changes is where the lane's edge falls, and
      // the picture says that by running off it.
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
    ink.isAntiAlias = false;
    ink.strokeWidth = OaaStroke.hairline;
    canvas.drawRawPoints(ui.PointMode.lines, segments, ink);
    if (clipped > 0) {
      over.fillRange(clipped * 4, over.length, _parked);
      _over.isAntiAlias = false;
      canvas.drawRawPoints(ui.PointMode.lines, over, _over);
    }
  }

  /// One point per sample, joined — the picture when a column holds fewer than
  /// one sample and there is nothing to take a minimum and a maximum of.
  ///
  /// **One polyline, not a segment per sample.** Independent segments meeting
  /// end to end are rasterised independently: each butt cap computes its own
  /// coverage, the shared endpoints composite twice and the pixels either side
  /// of them not at all, so a hairline trace arrives on screen with its density
  /// varying sample by sample and reads as a line that has been chewed. A
  /// polyline is one path, stroked once, with joins — the same ink everywhere.
  ///
  /// A polyline has no tail to park, because every point is joined to the next
  /// and a parked one would be stroked to and back across the module. The
  /// buffer is cut to length instead, once, by [_ScopeHistory.polyline].
  void _paintTrace(
    Canvas canvas,
    Size size,
    _ScopeHistory history,
    Float32List samples,
    double centre,
    double half,
    Paint ink,
  ) {
    final count = history.traceCount;
    if (count < 2) return;

    final line = history.polyline(count);
    final marks = history.overSegments;
    final step = (size.width - 1) / (count - 1);
    var clipped = 0;

    for (var i = 0; i < count; i++) {
      final sample = samples[i];
      final x = i * step;
      final y = centre - (sample * zoom.scale).clamp(-1.0, 1.0) * half;

      line[i * 2] = x;
      line[i * 2 + 1] = y;

      // A tick rather than a point, so that the parked tail of the buffer is
      // a run of zero-length lines the rasteriser drops rather than a run of
      // squares it has to draw and clip. Taken from the sample and not from
      // the zoomed position it is drawn at — see the note in `_paintColumns`.
      if (sample <= -1.0 || sample >= 1.0) {
        marks[clipped * 4] = x;
        marks[clipped * 4 + 1] = y - OaaStroke.mark;
        marks[clipped * 4 + 2] = x;
        marks[clipped * 4 + 3] = y + OaaStroke.mark;
        clipped++;
      }
    }

    // The other way round from the columns: a trace is a diagonal, and a
    // diagonal without antialiasing is a staircase. It is drawn a half pixel
    // heavier for the same reason the columns are snapped — an antialiased
    // hairline running nearly flat puts half its ink in one row and half in
    // the next and reads as a line that is fading in and out, which is what a
    // one-pixel trace looked like along every peak and trough.
    ink.isAntiAlias = true;
    ink.strokeWidth = OaaStroke.mark;
    canvas.drawRawPoints(ui.PointMode.polygon, line, ink);
    if (clipped > 0) {
      marks.fillRange(clipped * 4, marks.length, _parked);
      canvas.drawRawPoints(ui.PointMode.lines, marks, _overMark);
    }
  }

  @override
  bool shouldRepaint(_OscilloscopePainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.timeBase != timeBase ||
      oldDelegate.sync != sync ||
      oldDelegate.division != division ||
      oldDelegate.grid != grid ||
      oldDelegate.stereo != stereo ||
      oldDelegate.zoom != zoom ||
      !identical(oldDelegate.engine, engine);
}
