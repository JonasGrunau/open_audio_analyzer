// SPDX-License-Identifier: MIT

import 'metric.dart';

/// The kinds of module a tab can contain.
///
/// Named after what they measure rather than what they look like, with one
/// exception: [superMeter] keeps Decibel's name because there is no better one
/// for "three integrating measurements on concentric arcs".
enum ModuleKind {
  numberBox('number_box', 'Number Box', 2, 1),
  lufsMeter('lufs_meter', 'LUFS Meter', 4, 6),
  digitalMeter('digital_meter', 'Digital Meter', 3, 6),
  superMeter('super_meter', 'Super Meter', 6, 6),
  vuMeter('vu_meter', 'VU Meter', 5, 4),
  alertMeter('alert_meter', 'Alert Meter', 3, 2),
  validator('validator', 'Validator', 4, 3),
  histogram('histogram', 'Histogram', 8, 5),
  spectrumAnalyzer('spectrum', 'Spectrum Analyzer', 8, 5),
  spectrogram('spectrogram', 'Spectrogram', 8, 5),
  phaseScope('phase_scope', 'Phase Scope', 5, 5),
  stereoCloud('stereo_cloud', 'Stereo Cloud', 6, 5);

  const ModuleKind(this.id, this.label, this.minColumns, this.minRows);

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

/// One module on a tab.
///
/// [options] is an untyped map on purpose. Every module has its own settings —
/// the spectrogram's scroll direction, the VU's face, the digital meter's decay
/// — and threading a sealed class hierarchy for all twelve through the preset
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

  /// The metric a Number Box shows. Meaningless for other kinds.
  Metric get metric =>
      Metric.fromId(options['metric'] as String? ?? '') ??
      Metric.lufsIntegrated;

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
      rect: GridRect.fromJson(json['rect']! as Map<String, Object?>),
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
