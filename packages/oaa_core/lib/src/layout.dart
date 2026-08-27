// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'metric.dart';
import 'transport.dart';

/// The kinds of module a tab can contain.
///
/// Named after what they measure rather than what they look like, with one
/// exception: [superMeter] keeps Decibel's name because there is no better one
/// for "three integrating measurements on concentric arcs".
enum ModuleKind {
  numberBox(
    'number_box',
    'Number Box',
    minColumns: 2,
    // Two, not one. A single row is about 55 px on a 1600x880 canvas; the
    // title bar takes 24 of that and the module's own inset takes the rest,
    // so a one-row Number Box drew a title and an empty body — not "too
    // small", which is a statement, but blank, which is a fault. Stored
    // layouts holding a one-row box are clamped up by [GridRect.fittedTo],
    // which `ModuleSpec.fromJson` applies to every rect it reads.
    minRows: 2,
    defaultColumns: 4,
    defaultRows: 2,
    minBodyWidth: 32,
    minBodyHeight: 24,
  ),
  lufsMeter(
    'lufs_meter',
    'LUFS Meter',
    minColumns: 4,
    minRows: 6,
    defaultColumns: 5,
    defaultRows: 8,
    minBodyWidth: 60,
    minBodyHeight: 60,
  ),
  digitalMeter(
    'digital_meter',
    'Digital Meter',
    minColumns: 3,
    minRows: 6,
    defaultColumns: 4,
    defaultRows: 8,
    minBodyWidth: 60,
    minBodyHeight: 60,
  ),
  superMeter(
    'super_meter',
    'Super Meter',
    minColumns: 6,
    minRows: 6,
    defaultColumns: 8,
    defaultRows: 8,
    minBodyWidth: 90,
    minBodyHeight: 90,
  ),
  vuMeter(
    'vu_meter',
    'VU Meter',
    minColumns: 5,
    minRows: 4,
    defaultColumns: 6,
    defaultRows: 5,
    minBodyWidth: 80,
    minBodyHeight: 50,
  ),
  alertMeter(
    'alert_meter',
    'Alert Meter',
    minColumns: 3,
    minRows: 2,
    defaultColumns: 4,
    defaultRows: 3,
    defaultMetric: Metric.truePeakMax,
    minBodyWidth: 48,
    minBodyHeight: 28,
  ),
  validator(
    'validator',
    'Validator',
    minColumns: 4,
    minRows: 3,
    defaultColumns: 6,
    defaultRows: 4,
    minBodyWidth: 100,
    minBodyHeight: 48,
  ),
  histogram(
    'histogram',
    'Histogram',
    minColumns: 8,
    minRows: 5,
    defaultColumns: 12,
    defaultRows: 6,
    minBodyWidth: 120,
    minBodyHeight: 60,
  ),
  loudnessDistribution(
    'distribution',
    'Loudness Distribution',
    minColumns: 6,
    minRows: 4,
    defaultColumns: 8,
    defaultRows: 5,
    minBodyWidth: 100,
    minBodyHeight: 56,
  ),
  spectrumAnalyzer(
    'spectrum',
    'Spectrum Analyzer',
    minColumns: 8,
    minRows: 5,
    defaultColumns: 12,
    defaultRows: 7,
    minBodyWidth: 120,
    minBodyHeight: 60,
  ),
  spectrogram(
    'spectrogram',
    'Spectrogram',
    minColumns: 8,
    minRows: 5,
    defaultColumns: 12,
    defaultRows: 7,
    minBodyWidth: 80,
    minBodyHeight: 40,
  ),
  oscilloscope(
    'oscilloscope',
    'Oscilloscope',
    minColumns: 8,
    // Three, because two lanes need room to be two lanes. A stereo waveform
    // drawn in one row is two four-pixel strips separated by a gutter, which
    // reads as a rendering fault rather than as a small meter.
    minRows: 3,
    defaultColumns: 12,
    defaultRows: 5,
    minBodyWidth: 120,
    minBodyHeight: 48,
  ),
  phaseScope(
    'phase_scope',
    'Phase Scope',
    minColumns: 5,
    minRows: 5,
    defaultColumns: 6,
    defaultRows: 6,
    minBodyWidth: 60,
    minBodyHeight: 60,
  ),
  stereoCloud(
    'stereo_cloud',
    'Stereo Cloud',
    minColumns: 6,
    minRows: 5,
    defaultColumns: 6,
    defaultRows: 6,
    minBodyWidth: 80,
    minBodyHeight: 60,
  );

  const ModuleKind(
    this.id,
    this.label, {
    required this.minColumns,
    required this.minRows,
    required this.defaultColumns,
    required this.defaultRows,
    required this.minBodyWidth,
    required this.minBodyHeight,
    this.defaultMetric = Metric.lufsIntegrated,
  });

  /// Stable identifier for presets and the wire protocol.
  final String id;
  final String label;

  /// Smallest size at which this module is legible.
  ///
  /// Decibel handles undersized modules by substituting a static placeholder
  /// image, which is a good idea: a spectrum analyser squeezed into two cells
  /// is not a small spectrum analyser, it is a smear. The grid enforces these
  /// on resize.
  final int minColumns;
  final int minRows;

  /// Smallest **body** this module can draw in, in logical pixels.
  ///
  /// A cell count is not a size. The canvas is 24x16 cells at every window
  /// size, so a two-row module is 160 px tall on a 27" display and 40 px tall
  /// on a small window, and the module's own drawing threshold is in pixels
  /// either way. Enforcing only the cell minimum meant a legal layout could
  /// still hand a painter a box it refused to draw in, and a painter that
  /// refuses draws *nothing* — six Number Boxes across the top of the default
  /// preset were empty panels on a 1024x640 window, which reads as a broken
  /// meter rather than as a window that is too small.
  ///
  /// These are the numbers the painters already guarded on, moved here so the
  /// frame can substitute the `ModuleTooSmall` placeholder instead of leaving
  /// a blank. The body is what is left after the title bar and the module's
  /// inset, which is what `ModuleHost` measures.
  final double minBodyWidth;
  final double minBodyHeight;

  /// Which measurement this kind shows when nothing has chosen one.
  ///
  /// Only the kinds that show a single quantity use it — a Number Box, an
  /// Alert. It exists so that a freshly placed Alert Meter watches true peak,
  /// which is what an alert is for, rather than integrated loudness, which
  /// cannot go "over" anything and would make the module look broken until
  /// somebody found its menu.
  final Metric defaultMetric;

