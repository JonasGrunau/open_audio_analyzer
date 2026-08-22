// SPDX-License-Identifier: MIT

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

/// What the analyser's peak-hold line is a hold *of*.
///
/// The curve is averaged over [SpectrumResponse.timeConstant] and the hold is
/// not, and the two used to disagree about more than one thing. Both are fixed
/// here, but only one of them can be:
///
///   - **Motion.** The hold snapped to a new peak while the curve eased towards
///     it, so on Slow the two moved as if they belonged to different plots.
///     The drawn hold now follows the same pole at every setting, whichever of
///     these is chosen. That is not a mode; it is the fix.
///   - **Shape.** A maximum of a noisy band is spiky where an average of it is
///     smooth, so the line above a Slow curve is a comb even once it moves in
///     step. Removing *that* means holding the curve instead of the band, and
///     it costs something real — which is why it is a choice and not the
///     default.
///
/// [peaks] is what the engine measured: a hold over the raw band levels, taken
/// on every 1024-sample hop, so it catches transients between two published
/// frames that the display never saw. [envelope] is the highest the *drawn*
/// curve has been, which is smooth wherever the curve is and is the line to
/// pick when the hold is being read as a shape — and which, on a slow response,
/// sits below a peak the programme really reached, because the curve it is
/// holding never went there.
enum SpectrumHold {
  peaks('peaks', 'Peaks'),
  envelope('envelope', 'Envelope');

  const SpectrumHold(this.id, this.label);

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  static SpectrumHold? fromId(String id) {
    for (final hold in SpectrumHold.values) {
      if (hold.id == id) return hold;
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

/// How tall the oscilloscope draws full scale.
///
/// A vertical zoom, not a gain: nothing about the measurement changes and the
/// clip marks still mark samples that reached full scale, whatever this is set
/// to. It exists because a mastered track and a solo'd reverb tail are thirty
/// decibels apart, and a waveform drawn to the same full scale for both leaves
/// the second one a line. What runs past the lane is clipped by the lane, which
/// is what a zoom means — the picture says so by being cut off at the edge.
enum ScopeZoom {
  x1('1', '1x', 1),
  x2('2', '2x', 2),
  x4('4', '4x', 4),
  x8('8', '8x', 8);

  const ScopeZoom(this.id, this.label, this.scale);

  /// Stable identifier for presets and the wire protocol.
  final String id;

  /// What the module's menu says.
  final String label;

  /// What a sample is multiplied by before it is drawn.
  final double scale;

  static ScopeZoom? fromId(String id) {
    for (final zoom in ScopeZoom.values) {
      if (zoom.id == id) return zoom;
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
  /// read is not a more honest one — the peak-hold line above it still carries
  /// every maximum either way.
  SpectrumResponse get spectrumResponse =>
      SpectrumResponse.fromId(options['response'] as String? ?? '') ??
      SpectrumResponse.normal;

  /// What the analyser's peak-hold line holds. See [SpectrumHold].
  ///
  /// Defaults to [SpectrumHold.peaks], because that is the measurement: a hold
  /// that can only be as high as the drawn curve went is a hold that reads low
  /// on exactly the material a hold exists for.
  SpectrumHold get spectrumHold =>
      SpectrumHold.fromId(options['hold'] as String? ?? '') ??
      SpectrumHold.peaks;

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

  /// How tall the oscilloscope draws full scale. See [ScopeZoom].
  ///
  /// Defaults to [ScopeZoom.x1], where the lane is full scale and nothing can
  /// run past it — the only setting at which the *height* of the trace is a
  /// reading rather than a view.
  ScopeZoom get scopeZoom =>
      ScopeZoom.fromId(options['zoom'] as String? ?? '') ?? ScopeZoom.x1;

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

  factory PresetSpec.fromJson(Map<String, Object?> json) => PresetSpec(
    name: json['name']! as String,
    tabs: [
      for (final raw in (json['tabs'] as List? ?? const []))
        TabSpec.fromJson((raw as Map).cast<String, Object?>()),
    ],
    calibrationId: json['calibration'] as String?,
    skinId: json['skin'] as String?,
  );
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
