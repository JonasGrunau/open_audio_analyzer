// SPDX-License-Identifier: MIT

import 'metric.dart';

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
  /// thirteen times.
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

/// One module on a tab.
///
/// [options] is an untyped map on purpose. Every module has its own settings —
/// the spectrogram's scroll direction, the VU's face, the digital meter's decay
/// — and threading a sealed class hierarchy for all thirteen through the preset
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
