// SPDX-License-Identifier: GPL-3.0-or-later
//
// The layout controller, tested without a window.
//
// WorkspaceController touches neither the engine nor the widget tree, so all of
// this runs as plain Dart. Only the parts that genuinely need a pointer — the
// drag arithmetic, the hit-test layering — are left for canvas_test.dart, which
// is slower and less precise by nature.

import 'package:bel/src/canvas/workspace.dart';
import 'package:bel_core/bel_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

/// A container sitting on a fresh, empty tab.
///
/// What Bel opens with is a product decision — what a new user should see — and
/// it is dense on purpose. A test that fills a canvas until it refuses, or
/// counts what is left after a delete, would otherwise be asserting that
/// decision rather than the edit it is about, and would fail the day somebody
/// adds a meter to the default layout. Only the `default preset` group above
/// looks at the real thing.
ProviderContainer _onEmptyTab() {
  final container = _container();
  container.read(workspaceProvider.notifier).addTab();
  return container;
}

int _moduleCount(ProviderContainer container) =>
    container.read(workspaceProvider).tab.modules.length;

int _tabCount(ProviderContainer container) =>
    container.read(workspaceProvider).preset.tabs.length;

void main() {
  group('the default preset', () {
    test('opens on the readings a mix check actually needs', () {
      final workspace = _container().read(workspaceProvider);

      expect(workspace.preset.tabs, hasLength(2));
      expect(
        workspace.tab.modules.map((m) => m.metric),
        containsAll([
          Metric.lufsIntegrated,
          Metric.loudnessRange,
          Metric.truePeakMax,
        ]),
      );
    });

    test('every module kind is on it somewhere', () {
      // The preset is also the only place all thirteen kinds are exercised
      // together, so a kind that exists but nobody has laid out is worth
      // catching here: the alternative is that it ships never having been
      // drawn at a real size.
      final preset = _container().read(workspaceProvider).preset;
      final placed = {
        for (final tab in preset.tabs)
          for (final module in tab.modules) module.kind,
      };
      expect(placed, hasLength(ModuleKind.values.length));
    });

    test('places nothing overlapping and nothing off the canvas', () {
      // Every tab, not just the first. A module hanging off the bottom of tab
      // two would be invisible until somebody clicked it, and the grid would
      // then refuse to move it anywhere.
      final preset = _container().read(workspaceProvider).preset;
      for (final tab in preset.tabs) {
        for (final module in tab.modules) {
          expect(
            isInsideGrid(module.rect),
            isTrue,
            reason: '${module.kind.label} on "${tab.name}" is off the canvas',
          );
          expect(
            tab.accepts(module.rect, ignoring: module.id),
            isTrue,
            reason:
                '${module.kind.label} on "${tab.name}" overlaps a neighbour',
          );
          expect(
            module.rect.columns >= module.kind.minColumns &&
                module.rect.rows >= module.kind.minRows,
            isTrue,
            reason:
                '${module.kind.label} on "${tab.name}" is below its minimum',
          );
        }
      }
    });
  });

  group('modules', () {
    test('adding selects what was added', () {
      final container = _onEmptyTab();
      final controller = container.read(workspaceProvider.notifier);

      expect(controller.addModule(ModuleKind.vuMeter), isTrue);

      final workspace = container.read(workspaceProvider);
      expect(workspace.tab.modules, hasLength(1));
      expect(
        workspace.tab.moduleById(workspace.selectedModuleId!)!.kind,
        ModuleKind.vuMeter,
      );
    });

    test('a full canvas refuses instead of pretending', () {
      final container = _onEmptyTab();
      final controller = container.read(workspaceProvider.notifier);

      // A spectrum analyser is 12x7 by default, so on an empty 24x16 grid four
      // of them tile it two by two with two rows to spare — and a fifth has
      // nowhere to go. The refusal is the point: the canvas says no rather than
      // shrinking one to fit or dropping it on top of another.
      for (var i = 0; i < 4; i++) {
        expect(
          controller.addModule(ModuleKind.spectrumAnalyzer),
          isTrue,
          reason: 'analyser ${i + 1} should fit',
        );
      }
      expect(controller.addModule(ModuleKind.spectrumAnalyzer), isFalse);
      expect(container.read(workspaceProvider).tab.modules, hasLength(4));
    });

    test('deleting the selected module clears the selection', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final id = container.read(workspaceProvider).tab.modules.first.id;

      controller.select(id);
      controller.removeModule(id);

      final workspace = container.read(workspaceProvider);
      expect(workspace.selectedModuleId, isNull);
      expect(workspace.tab.moduleById(id), isNull);
    });

    test('changing a metric changes only that module', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final modules = container.read(workspaceProvider).tab.modules;
      final before = modules[3].metric;

      controller.setModuleOption(
        modules[0].id,
        'metric',
        Metric.crestFactor.id,
      );

      final after = container.read(workspaceProvider).tab;
      expect(after.moduleById(modules[0].id)!.metric, Metric.crestFactor);
      expect(after.moduleById(modules[3].id)!.metric, before);
    });
  });

  group('undo', () {
    test('restores a deleted module, options and all', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final module = container.read(workspaceProvider).tab.modules.first;
      final before = _moduleCount(container);

      controller.removeModule(module.id);
      expect(_moduleCount(container), before - 1);

      controller.undo();

      final restored = container
          .read(workspaceProvider)
          .tab
          .moduleById(module.id);
      expect(restored, isNotNull);
      expect(restored!.metric, module.metric);
      expect(restored.rect, module.rect);
    });

    test('redo puts it back', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final id = container.read(workspaceProvider).tab.modules.first.id;

      controller.removeModule(id);
      controller.undo();
      controller.redo();

      expect(container.read(workspaceProvider).tab.moduleById(id), isNull);
    });

    test('a new edit discards the redo branch', () {
      // Otherwise redo replays an edit against a layout it was never made
      // against, and puts a module somewhere nobody chose.
      //
      // On an empty tab, because the new edit has to be one that can actually
      // succeed: `addModule` returns false on a full canvas, and a refused add
      // is not an edit, so this would pass or fail depending on how much room
      // the default preset happens to leave.
      final container = _onEmptyTab();
      final controller = container.read(workspaceProvider.notifier);
      controller.addModule(ModuleKind.numberBox);
      final id = container.read(workspaceProvider).selectedModuleId!;

      controller.removeModule(id);
      controller.undo();
      expect(controller.canRedo, isTrue);

      expect(controller.addModule(ModuleKind.vuMeter), isTrue);
      expect(controller.canRedo, isFalse);
    });

    test('selecting is not an edit', () {
      // The reason this matters: with selection in the history, the first
      // half-dozen Cmd+Z presses after a mistake undo nothing but clicks.
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      expect(controller.canUndo, isFalse);
      controller.select(container.read(workspaceProvider).tab.modules.first.id);
      controller.select(null);
      expect(controller.canUndo, isFalse);
    });

    test('switching tabs is not an edit either', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      final before = _tabCount(container);
      controller.addTab();
      expect(controller.canUndo, isTrue);

      controller.selectTab(0);
      controller.undo();

      // The undo took back the *tab*, not the navigation.
      expect(_tabCount(container), before);
    });

    test('history is bounded', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      for (var i = 0; i < WorkspaceController.historyLimit + 20; i++) {
        controller.addTab();
      }
      for (var i = 0; i < WorkspaceController.historyLimit + 20; i++) {
        controller.undo();
      }

      // Bounded, so the oldest states are gone — but never past the start, and
      // never into an invalid state.
      final workspace = container.read(workspaceProvider);
      expect(workspace.preset.tabs, isNotEmpty);
      expect(workspace.activeTab, lessThan(workspace.preset.tabs.length));
    });
  });

  group('tabs', () {
    test('a new tab is empty and becomes the active one', () {
      final container = _container();
      final before = _tabCount(container);
      container.read(workspaceProvider.notifier).addTab();

      final workspace = container.read(workspaceProvider);
      expect(workspace.preset.tabs, hasLength(before + 1));
      expect(workspace.activeTab, before);
      expect(workspace.tab.modules, isEmpty);
    });

    test('the last tab cannot be deleted', () {
      // A preset with no tabs has nowhere to put a module and no way back.
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      while (_tabCount(container) > 1) {
        expect(controller.removeTab(0), isTrue);
      }
      expect(controller.removeTab(0), isFalse);
      expect(_tabCount(container), 1);
    });

    test('deleting the active tab lands on one that exists', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      final before = _tabCount(container);
      controller.addTab();
      controller.addTab();
      final last = _tabCount(container) - 1;
      expect(container.read(workspaceProvider).activeTab, last);

      controller.removeTab(last);

      final workspace = container.read(workspaceProvider);
      expect(workspace.preset.tabs, hasLength(before + 1));
      expect(workspace.activeTab, lessThan(last));
    });

    test('an empty rename is refused rather than applied', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final before = container.read(workspaceProvider).preset.tabs[0].name;

      controller.renameTab(0, '   ');
      expect(container.read(workspaceProvider).preset.tabs[0].name, before);

      controller.renameTab(0, '  Mastering  ');
      expect(
        container.read(workspaceProvider).preset.tabs[0].name,
        'Mastering',
      );
    });

    test('a duplicated tab carries its modules but is its own tab', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      final tabs = _tabCount(container);
      final modules = container
          .read(workspaceProvider)
          .preset
          .tabs[0]
          .modules
          .length;

      controller.duplicateTab(0);
      final workspace = container.read(workspaceProvider);

      expect(workspace.preset.tabs, hasLength(tabs + 1));
      expect(workspace.tab.modules, hasLength(modules));

      // Deleting from the copy must not reach through to the original: a
      // duplicate that shared its module list would make "try a variant" a
      // destructive operation.
      controller.removeModule(workspace.tab.modules.first.id);
      expect(
        container.read(workspaceProvider).preset.tabs[0].modules,
        hasLength(modules),
      );
    });
  });
}
