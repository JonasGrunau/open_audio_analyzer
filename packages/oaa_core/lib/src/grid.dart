// SPDX-License-Identifier: MIT

import 'layout.dart';

/// The placement rules for the canvas, as pure functions over [TabSpec].
///
/// None of this knows what a pixel is. That is not tidiness for its own sake:
/// the same rules have to hold in the desktop app, in a preset loaded from
/// disk, and on a remote display that receives a layout it did not author, and
/// only one of those three has a widget tree. Keeping the algebra here means
/// `dart test packages/oaa_core` covers every placement decision Open Audio
/// Analyzer makes with no toolchain and no window.
///
/// ---------------------------------------------------------------------------
/// Modules may not overlap, and a move that would overlap is refused
///
/// The two alternatives were both worse. Allowing overlap turns a meter bridge
/// into a stack of half-hidden panels and needs a z-order nobody asked for.
/// Pushing neighbours out of the way — the dashboard-library approach — means a
/// drag near the left edge can rearrange a layout the user spent ten minutes
/// on, and the cascade is not reversible by dragging back.
///
/// So placement is a predicate, not a negotiation: a target position is either
/// free or it is not, the canvas shows which while the pointer is down, and an
/// invalid drop leaves the layout exactly as it was. Nothing moves that the
/// user did not move.

/// Whether [rect] lies entirely inside the canvas.
bool isInsideGrid(GridRect rect) =>
    rect.column >= 0 &&
    rect.row >= 0 &&
    rect.columns > 0 &&
    rect.rows > 0 &&
    rect.right <= kGridColumns &&
    rect.bottom <= kGridRows;

/// Pins [rect] to the canvas and to [kind]'s minimum size.
///
/// The placement rules' name for [GridRect.fittedTo], which is where the
/// clamping lives so that deserialisation can apply it too — see the note
/// there. One implementation, because a layout read from a file and a layout
/// dragged with a pointer have to end up under the same rules.
GridRect fitToGrid(GridRect rect, ModuleKind kind) => rect.fittedTo(kind);

/// Layout edits. Every one returns a new [TabSpec]; nothing here mutates.
///
/// Immutability is what makes undo three lines instead of a subsystem — the
/// controller keeps the previous [TabSpec] and that is the whole of it.
extension TabEditing on TabSpec {
  ModuleSpec? moduleById(String id) {
    for (final module in modules) {
      if (module.id == id) return module;
    }
    return null;
  }

  /// Whether [rect] is inside the canvas and clear of every other module.
  ///
  /// [ignoring] excludes one module from the overlap test, which is what makes
  /// a one-cell nudge or a resize legal: a module always overlaps itself.
  bool accepts(GridRect rect, {String? ignoring}) {
    if (!isInsideGrid(rect)) return false;
    for (final module in modules) {
      if (module.id == ignoring) continue;
      if (module.rect.overlaps(rect)) return false;
    }
    return true;
  }

  /// The first free position for a module of this size, scanning row-major.
  ///
  /// Row-major — left to right, then down — rather than nearest-to-something,
  /// because a predictable answer beats a clever one here. Adding four number
  /// boxes in a row should put them in a row.
  GridRect? firstFreeFor(int columns, int rows) {
    if (columns > kGridColumns || rows > kGridRows) return null;
    for (var row = 0; row <= kGridRows - rows; row++) {
      for (var column = 0; column <= kGridColumns - columns; column++) {
        final candidate = GridRect(
          column: column,
          row: row,
          columns: columns,
          rows: rows,
        );
        if (accepts(candidate)) return candidate;
      }
    }
    return null;
  }

  /// [wanted] if it is free, otherwise the first free position of the same
  /// size, otherwise null because the canvas is full.
  GridRect? freeNear(GridRect wanted) {
    if (accepts(wanted)) return wanted;
    return firstFreeFor(wanted.columns, wanted.rows);
  }

  /// Places a new module, and reports which one it placed.
  ///
  /// Returns null when the canvas has no room. The caller has to say so out
  /// loud: silently dropping the request looks like a broken click, and
  /// silently shrinking the module to make it fit is worse — the user asked for
  /// a spectrum analyser, not for whatever happened to be available.
  ({TabSpec tab, ModuleSpec module})? adding(ModuleKind kind, {GridRect? at}) {
    final wanted = fitToGrid(
      at ??
          GridRect(
            column: 0,
            row: 0,
            columns: kind.defaultColumns,
            rows: kind.defaultRows,
          ),
      kind,
    );

    final placed = freeNear(wanted);
    if (placed == null) return null;

    final module = ModuleSpec(
      id: _freshId(modules),
      kind: kind,
      rect: placed,
      options: const {},
    );
    return (tab: copyWith(modules: [...modules, module]), module: module);
  }

  /// Copies a module, to [at] when that is free and to the first free space of
  /// the same size otherwise.
  ///
  /// Duplicating a configured module is how a row of number boxes gets built —
  /// place one, set its metric, duplicate it five times — so the copy carries
  /// the options across. It is a new module with a new id, not a reference.
  ///
  /// [at] is what alt-dragging passes: the copy lands where the pointer was
  /// released rather than wherever the scan happens to reach first.
  ({TabSpec tab, ModuleSpec module})? duplicating(String id, {GridRect? at}) {
    final source = moduleById(id);
    if (source == null) return null;

    final placed = (at != null && accepts(at))
        ? at
        : firstFreeFor(source.rect.columns, source.rect.rows);
    if (placed == null) return null;

    final module = ModuleSpec(
      id: _freshId(modules),
      kind: source.kind,
      rect: placed,
      options: source.options,
    );
    return (tab: copyWith(modules: [...modules, module]), module: module);
  }

  /// Replaces a module in place, keeping its position in the list.
  ///
  /// List order is paint order and tab order; a move that sent a module to the
  /// end of the list would change neither its position nor its appearance, and
  /// would still reshuffle the layout for anybody diffing it — which the remote
  /// display in Phase 6 does.
  TabSpec replacing(ModuleSpec module) => copyWith(
    modules: [
      for (final existing in modules)
        if (existing.id == module.id) module else existing,
    ],
  );

  TabSpec removing(String id) => copyWith(
    modules: [
      for (final module in modules)
        if (module.id != id) module,
    ],
  );
}

/// An id no module on this tab is using.
///
/// Ids only have to be unique within a tab, and they end up in saved presets,
/// so they are short and deterministic rather than random: two runs that build
/// the same layout produce byte-identical files, which makes a preset something
/// you can keep in version control and diff.
String _freshId(List<ModuleSpec> modules) {
  final used = {for (final module in modules) module.id};
  var n = modules.length + 1;
  while (used.contains('m$n')) {
    n++;
  }
  return 'm$n';
}
