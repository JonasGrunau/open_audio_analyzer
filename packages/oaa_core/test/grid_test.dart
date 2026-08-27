// SPDX-License-Identifier: GPL-3.0-or-later
//
// The canvas rules, tested where they live rather than through a widget.
//
// Every one of these assertions is reachable by dragging a module with a mouse,
// and every one of them would be slow, flaky and hard to read as a widget test.
// Placement is arithmetic over integers; it belongs in a test that runs in
// milliseconds with no window.

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

GridRect _rect(int column, int row, int columns, int rows) =>
    GridRect(column: column, row: row, columns: columns, rows: rows);

ModuleSpec _module(String id, GridRect rect, [ModuleKind? kind]) =>
    ModuleSpec(id: id, kind: kind ?? ModuleKind.numberBox, rect: rect);

TabSpec _tab(List<ModuleSpec> modules) =>
    TabSpec(name: 'Test', modules: modules);

void main() {
  group('grid bounds', () {
    test('a rect inside the canvas is inside it', () {
      expect(isInsideGrid(_rect(0, 0, kGridColumns, kGridRows)), isTrue);
      expect(isInsideGrid(_rect(22, 15, 2, 1)), isTrue);
    });

    test('a rect crossing any edge is not', () {
      expect(isInsideGrid(_rect(-1, 0, 2, 2)), isFalse);
      expect(isInsideGrid(_rect(0, -1, 2, 2)), isFalse);
      expect(isInsideGrid(_rect(23, 0, 2, 2)), isFalse);
      expect(isInsideGrid(_rect(0, 15, 2, 2)), isFalse);
    });

    test('a zero-sized rect is not a placement', () {
      // Otherwise a resize that collapses a module leaves an invisible,
      // unselectable, undeletable entry in the preset.
      expect(isInsideGrid(_rect(0, 0, 0, 4)), isFalse);
      expect(isInsideGrid(_rect(0, 0, 4, 0)), isFalse);
    });
  });

  group('fitToGrid', () {
    test('grows a module up to its minimum', () {
      final fitted = fitToGrid(_rect(0, 0, 1, 1), ModuleKind.spectrumAnalyzer);
      expect(fitted.columns, ModuleKind.spectrumAnalyzer.minColumns);
      expect(fitted.rows, ModuleKind.spectrumAnalyzer.minRows);
    });

    test('slides a module back into view rather than squashing it', () {
      // Size is clamped before position, which is the difference between a
      // module dragged off the right edge returning at full size and it
      // arriving one column wide.
      final fitted = fitToGrid(_rect(30, 20, 6, 6), ModuleKind.phaseScope);
      expect(fitted.columns, 6);
      expect(fitted.rows, 6);
      expect(fitted.column, kGridColumns - 6);
      expect(fitted.row, kGridRows - 6);
    });

    test('every kind fits on an empty canvas at its default size', () {
      // A module nobody can place is a module nobody can use. This catches a
      // default size that outgrows the canvas the moment either constant moves.
      for (final kind in ModuleKind.values) {
        final placed = _tab(const []).adding(kind);
        expect(placed, isNotNull, reason: '${kind.label} does not fit');
        expect(placed!.module.rect.columns, kind.defaultColumns);
        expect(placed.module.rect.rows, kind.defaultRows);
        expect(kind.defaultColumns, greaterThanOrEqualTo(kind.minColumns));
        expect(kind.defaultRows, greaterThanOrEqualTo(kind.minRows));
      }
    });
  });

  group('overlap', () {
    final tab = _tab([_module('m1', _rect(0, 0, 4, 4))]);

    test('a position covered by another module is refused', () {
      expect(tab.accepts(_rect(2, 2, 4, 4)), isFalse);
      expect(tab.accepts(_rect(3, 3, 1, 1)), isFalse);
    });

    test('sharing an edge is not overlapping', () {
      // Off-by-one here would leave a permanent one-cell gutter between every
      // pair of modules and make a full-width row impossible to build.
      expect(tab.accepts(_rect(4, 0, 4, 4)), isTrue);
      expect(tab.accepts(_rect(0, 4, 4, 4)), isTrue);
    });

    test('a module does not block itself', () {
      // Without this a module cannot be nudged one cell, or resized at all.
      expect(tab.accepts(_rect(1, 0, 4, 4)), isFalse);
      expect(tab.accepts(_rect(1, 0, 4, 4), ignoring: 'm1'), isTrue);
      expect(tab.accepts(_rect(0, 0, 8, 8), ignoring: 'm1'), isTrue);
    });
  });

  group('placement', () {
    test('modules added in sequence fill left to right', () {
      var tab = _tab(const []);
      final placed = <GridRect>[];
      for (var i = 0; i < 6; i++) {
        final result = tab.adding(ModuleKind.numberBox)!;
        tab = result.tab;
        placed.add(result.module.rect);
      }

      // Six 4x2 boxes are exactly one 24-column row.
      expect(placed.take(6).map((r) => r.row), everyElement(0));
      expect(placed.map((r) => r.column), [0, 4, 8, 12, 16, 20]);
    });

    test('a requested position is honoured when it is free', () {
      final result = _tab(
        const [],
      ).adding(ModuleKind.numberBox, at: _rect(10, 6, 4, 2))!;
      expect(result.module.rect, _rect(10, 6, 4, 2));
    });

    test('a requested position that is taken falls back to a free one', () {
      final tab = _tab([_module('m1', _rect(0, 0, 24, 8))]);
      final result = tab.adding(ModuleKind.numberBox, at: _rect(2, 2, 4, 2))!;
      expect(result.module.rect.overlaps(_rect(0, 0, 24, 8)), isFalse);
      expect(result.module.rect.row, 8);
    });

    test('a full canvas refuses rather than overlapping or shrinking', () {
      // The honest failure. Returning the tab unchanged would read as a broken
      // click, and making room by resizing something would move a module the
      // user did not touch.
      final full = _tab([_module('m1', _rect(0, 0, kGridColumns, kGridRows))]);
      expect(full.adding(ModuleKind.numberBox), isNull);
      expect(full.duplicating('m1'), isNull);
    });
  });

  group('ids', () {
    test('a new module never collides with an existing one', () {
      var tab = _tab(const []);
      for (var i = 0; i < 20; i++) {
        tab = tab.adding(ModuleKind.numberBox)!.tab;
      }
      final ids = tab.modules.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('ids survive a delete in the middle', () {
      // The naive "length + 1" scheme reuses an id here, and a preset with two
      // modules sharing an id loses one of them on reload.
      var tab = _tab(const []);
      tab = tab.adding(ModuleKind.numberBox)!.tab;
      tab = tab.adding(ModuleKind.numberBox)!.tab;
      tab = tab.adding(ModuleKind.numberBox)!.tab;
      tab = tab.removing(tab.modules[1].id);
      tab = tab.adding(ModuleKind.numberBox)!.tab;

      final ids = tab.modules.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('duplicate', () {
    test('carries the options across but not the identity', () {
      final tab = _tab([
        ModuleSpec(
          id: 'm1',
          kind: ModuleKind.numberBox,
          rect: _rect(0, 0, 4, 2),
          options: const {'metric': 'lra'},
        ),
      ]);

      final result = tab.duplicating('m1')!;
      expect(result.module.id, isNot('m1'));
      expect(result.module.options['metric'], 'lra');
      expect(result.module.rect.overlaps(_rect(0, 0, 4, 2)), isFalse);
      expect(result.tab.modules, hasLength(2));
    });

    test('duplicating something that is not there is a no-op, not a crash', () {
      expect(_tab(const []).duplicating('nope'), isNull);
    });

    test('lands where it was dropped — this is what alt-drag passes', () {
      final tab = _tab([_module('m1', _rect(0, 0, 4, 2))]);
      expect(
        tab.duplicating('m1', at: _rect(10, 6, 4, 2))!.module.rect,
        _rect(10, 6, 4, 2),
      );
    });

    test('falls back to a free slot when the drop target is occupied', () {
      final tab = _tab([
        _module('m1', _rect(0, 0, 4, 2)),
        _module('m2', _rect(10, 6, 4, 2)),
      ]);
      final placed = tab.duplicating('m1', at: _rect(10, 6, 4, 2))!.module.rect;
      expect(placed.overlaps(_rect(10, 6, 4, 2)), isFalse);
    });
  });

  group('replace', () {
    test('keeps list order, because list order is paint order', () {
      final tab = _tab([
        _module('m1', _rect(0, 0, 2, 2)),
        _module('m2', _rect(4, 0, 2, 2)),
        _module('m3', _rect(8, 0, 2, 2)),
      ]);

      final moved = tab.replacing(
        tab.moduleById('m2')!.copyWith(rect: _rect(4, 8, 2, 2)),
      );

      expect(moved.modules.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(moved.moduleById('m2')!.rect, _rect(4, 8, 2, 2));
    });
  });

  group('serialisation round-trips', () {
    // --- What arrives from a file ----------------------------------------
    //
    // A rect in a document is four arbitrary integers. It may predate a
    // module's minimum being raised, name a size this build considers
    // unreadable, or have been typed by hand — and everything downstream
    // assumes otherwise. `layout.dart` claimed for a phase that stored layouts
    // were "clamped up by `normaliseModule`", a function that did not exist
    // anywhere in the repository; the canvas then threw ArgumentError out of a
    // pointer callback when a too-small module sat against the right edge,
    // because the clamp bounds crossed over.
    test('a module read from JSON is pinned to its minimum and the canvas', () {
      final module = ModuleSpec.fromJson({
        'id': 'm1',
        'kind': 'spectrum',
        // One cell wide, hard against the right edge, one row past the bottom.
        'rect': {'c': 23, 'r': 15, 'w': 1, 'h': 1},
      })!;

      expect(module.rect.columns, ModuleKind.spectrumAnalyzer.minColumns);
      expect(module.rect.rows, ModuleKind.spectrumAnalyzer.minRows);
      expect(isInsideGrid(module.rect), isTrue);
      // Slid back into view at full size rather than squashed against the edge.
      expect(module.rect.right, kGridColumns);
      expect(module.rect.bottom, kGridRows);
    });

    test('a nonsense rect from a hand-edited file still loads', () {
      final module = ModuleSpec.fromJson({
        'id': 'm1',
        'kind': 'number_box',
        'rect': {'c': -8, 'r': -3, 'w': 0, 'h': 999},
      })!;

      expect(isInsideGrid(module.rect), isTrue);
      expect(module.rect.column, 0);
      expect(module.rect.row, 0);
      expect(module.rect.columns, ModuleKind.numberBox.minColumns);
      expect(module.rect.rows, kGridRows);
    });

    test('a laid-out tab survives JSON', () {
      var tab = _tab(const []);
      tab = tab.adding(ModuleKind.spectrumAnalyzer)!.tab;
      tab = tab.adding(ModuleKind.numberBox, at: _rect(0, 8, 4, 2))!.tab;

      final restored = TabSpec.fromJson(tab.toJson());
      expect(restored.modules, hasLength(2));
      expect(restored.modules[0].kind, ModuleKind.spectrumAnalyzer);
      expect(restored.modules[1].rect, _rect(0, 8, 4, 2));
    });
  });
}