  /// The size a freshly placed module gets.
  ///
  /// Deliberately larger than the minimum. Placing a module at its own minimum
  /// means every module arrives looking cramped and the first thing anybody
  /// does after adding one is resize it, which is a small failure repeated
  /// fourteen times.
  final int defaultColumns;
  final int defaultRows;

  static ModuleKind? fromId(String id) {
    for (final kind in ModuleKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// A module's position on the canvas, in grid cells.
///
/// Grid cells rather than pixels is the one deliberate departure from Decibel,
/// whose canvas is free-positioned and whose presets therefore have to store
/// sizes as fractions of the window and reconstitute them per screen. Storing
/// cells makes a preset screen-independent by construction instead of by
/// special case, and it is what lets the same layout open on a 32" display and
/// a 11" tablet without anybody writing responsive code.
class GridRect {
  const GridRect({
    required this.column,
    required this.row,
    required this.columns,
    required this.rows,
  });

  final int column;
  final int row;
  final int columns;
  final int rows;

  int get right => column + columns;
  int get bottom => row + rows;

  bool overlaps(GridRect other) =>
      column < other.right &&
      other.column < right &&
      row < other.bottom &&
      other.row < bottom;

  GridRect copyWith({int? column, int? row, int? columns, int? rows}) =>
      GridRect(
        column: column ?? this.column,
        row: row ?? this.row,
        columns: columns ?? this.columns,
        rows: rows ?? this.rows,
      );

  /// This rect pinned to the canvas and to [kind]'s minimum size.
  ///
  /// Size is clamped first and position second, so a module past the right edge
  /// slides back into view at full size rather than being squashed against it.
  ///
  /// Lives here rather than only in `grid.dart` because deserialisation needs
  /// it: a stored layout is arbitrary integers from a file, and until this ran
  /// on the way in, a module could be narrower than its kind's minimum *and*
  /// hard against an edge — a pair the canvas then could not resize, because
  /// the clamp bounds crossed over. `fitToGrid` is the same function under the
  /// name the placement rules use.
  GridRect fittedTo(ModuleKind kind) {
    final fittedColumns = columns.clamp(kind.minColumns, kGridColumns);
    final fittedRows = rows.clamp(kind.minRows, kGridRows);
    return GridRect(
      column: column.clamp(0, kGridColumns - fittedColumns),
      row: row.clamp(0, kGridRows - fittedRows),
      columns: fittedColumns,
      rows: fittedRows,
    );
  }

  Map<String, Object?> toJson() => {
    'c': column,
    'r': row,
    'w': columns,
    'h': rows,
  };

  factory GridRect.fromJson(Map<String, Object?> json) => GridRect(
    column: json['c']! as int,
    row: json['r']! as int,
    columns: json['w']! as int,
    rows: json['h']! as int,
  );

  @override
  bool operator ==(Object other) =>
      other is GridRect &&
      other.column == column &&
      other.row == row &&
      other.columns == columns &&
      other.rows == rows;

  @override
  int get hashCode => Object.hash(column, row, columns, rows);

  @override
  String toString() => 'GridRect($column,$row ${columns}x$rows)';
}

/// How fast the spectrum analyser's curve follows what the engine publishes.
///
/// **A time constant, not a frame rate.** The obvious reading of "slow the
/// analyser down" is to redraw it less often, and that is the one thing a meter
/// must not do: the engine publishes a transform every 1024 samples, and a
/// display that drew one frame in three would simply not show what happened in
/// the other two — a transient landing between refreshes would be gone rather
/// than smaller. An average shows all of it, in proportion.
///
/// So each band's *displayed* level is a one-pole average of the band levels
/// the engine published, over [timeConstant] seconds. The averaging is in dB,
/// on the value being drawn, which makes this a display ballistic in the sense
/// a VU movement is one — not a power average of the signal, which would be a
/// different quantity and would say so.
///
/// **The peak-hold line is never averaged.** It is the engine's own hold, and
/// it is what keeps a slow setting honest: the curve says where the programme
/// mostly sits, the line above it says how far it actually went.
enum SpectrumResponse {
  /// Every published frame, exactly as measured. What the module did before
  /// this setting existed, and still the right choice for finding a click.
  fast('fast', 'Fast', 0),

  /// Calm enough to read a balance off, fast enough to follow a mix.
  normal('normal', 'Normal', 0.12),

  /// For the shape of a whole programme rather than the shape of a bar.
  slow('slow', 'Slow', 0.5);

  const SpectrumResponse(this.id, this.label, this.timeConstant);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new response instead.
  final String id;

  /// What the module's menu says.
  final String label;

  /// Seconds for the drawn level to cover 63% of a step. Zero draws the
  /// published value untouched.
  final double timeConstant;

  static SpectrumResponse? fromId(String id) {
    for (final response in SpectrumResponse.values) {
      if (response.id == id) return response;
    }
    return null;
  }
}

/// How much the Histogram averages its two bands over before drawing them.
///
/// **A window in seconds, not in columns.** The module folds measurements into
/// 100 ms columns and that rate lives in `histogram.dart`; a setting expressed
/// in columns would mean something different the day that changed, and would
/// mean nothing at all to anybody reading a preset.
///
/// **A centred window, not a one-pole.** [SpectrumResponse] smooths a *live*
/// value, where only the past exists, so a lagging filter is the only kind
/// available. This module draws *history*: every column but the newest has a
/// future as well as a past, so the mean can be symmetric — and it has to be,
/// because a one-pole would slide the whole curve to the right against a time
/// axis labelled `1m15s`. That would make the display wrong about *when* a
/// section was loud, which is the one question it exists to answer. What the
/// symmetry costs instead is at the right edge, where there is no future yet:
/// the newest column is a mean of the newest half-window only, so it sits a
/// little behind the live meters and settles as columns age past it.
///
/// **Nothing goes past two seconds.** Short-term loudness is a 3 s window
/// already; a smoother approaching that draws the momentary band and the
/// short-term curve as one line, and the gap between them is the reading.
enum HistogramSmoothing {
  /// Every column exactly as measured. What the module did before this setting
  /// existed, and still the right choice for finding the single loudest 100 ms
  /// in a programme.
  off('off', 'Off', 0),

  /// Enough to take the sampling jitter off the momentary band and no more.
  light('light', 'Light', 0.5),

  /// Calm enough that the shape of the programme is what you see first.
  normal('normal', 'Normal', 1.0),

  /// For the arc of a whole master rather than the arc of a phrase.
  broad('broad', 'Broad', 2.0);

  const HistogramSmoothing(this.id, this.label, this.seconds);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new setting instead.
  final String id;

  /// What the module's menu says.
  final String label;

  /// The full width of the averaging window, in seconds of measured signal.
  /// Zero draws the columns untouched.
  final double seconds;

  /// The window's half-width in columns, given [secondsPerColumn].
  ///
  /// Lives here so that the rounding is decided once. A window that rounds to
  /// zero would leave a setting in the menu that does nothing, so anything
  /// non-zero is at least one column either side.
  int radiusInColumns(double secondsPerColumn) {
    if (seconds == 0) return 0;
    final radius = (seconds / 2 / secondsPerColumn).round();
    return radius < 1 ? 1 : radius;
  }

  static HistogramSmoothing? fromId(String id) {
    for (final smoothing in HistogramSmoothing.values) {
      if (smoothing.id == id) return smoothing;
    }
    return null;
  }
}

/// What the Loudness Distribution's loudness axis spans.
///
/// [full] is the published range exactly, −60 to 0 LUFS, and it is what the
/// module drew before this setting existed. It is the honest axis and it is
/// usually a waste of the module: the gated short-term distribution of a
/// mastered programme occupies eight to fifteen of those sixty decibels, so
/// four fifths of the width is empty and the shape that carries the reading is
/// squeezed into the rest.
///
/// [auto] fits the axis to what is actually drawn on it — every occupied bin,
/// the gated range, and the delivery target — and then rounds that outwards to
/// a whole number of ticks. **Fitting is not the same as narrowing**, which is
/// the distinction the module's own axis note is about: `MeterScale.fractionOf`
/// clamps, so an axis chosen without reference to the bins stacks everything
/// below its floor onto the bottom column as one tall bar the programme never
/// had. A fitted axis cannot do that, because containing every occupied bin is
/// the thing it is computed from.
enum DistributionScale {
  /// The narrowest round window that holds everything the module draws.
  auto('auto', 'Auto'),

  /// −60 to 0 LUFS, whatever the programme did.
  full('full', 'Full range');

  const DistributionScale(this.id, this.label);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new setting instead.
  final String id;

  /// What the module's menu says.
  final String label;

  static DistributionScale? fromId(String id) {
    for (final scale in DistributionScale.values) {
      if (scale.id == id) return scale;
    }
    return null;
  }
}

/// How much time the oscilloscope's display spans, left edge to right.
///
/// A 1-2-5 sequence, because that is the sequence every time-base knob has ever
/// had and somebody who has used a scope reaches for the next detent rather
/// than reading the menu.
///
/// **The setting also decides how the window is found**, and that is not a
/// second control because there is only one right answer at each end. Below
/// [_rollAbove] the display is *triggered*: the module looks back through the
/// samples it has kept for the most recent rising zero crossing and draws
/// forward from there, so a periodic signal stands still. Above it the display
/// *rolls*: measurements are accumulated into columns and scrolled right to
/// left, the way a DAW draws a waveform.
///
/// The boundary is where each stops working. A rolling display advances by one
/// published measurement — 21 ms of audio — per step, so at 200 ms a fifth of
/// the width arrives at once and the picture lurches; and a triggered display
/// has to hold the whole span in memory *plus* somewhere to search, which is
/// the other reason not to let the fast mode run to seconds. Between 200 ms and
/// 500 ms either would do, and the split is put there rather than left to the
/// reader.
enum ScopeTimeBase {
  ms5('5ms', '5 ms', 0.005),
  ms10('10ms', '10 ms', 0.010),
  ms20('20ms', '20 ms', 0.020),
  ms50('50ms', '50 ms', 0.050),
  ms100('100ms', '100 ms', 0.100),
  ms200('200ms', '200 ms', 0.200),
  ms500('500ms', '500 ms', 0.500),
  s1('1s', '1 s', 1.0),
  s2('2s', '2 s', 2.0),
  s5('5s', '5 s', 5.0);

  const ScopeTimeBase(this.id, this.label, this.seconds);

  /// Stable identifier for presets. Never change one of these; add a new base
  /// instead.
  final String id;

  /// What the module's menu says, and what the display prints in its corner.
  final String label;

  /// Seconds from the left edge of the display to the right.
  final double seconds;

  /// The first span that rolls instead of triggering.
  static const double _rollAbove = 0.2;

  /// Whether the window is found by a trigger rather than scrolled into view.
  bool get isTriggered => seconds <= _rollAbove;

  /// The longest span a triggered display has to hold, which is what sizes the
  /// module's sample buffer.
  static double get longestTriggered => _rollAbove;

  static ScopeTimeBase? fromId(String id) {
    for (final base in ScopeTimeBase.values) {
      if (base.id == id) return base;
    }
    return null;
  }
}

/// How far the analyser rotates its drawn curve, in dB per octave.
///
/// Real programme material is not flat and never was: energy falls with
/// frequency at something like 3 to 4.5 dB an octave across almost every mix
/// anyone has made. An untilted analyser therefore draws every one of them as
/// the same ramp down to the right, with the bottom two octaves against the
/// ceiling and the top four crushed into the floor where there is no vertical
/// room left to show anything happening. The slope is the loudest thing in the
/// picture and it is the one part of it that carries no information.
///
/// A tilt adds a fixed per-band offset to the *drawn* level — nothing else —
/// which rotates the curve about [pivotHz] and puts a typical mix roughly
/// horizontal across the plot. What is left is the deviation, which is the
/// thing being looked for: a bump reads as a bump rather than as a kink in a
/// slope. [db4p5] is the default for the same reason FabFilter's is.
///
/// **The vertical scale is then true at [pivotHz] and rotated everywhere
/// else,** so the module prints the tilt it is drawing at. A dB axis quietly
/// rotated by 45 dB across its width is the one thing worse than no axis at
/// all. Per *octave* rather than per decade because that is the unit every
/// noise slope has ever been quoted in — pink noise is −3 dB/oct, and 3 dB/oct
/// is the setting that draws it as a straight line.
///
/// Nothing measured changes. `Spectrum` and `Spectrum peak` are published,
/// reported and sent over the wire exactly as the engine measured them at
/// every setting, and every other module reading those bands — the
/// spectrogram, the stereo cloud — is untouched by this.
enum SpectrumTilt {
  db0('0', '0 dB/oct', 0),
  db1p5('1.5', '1.5 dB/oct', 1.5),
  db3('3', '3 dB/oct', 3),
  db4p5('4.5', '4.5 dB/oct', 4.5),
  db6('6', '6 dB/oct', 6);

  const SpectrumTilt(this.id, this.label, this.dbPerOctave);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new tilt instead.
  final String id;

  /// What the module's menu says, and what the analyser prints in its corner.
  final String label;

  /// Decibels added per octave above [pivotHz], and subtracted per octave
  /// below it.
  final double dbPerOctave;

  /// The frequency the rotation turns about, and therefore the one place the
  /// analyser's dB scale reads true at any tilt.
  ///
  /// 1 kHz, which is where every other reference in audio is taken and what
  /// the engine's own test tone sits at. The geometric centre of the analyser's
  /// 20 Hz to 20 kHz span is 632 Hz and would keep the picture a shade better
  /// centred; it would also mean the one honest point on the scale was a
  /// frequency nobody thinks in.
  static const double pivotHz = 1000;

  /// The offset this tilt adds to a level drawn at [hz].
  ///
  /// Zero at [pivotHz] whatever the setting, so switching tilts pivots the
  /// curve rather than moving it up or down the scale.
  double dbAt(double hz) => dbPerOctave * math.log(hz / pivotHz) / math.ln2;

  static SpectrumTilt? fromId(String id) {
    for (final tilt in SpectrumTilt.values) {
      if (tilt.id == id) return tilt;
    }
    return null;
  }
}

/// What decides where the oscilloscope's window starts and how wide it is.
///
/// [free] is the display this module was born with: a width in milliseconds
/// from [ScopeTimeBase], found by a trigger at scope speeds and rolled above
/// them. It needs nothing but audio, which is why it is the default and the
/// only thing a sound card can offer.
///
/// [tempo] makes the width a musical division of the host's tempo and locks the
/// window to the bar line, so a kick lands in the same column every bar and the
/// picture stands still against the beat rather than against a zero crossing.
/// It is drawn by *phase* rather than by scrolling: every sample is placed at
/// the column its musical position falls in, so each pass overwrites the last
/// in place.
///
/// **It is the host's playhead that does this, not a MIDI clock.** The plugin
/// receives `ppqPosition`, the start of the current bar, the tempo and the time
/// signature from the DAW itself and forwards all four — see `docs/WIRE.md`.
/// MIDI clock is 24 pulses a quarter with no bar position in it and jitter from
/// the message queue; everything it could tell us we already have exactly.
///
/// A source with no tempo cannot be locked to one. When the host offers none —
/// a sound card, or a DAW that does not report a playhead — the module draws
/// the [free] window and its label says the free time base, so what is written
/// under the trace is always what is above it.
enum ScopeSync {
  free('free', 'Free'),
  tempo('tempo', 'Tempo');

  const ScopeSync(this.id, this.label);

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  static ScopeSync? fromId(String id) {
    for (final sync in ScopeSync.values) {
      if (sync.id == id) return sync;
    }
    return null;
  }
}

/// The musical width of a tempo-synced oscilloscope window.
///
/// Two families, because a bar is not a note value: a note is a fixed number of
/// quarters and a bar is however many the time signature says. Both are here so
/// that "1 bar" means one bar in 7/8 as well as in 4/4 — a scope that showed
/// four quarters and called it a bar would be wrong in every session that is
/// not in common time, and wrong in a way that looks like a drifting trace.
enum ScopeDivision {
  bars4('4bar', '4 bars', bars: 4),
  bars2('2bar', '2 bars', bars: 2),
  bar1('1bar', '1 bar', bars: 1),
  half('1_2', '1/2', quarters: 2),
  quarter('1_4', '1/4', quarters: 1),
  eighth('1_8', '1/8', quarters: 0.5),
  sixteenth('1_16', '1/16', quarters: 0.25),
  thirtySecond('1_32', '1/32', quarters: 0.125);

  const ScopeDivision(this.id, this.label, {this.bars = 0, this.quarters = 0});

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  /// Bars, for the bar-counted widths. Zero for the note values.
  final double bars;

  /// Quarter notes, for the note values. Zero for the bar-counted widths.
  final double quarters;

  /// This width in quarter notes under [transport]'s time signature.
  ///
  /// A bar is `4 * numerator / denominator` quarters — four in 4/4, three in
  /// 3/4, three and a half in 7/8. A host that has not said what it is in gets
  /// common time, which is stated here rather than assumed silently: it is the
  /// one place in this module where a missing field is filled in, and it is
  /// filled in with a *grid* rather than with a measurement.
  double quartersIn(Transport transport) {
    if (bars == 0) return quarters;
    final numerator = transport.hasTimeSignature
        ? transport.timeSigNumerator
        : 4;
    final denominator = transport.hasTimeSignature
        ? transport.timeSigDenominator
        : 4;
    if (numerator <= 0 || denominator <= 0) return bars * 4;
    return bars * 4 * numerator / denominator;
  }

  static ScopeDivision? fromId(String id) {
    for (final division in ScopeDivision.values) {
      if (division.id == id) return division;
    }
    return null;
  }
}

/// Straight, triplet or dotted, applied to a [ScopeDivision].
///
/// The modifier every tempo-synced control in a DAW has, and it means the same
/// thing here: a triplet is two thirds of the width and a dotted note is half
/// again. It applies to the bar widths too, which is unusual and harmless —
/// two thirds of a bar is a legitimate thing to want to look at, and refusing
/// it would be a special case to explain.
///
/// **A free-running window has no grid**, because it has no division to modify
/// — its width is a number of milliseconds and there is no triplet of one. The
/// row is greyed rather than dropped for the same reason [ScopeTrigger]'s is
/// under [ScopeSync.tempo], and it is the same rule read the other way round.
enum ScopeGrid {
  straight('straight', 'Straight', 1),
  triplet('triplet', 'Triplet', 2 / 3),
  dotted('dotted', 'Dotted', 1.5);

  const ScopeGrid(this.id, this.label, this.factor);

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  /// What the division's width is multiplied by.
  final double factor;

  static ScopeGrid? fromId(String id) {
    for (final grid in ScopeGrid.values) {
      if (grid.id == id) return grid;
    }
    return null;
  }
}

/// How the oscilloscope arranges a stereo signal.
///
/// Two pictures of the same audio, and neither is right at both ends of the
/// module's range. [lanes] is the one to open on and the one to read a stereo
/// image from: two traces around two centre lines cannot be confused for one
/// another, and a channel that is doing something the other is not shows up as
/// a difference in shape rather than as a thickening. [overlay] puts both
/// around one centre line, which buys the trace twice the height and makes the
/// *difference* between the channels the thing you see — a widened low end, a
/// side-chained pad, a channel that is a few samples late.
///
/// The overlaid channels are told apart by weight and never by hue. This
/// application's skins move the hues, and a picture that depends on one is a
/// picture that stops working in a skin somebody chose.
enum ScopeStereo {
  lanes('lanes', 'Lanes'),
  overlay('overlay', 'Overlay');

  const ScopeStereo(this.id, this.label);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new arrangement instead.
  final String id;

  /// What the module's menu says.
  final String label;

  static ScopeStereo? fromId(String id) {
    for (final mode in ScopeStereo.values) {
      if (mode.id == id) return mode;
    }
    return null;
  }
}

/// What decides where a free-running oscilloscope window starts.
///
/// [auto] is the display this module was born with, and it is a scope's auto
/// trigger: below 200 ms it looks back for the most recent rising zero crossing
/// so a periodic signal stands still, above it the window rolls, and either way
/// something is always on screen. It needs nothing from the user, which is why
/// it is the default.
///
/// **Its row says `Off` and its id is `auto`.** A bench scope calls this mode
/// Auto, but the row it sits in is spelled `Trigger:`, and `Trigger: Auto`
/// reads as an automatic trigger — the opposite of a display that is not
/// triggered at all. The id keeps the older word because it is written into
/// every saved preset and into the wire protocol, and a renamed id does not
/// fail: [fromId] falls through to the default and the layout quietly forgets
/// what it was set to.
///
/// [transient] is the sweep, and it is the mode for looking at *one event*. The
/// display waits, armed, until the signal rises through [ScopeThreshold]; from
/// that sample it draws forward across the whole width once and then holds what
/// it drew until the next crossing. So a kick starts at the left edge every
/// time, at every time base — the roll above 200 ms is replaced by the sweep
/// rather than left in place — and a threshold nothing reaches leaves the last
/// capture on screen instead of drawing a picture of the noise floor.
///
/// The two differ in what they do when there is no trigger, which is the same
/// distinction a bench scope draws between its Auto and Normal modes: [auto]
/// free-runs and shows whatever the newest audio was, [transient] holds. That is the whole reason
/// both exist — a free-running window is unreadable for a transient and a held
/// one is useless for a continuous tone.
///
/// **A tempo-locked window has no trigger.** [ScopeSync.tempo] already decides
/// where the window starts, from the host's bar line, and a second answer to
/// the same question would either be ignored or fight it. The trigger is
/// offered where the time base is, and for the same reason.
enum ScopeTrigger {
  auto('auto', 'Off'),
  transient('transient', 'Transient');

  const ScopeTrigger(this.id, this.label);

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  /// Whether the display sweeps from a trigger rather than rolling or
  /// free-running.
  bool get sweeps => this == transient;

  static ScopeTrigger? fromId(String id) {
    for (final trigger in ScopeTrigger.values) {
      if (trigger.id == id) return trigger;
    }
    return null;
  }
}

/// The level [ScopeTrigger.transient] fires at, in dBFS.
///
/// A range and not a set of steps, because the useful setting is "just under
/// the transient" and where that falls is a property of the material rather
/// than of the instrument. The oscilloscope draws it as a slider with the level
/// printed beside it and a line across the lane at the height it is set to, so
/// the number, the control and the picture are the same statement.
///
/// dBFS rather than a fraction of full scale for the reason every other number
/// in this application is in dB: −12 is a place somebody can find on a mix,
/// 0.25 is arithmetic. The floor is low enough to catch anything above the
/// noise, and at the very bottom of the range the trigger is within a hair of
/// the rising zero crossing [ScopeTrigger.auto] uses.
abstract final class ScopeThreshold {
  static const double minDb = -60;
  static const double maxDb = 0;

  /// Under a mastered mix's peaks and over its sustain, which is where a
  /// transient trigger has something to lock to on the first try.
  static const double defaultDb = -12;

  /// One press of an arrow key.
  static const double stepDb = 1;

  /// The amplitude a sample has to reach, from a level in dBFS.
  static double amplitude(double db) => math.pow(10, db / 20).toDouble();

  /// A dragged level, to the tenth of a decibel the module prints.
  ///
  /// So that the number on screen, the line drawn at it and the number written
  /// into the preset are the same one. A control that stores more precision
  /// than it shows is a control whose readout is a rounding of something else,
  /// and a preset file people are invited to read is not the place for
  /// `-11.732394366197184`.
  static double quantise(double db) =>
      (db.clamp(minDb, maxDb) * 10).roundToDouble() / 10;

  /// What the module prints beside the control.
  static String label(double db) => '${db.toStringAsFixed(1)} dB';

  /// How far under the loudest transient `Auto` sets the level.
  ///
  /// **Not *at* the peak**, which is what "set it to the loudest transient"
  /// sounds like and which would draw the wrong picture. The trigger fires on a
  /// rising crossing, so a level at the top of the attack starts the sweep at
  /// the peak and the display holds the decay with the transient itself off the
  /// left edge — and nothing quieter than the loudest sample in the programme
  /// would ever fire it again. Six decibels is half the amplitude, which is
  /// still inside the attack: the sweep starts before the transient and the
  /// picture contains it.
  static const double autoMarginDb = 6;

  /// The level `Auto` sets, from the loudest the signal has been.
  ///
  /// [peak] is an amplitude, and it is the largest value the *trigger's own*
  /// quantity reached — the mid of the two channels, not either channel and not
  /// its absolute value. A level derived from anything else can sit above
  /// everything the trigger ever compares against, which presents as a control
  /// that found a number and a display that never sweeps again.
  ///
  /// Rounded to [stepDb] rather than to [quantise]'s tenth, because this one
  /// follows the audio: a level that moved by a tenth of a decibel per published
  /// block would rebuild the strip forty-seven times a second to redraw a line
  /// nobody can see move.
  ///
  /// Null when there is nothing there to trigger on — silence, or a programme
  /// whose loudest transient is under [minDb] + [autoMarginDb]. The caller
  /// keeps the level it had: a passage nobody played is not a measurement, and
  /// slamming the level to the floor during one would arm the trigger on the
  /// noise underneath it.
  static double? autoAt(double peak) {
    if (!(peak > 0)) return null;
    final db = 20 * math.log(peak) / math.ln10 - autoMarginDb;
    if (db < minDb || db.isNaN) return null;
    return (db.clamp(minDb, maxDb) / stepDb).roundToDouble() * stepDb;
  }

  /// Reads the stored value, clamped. Anything that is not a number is the
  /// default rather than a failure — an option map is written by other versions
  /// of this application and by hand.
  static double fromJson(Object? raw) =>
      raw is num ? raw.toDouble().clamp(minDb, maxDb) : defaultDb;
}

/// How tall the oscilloscope draws full scale.
///
/// A vertical zoom, not a gain: nothing about the measurement changes and the
/// clip marks still mark samples that reached full scale, whatever this is set
/// to. It exists because a mastered track and a solo'd reverb tail are thirty
/// decibels apart, and a waveform drawn to the same full scale for both leaves
/// the second one a line. What runs past the lane is clipped by the lane, which
/// is what a zoom means — the picture says so by being cut off at the edge.
///
/// **A number rather than a set of steps, and the module's own slider rather
/// than a menu.** Thirty decibels is the range this has to cover and a menu of
/// four multipliers covered eighteen of them in jumps of six, so the setting
/// that fits the material was usually between two rows. What replaced the menu
/// is a control on the module, dragged with the picture under it, which is the
/// only way to choose a view of something that is moving.
///
/// [steps] is what the *slider* is even in — one octave per step of 1, so half
/// the travel is the first four multipliers and the other half the next four.
/// Nothing snaps to it.
abstract final class ScopeZoom {
  static const double min = 1;
  static const double max = 32;

  /// Full scale is the lane, where the height of the trace is a reading rather
  /// than a view and nothing can run off the edge.
  static const double defaultScale = 1;

  /// One press of an arrow key: a quarter of an octave.
  static const double stepOctaves = 0.25;

  /// The slider's travel, in octaves above [min].
  static double get octaves => _log2(max);

  /// The scale a slider at [position] octaves is set to, to the hundredth of a
  /// multiplier. See [ScopeThreshold.quantise] — same reason, and at this range
  /// a hundredth is a good deal finer than the pixel it moves.
  static double scaleAt(double position) {
    final scale = math.pow(2, position.clamp(0.0, octaves)).toDouble();
    return (scale * 100).roundToDouble() / 100;
  }

  /// Where a scale sits on the slider, in octaves.
  static double positionOf(double scale) => _log2(scale.clamp(min, max));

  /// What the module prints beside the control.
  static String label(double scale) => '${scale.toStringAsFixed(1)}x';

  /// Reads the stored value, clamped.
  ///
  /// **A string is read as a number, which is not a fallback but the
  /// migration.** The four steps this replaced were stored under the ids `1`,
  /// `2`, `4` and `8` — the multipliers themselves, spelled — so every preset
  /// and every session written before the zoom was continuous names a scale
  /// this still understands, and none of them needs a version number to say
  /// so.
  static double fromJson(Object? raw) {
    final value = raw is num
        ? raw.toDouble()
        : raw is String
        ? double.tryParse(raw)
        : null;
    return value == null || !value.isFinite
        ? defaultScale
        : value.clamp(min, max);
  }

  static double _log2(double value) => math.log(value) / math.ln2;
}

/// Which colours the spectrogram and the oscilloscope draw in.
///
/// Two of the fourteen modules answer with a colour rather than with a length,
/// and there are two good ways to choose that colour. [skin] is the one they
/// were born with: level runs a ramp from the module's own ground through
/// `accent` to `warn`, brightness rising the whole way, carrying whichever skin
/// the user chose. It is restrained, it is honest about how much a colour can
/// say, and it is what these modules open on.
///
/// [rgb] gives the frequency axis to the hue circle instead — **bass red, mids
/// green, highs blue into white** — and lets brightness carry the level. That is
/// the scheme every piece of DJ software colours a waveform with, and on these
/// two modules it says something a level ramp cannot: a hue names a *band*, so
/// a kick is red, a snare is amber and a hat is blue, at a glance, before any
/// level has been read. The oscilloscope takes the same ramp: each column is
/// drawn in the hue of where the energy in it sat, which is what makes a
/// waveform readable as music rather than as an envelope.
///
/// It costs two things, which is why it is not the default rather than a reason
/// to withhold it. A rainbow reads as more precise than the measurement behind
/// it — the eye finds edges between hues that are not edges in the data — and
/// roughly eight percent of men cannot separate its red end from its green, for
/// whom the bass and the mids become one colour. The ramp also brings its own
/// dark ground, so on a light skin the module stops matching the interface
/// around it.
///
/// **Nothing measured changes, and no geometry moves.** The same cell, the same
/// column, the same sample, in a different colour — every reading, every report
/// and every byte on the wire is identical at both settings.
enum ColorRamp {
  skin('skin', 'Skin'),
  rgb('rgb', 'Full RGB');

  const ColorRamp(this.id, this.label);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new ramp instead.
  final String id;

  /// What the module's menu says.
  final String label;

  static ColorRamp? fromId(String id) {
    for (final ramp in ColorRamp.values) {
      if (ramp.id == id) return ramp;
    }
    return null;
  }
}

/// One module on a tab.
///
/// [options] is an untyped map on purpose. Every module has its own settings —
/// the spectrogram's scroll direction, the VU's face, the digital meter's decay
/// — and threading a sealed class hierarchy for all fourteen through the preset
/// serialiser buys type safety in exactly one place while making it impossible
/// to load a preset written by a newer version. An unknown key here is
/// ignored and preserved; an unknown subclass would be a parse failure.
class ModuleSpec {
  const ModuleSpec({
    required this.id,
    required this.kind,
    required this.rect,
    this.options = const {},
  });

  /// Unique within a tab. Kept stable across moves so that a remote display can
  /// diff a layout rather than rebuilding it.
  final String id;
  final ModuleKind kind;
  final GridRect rect;
  final Map<String, Object?> options;

  /// The metric this module shows, for the kinds that show one.
  Metric get metric =>
      Metric.fromId(options['metric'] as String? ?? '') ?? kind.defaultMetric;

  /// How fast the spectrum analyser follows the measurement.
  ///
  /// Defaults to [SpectrumResponse.normal] rather than to [SpectrumResponse
  /// .fast], which is what every analyser did before the setting existed. At
  /// 47 transforms a second the untouched curve flickers hard enough that the
  /// shape of the balance is difficult to read at all, and a display nobody can
  /// read is not a more honest one. What it costs is stated where the hold line
  /// is described: that line is the envelope of the drawn curve, so a slower
  /// response holds a smoothed transient rather than the one the engine
  /// measured. [SpectrumResponse.fast] is still the setting for finding a
  /// click.
  SpectrumResponse get spectrumResponse =>
      SpectrumResponse.fromId(options['response'] as String? ?? '') ??
      SpectrumResponse.normal;

  /// How far the analyser rotates what it draws. See [SpectrumTilt].
  ///
  /// Defaults to [SpectrumTilt.db4p5], which is the tilt that draws a mix as
  /// roughly horizontal — an untilted analyser spends most of its height on a
  /// slope every piece of music has.
  SpectrumTilt get spectrumTilt =>
      SpectrumTilt.fromId(options['tilt'] as String? ?? '') ??
      SpectrumTilt.db4p5;

  /// How much the Histogram averages its bands over. See [HistogramSmoothing].
  ///
  /// Defaults to [HistogramSmoothing.normal] rather than to
  /// [HistogramSmoothing.off], which is what the module did before the setting
  /// existed — the same call [spectrumResponse] makes and for the same reason.
  /// The momentary band is a maximum per 100 ms column, so at one pixel a
  /// column it combs hard enough on real material that the gap between the two
  /// bands, which is the whole reading, is difficult to see at all. A display
  /// nobody can read is not a more honest one, and the raw picture is one menu
  /// row away.
  HistogramSmoothing get histogramSmoothing =>
      HistogramSmoothing.fromId(options['smoothing'] as String? ?? '') ??
      HistogramSmoothing.normal;

  /// How much of the loudness axis the Loudness Distribution spans. See
  /// [DistributionScale].
  ///
  /// Defaults to [DistributionScale.auto] rather than to the published range
  /// the module drew before the setting existed — the same call
  /// [histogramSmoothing] makes and for the same reason. A distribution given
  /// a fifth of the width is a picture nobody can read the shape of, and the
  /// full axis is one menu row away.
  DistributionScale get distributionScale =>
      DistributionScale.fromId(options['scale'] as String? ?? '') ??
      DistributionScale.auto;

  /// How much time the oscilloscope shows at once.
  ///
  /// Defaults to a second, which is the setting the module was asked for: long
  /// enough that the shape of a phrase and the spacing of its transients are
  /// the picture, rather than one cycle of the fundamental. The scope speeds
  /// below 200 ms are one menu away and are what the module is called after,
  /// but a display that opens on 20 ms shows a stranger a stationary squiggle
  /// and tells them nothing about their mix.
  ScopeTimeBase get scopeTimeBase =>
      ScopeTimeBase.fromId(options['timeBase'] as String? ?? '') ??
      ScopeTimeBase.s1;

  /// What the oscilloscope's window is locked to. See [ScopeSync].
  ///
  /// Defaults to [ScopeSync.free], which is the only thing that works without a
  /// DAW on the other end of a socket.
  ScopeSync get scopeSync =>
      ScopeSync.fromId(options['sync'] as String? ?? '') ?? ScopeSync.free;

  /// The musical width of a tempo-synced window. See [ScopeDivision].
  ScopeDivision get scopeDivision =>
      ScopeDivision.fromId(options['division'] as String? ?? '') ??
      ScopeDivision.bar1;

  /// Straight, triplet or dotted, applied to [scopeDivision]. See [ScopeGrid].
  ScopeGrid get scopeGrid =>
      ScopeGrid.fromId(options['grid'] as String? ?? '') ?? ScopeGrid.straight;

  /// How the oscilloscope arranges a stereo signal. See [ScopeStereo].
  ///
  /// Defaults to [ScopeStereo.lanes], which is what the module did before the
  /// setting existed and is the arrangement a stranger can read: two traces
  /// around one centre line are two traces only once somebody has been told
  /// so.
  ScopeStereo get scopeStereo =>
      ScopeStereo.fromId(options['stereo'] as String? ?? '') ??
      ScopeStereo.lanes;

  /// What starts a free-running oscilloscope window. See [ScopeTrigger].
  ///
  /// Defaults to [ScopeTrigger.auto], which is what the module did before the
  /// setting existed: always something on screen, and nothing to set up.
  ScopeTrigger get scopeTrigger =>
      ScopeTrigger.fromId(options['trigger'] as String? ?? '') ??
      ScopeTrigger.auto;

  /// The level [ScopeTrigger.transient] fires at, in dBFS. See
  /// [ScopeThreshold].
  double get scopeThresholdDb => ScopeThreshold.fromJson(options['threshold']);

  /// Whether that level follows the material instead of being dragged.
  ///
  /// The only boolean in `options`, and the one value here that is read
  /// strictly: anything that is not `true` is off, which is what every preset
  /// written before this existed meant and what a hand-edited `"yes"` should
  /// mean rather than crashing a canvas. The level itself stays under
  /// `threshold` and is written back the moment this is switched off, so
  /// turning it off keeps the number Auto had found rather than snapping to
  /// whatever was dragged before it was switched on.
  bool get scopeAutoThreshold => options['autoThreshold'] == true;

  /// How tall the oscilloscope draws full scale. See [ScopeZoom].
  ///
  /// Defaults to [ScopeZoom.defaultScale], where the lane is full scale and
  /// nothing can run past it — the only setting at which the *height* of the
  /// trace is a reading rather than a view.
  double get scopeZoom => ScopeZoom.fromJson(options['zoom']);

  /// Which colours the spectrogram and the oscilloscope draw in. See
  /// [ColorRamp].
  ///
  /// Defaults to [ColorRamp.skin], which is what both modules did before the
  /// setting existed — and it is the one default here chosen *against* the
  /// picture that looks best at a glance. A rainbow is the more striking
  /// spectrogram and the less honest one; [ColorRamp] says why, and the menu
  /// row is one click away.
  /// **Read without a cast, unlike its neighbours above.** `as String?` throws
  /// on a value that is a number, and an option map is written by other
  /// versions of this application and by hand — `"ramp": 0` in a preset
  /// somebody edited would take the whole canvas down rather than draw a
  /// spectrogram. [ScopeThreshold.fromJson] and [ScopeZoom.fromJson] are
  /// written the same way for the same reason.
  ColorRamp get colorRamp {
    final raw = options['ramp'];
    return (raw is String ? ColorRamp.fromId(raw) : null) ?? ColorRamp.skin;
  }

  /// What a LUFS module's integration counts from.
  ///
  /// Per module rather than per app, so two of them can sit side by side
  /// showing the same signal over different windows — the whole programme and
  /// the section you are working on — which is the comparison the modes exist
  /// to make. Rides `options` like every other per-module choice, so no preset
  /// written before the modes existed needs migrating: an absent value is
  /// [LufsTimeMode.continuous], which is what those presets were measuring.
  LufsTimeMode get lufsMode =>
      LufsTimeMode.fromId(options['lufsMode'] as String? ?? '') ??
      LufsTimeMode.continuous;

  /// The region [LufsTimeMode.timecode] measures between.
  ///
  /// Null when none has been set, which makes the mode unhonourable rather than
  /// defaulted — `docs/WIRE.md` refuses `TIMECODE` without a region, because
  /// the alternative is measuring a stretch of timeline nobody chose.
  LufsRegion? get lufsRegion {
    final raw = options['lufsRegion'];
    return raw is Map ? LufsRegion.fromJson(raw.cast<String, Object?>()) : null;
  }

  /// What the title bar says.
  ///
  /// A Number Box is titled by what it shows rather than by what it is: six of
  /// them side by side all called "Number Box" is six modules you have to read
  /// the digits of to tell apart.
  String get title => kind == ModuleKind.numberBox ? metric.label : kind.label;

  ModuleSpec copyWith({GridRect? rect, Map<String, Object?>? options}) =>
      ModuleSpec(
        id: id,
        kind: kind,
        rect: rect ?? this.rect,
        options: options ?? this.options,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.id,
    'rect': rect.toJson(),
    if (options.isNotEmpty) 'options': options,
  };

  static ModuleSpec? fromJson(Map<String, Object?> json) {
    final kind = ModuleKind.fromId(json['kind'] as String? ?? '');
    // A preset written by a newer version may name a module this build does
    // not have. Dropping that one module and loading the rest is far better
    // than refusing the whole preset.
    if (kind == null) return null;
    return ModuleSpec(
      id: json['id']! as String,
      kind: kind,
      // Normalised on the way in, which is the *only* place it can be done
      // once for every source of a layout: the session file, a preset the user
      // hand-edited, and a layout that arrived over the wire from a host on a
      // different version. A rect from a file is four arbitrary integers —
      // negative, oversized, outside the canvas, or below a minimum that was
      // raised since it was written — and everything downstream assumes
      // otherwise. See [GridRect.fittedTo].
      rect: GridRect.fromJson(
        json['rect']! as Map<String, Object?>,
      ).fittedTo(kind),
      options: (json['options'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }
}

/// One screen of modules. Decibel calls these Tabs.
class TabSpec {
  const TabSpec({
    required this.name,
    required this.modules,
    this.displayTargetId,
  });

  final String name;
  final List<ModuleSpec> modules;

  /// The remote display this tab is mirrored to, if any. Phase 6.
  final String? displayTargetId;

  TabSpec copyWith({
    String? name,
    List<ModuleSpec>? modules,
    String? displayTargetId,
  }) => TabSpec(
    name: name ?? this.name,
    modules: modules ?? this.modules,
    displayTargetId: displayTargetId ?? this.displayTargetId,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'modules': [for (final module in modules) module.toJson()],
    if (displayTargetId != null) 'display': displayTargetId,
  };

  factory TabSpec.fromJson(Map<String, Object?> json) => TabSpec(
    name: json['name']! as String,
    modules: [
      for (final raw in (json['modules'] as List? ?? const []))
        ?ModuleSpec.fromJson((raw as Map).cast<String, Object?>()),
    ],
    displayTargetId: json['display'] as String?,
  );
}

/// A saved workspace: tabs, and which calibration and skin they were saved with.
///
/// [calibrationId] and [skinId] being nullable is Decibel's "from preset"
/// behaviour, and it is subtler than it looks. Null means *follow the preset* —
/// switching presets switches the target too. A concrete id means the user
/// pinned that choice, and browsing presets must then leave it alone. Without
/// the distinction, either presets cannot carry a target, or picking one
/// explicitly gets silently overwritten the next time you change layout.
class PresetSpec {
  const PresetSpec({
    required this.name,
    required this.tabs,
    this.calibrationId,
    this.skinId,
  });

  final String name;
  final List<TabSpec> tabs;
  final String? calibrationId;
  final String? skinId;

  Map<String, Object?> toJson() => {
    'name': name,
    'tabs': [for (final tab in tabs) tab.toJson()],
    if (calibrationId != null) 'calibration': calibrationId,
    if (skinId != null) 'skin': skinId,
  };

  PresetSpec copyWith({
    String? name,
    List<TabSpec>? tabs,
    String? calibrationId,
    String? skinId,
    bool clearCalibrationId = false,
    bool clearSkinId = false,
  }) => PresetSpec(
    name: name ?? this.name,
    tabs: tabs ?? this.tabs,
    calibrationId: clearCalibrationId
        ? null
        : calibrationId ?? this.calibrationId,
    skinId: clearSkinId ? null : skinId ?? this.skinId,
  );

  factory PresetSpec.fromJson(Map<String, Object?> json) => PresetSpec(
    name: json['name']! as String,
    tabs: [
      for (final raw in (json['tabs'] as List? ?? const []))
        TabSpec.fromJson((raw as Map).cast<String, Object?>()),
    ],
    calibrationId: json['calibration'] as String?,
    skinId: json['skin'] as String?,
  );

  /// [fromJson] for a document nobody in this project wrote.
  ///
  /// [fromJson] throws — `json['name']!` on a file with no name, a cast on a
  /// tab that is not a map — which is the right shape for a document this
  /// application wrote itself and the wrong one for a file a user chose in an
  /// open dialog. Anything can be in that file: a session snapshot, a skin, a
  /// preset from a build that has since changed shape, or JSON that is not ours
  /// at all. So this answers null instead, and the caller says so.
  ///
  /// **Empty tabs is not a preset**, and it is refused here rather than three
  /// layers down. `WorkspaceController.loadPreset` already ignores one, so
  /// without this the interface would report a successful open and then show the
  /// layout that was already on screen.
  static PresetSpec? tryFromJson(Map<String, Object?> json) {
    try {
      final name = json['name'];
      if (name is! String || name.trim().isEmpty) return null;
      final preset = PresetSpec.fromJson(json);
      return preset.tabs.isEmpty ? null : preset;
    } on Object {
      return null;
    }
  }
}

/// The canvas is this many columns wide at every window size.
///
/// 24 divides by 2, 3, 4, 6, 8 and 12, so halves, thirds and quarters are all
/// exact. A 12-column grid cannot express thirds and quarters at the same time,
/// which is the first thing anybody wants when arranging meters.
const int kGridColumns = 24;

/// And this many rows tall.
///
/// Fixing the row count as well as the column count is what makes a preset
/// genuinely screen-independent, and it is worth being explicit about why,
/// because the obvious alternative looks better and is not.
///
/// The obvious alternative is square cells with a scrolling canvas: a cell is
/// `width / 24` in both axes and the layout grows downwards. That keeps module
/// aspect ratios identical everywhere — but on a 32" display a cell is 160 px,
/// a modest six-row meter is 960 px tall, and a layout that fitted on the
/// laptop it was built on now needs scrolling. A meter bridge you have to
/// scroll is not a meter bridge; the entire point is that everything is in view
/// at once.
///
/// So both axes are fixed and cells are whatever shape the window makes them.
/// Aspect distortion costs nothing, because every painter has to handle
/// arbitrary aspect anyway — nothing stops a user resizing a phase scope to
/// 8x2, so a scope that only works when its cell is square was already broken.
///
/// 16 divides by 2, 4 and 8, so vertical halves, quarters and eighths are
/// exact, and 24x16 is close enough to square on a 16:9 display that a module
/// specified 6x6 reads as roughly square without anybody thinking about it.
const int kGridRows = 16;
