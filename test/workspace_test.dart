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

void main() {
  group('the default preset', () {
    test('opens on the readings a mix check actually needs', () {
      final workspace = _container().read(workspaceProvider);

      expect(workspace.preset.tabs, hasLength(1));
      expect(workspace.tab.modules, hasLength(6));
      expect(
        workspace.tab.modules.map((m) => m.metric),
        containsAll([
          Metric.lufsIntegrated,
          Metric.loudnessRange,
          Metric.truePeakMax,
        ]),
      );
    });

    test('places nothing overlapping and nothing off the canvas', () {
      final tab = _container().read(workspaceProvider).tab;
      for (final module in tab.modules) {
        expect(isInsideGrid(module.rect), isTrue);
        expect(tab.accepts(module.rect, ignoring: module.id), isTrue);
      }
    });
  });

  group('modules', () {
    test('adding selects what was added', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      expect(controller.addModule(ModuleKind.vuMeter), isTrue);

      final workspace = container.read(workspaceProvider);
      expect(workspace.tab.modules, hasLength(7));
      expect(
        workspace.tab.moduleById(workspace.selectedModuleId!)!.kind,
        ModuleKind.vuMeter,
      );
    });

    test('a full canvas refuses instead of pretending', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      // The default preset's six number boxes fill rows 0-2 across the full
      // width, leaving thirteen rows. A spectrum analyser is 12x7, so two sit
      // side by side in rows 3-9 and the remaining six-row strip is one row too
      // short for a third.
      expect(controller.addModule(ModuleKind.spectrumAnalyzer), isTrue);
      expect(controller.addModule(ModuleKind.spectrumAnalyzer), isTrue);
      expect(controller.addModule(ModuleKind.spectrumAnalyzer), isFalse);
      expect(container.read(workspaceProvider).tab.modules, hasLength(8));
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

      controller.removeModule(module.id);
      expect(container.read(workspaceProvider).tab.modules, hasLength(5));

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
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);
      final id = container.read(workspaceProvider).tab.modules.first.id;

      controller.removeModule(id);
      controller.undo();
      controller.addModule(ModuleKind.vuMeter);

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

      controller.addTab();
      expect(controller.canUndo, isTrue);

      controller.selectTab(0);
      controller.undo();

      // The undo took back the *tab*, not the navigation.
      expect(container.read(workspaceProvider).preset.tabs, hasLength(1));
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
      container.read(workspaceProvider.notifier).addTab();

      final workspace = container.read(workspaceProvider);
      expect(workspace.preset.tabs, hasLength(2));
      expect(workspace.activeTab, 1);
      expect(workspace.tab.modules, isEmpty);
    });

    test('the last tab cannot be deleted', () {
      // A preset with no tabs has nowhere to put a module and no way back.
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      expect(controller.removeTab(0), isFalse);
      expect(container.read(workspaceProvider).preset.tabs, hasLength(1));
    });

    test('deleting the active tab lands on one that exists', () {
      final container = _container();
      final controller = container.read(workspaceProvider.notifier);

      controller.addTab();
      controller.addTab();
      expect(container.read(workspaceProvider).activeTab, 2);

      controller.removeTab(2);

      final workspace = container.read(workspaceProvider);
      expect(workspace.preset.tabs, hasLength(2));
      expect(workspace.activeTab, lessThan(2));
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

      controller.duplicateTab(0);
      final workspace = container.read(workspaceProvider);

      expect(workspace.preset.tabs, hasLength(2));
      expect(workspace.tab.modules, hasLength(6));

      controller.removeModule(workspace.tab.modules.first.id);
      expect(
        container.read(workspaceProvider).preset.tabs[0].modules,
        hasLength(6),
      );
    });
  });
}
