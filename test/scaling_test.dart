// SPDX-License-Identifier: GPL-3.0-or-later
//
// What happens to the interface when the window changes size.
//
// The canvas is a fixed 24x16 cells at every window size, which is what makes a
// preset screen-independent — and it is also what makes "the module is big
// enough" a statement about *pixels* rather than about cells. The same legal
// two-row module is 160 px tall on a 27" display and 40 px on a small window.
//
// Every defect this file exists to keep out shipped, and none of them was
// visible in a diff or in the default-size widget tests:
//
//   - Six Number Boxes across the top of the default preset rendered as empty
//     panels on a 1024x640 window. Every painter guards on its own minimum and
//     a painter that declines to draw draws *nothing*, so the honest "too
//     small" placeholder never appeared. The floors live on `ModuleKind` now
//     and the frame enforces them.
//   - The status bar overflowed its own row by 121 px at the smallest window
//     the platform allowed. A `Row` that cannot fit its children does not
//     shrink them; in a release build it clips them silently.
//   - The source picker overflowed its *own* row, inside the bar, where the
//     bar's width gates cannot see it: the name was capped at 220 px but never
//     made flexible, so it took its natural width however little the bar had
//     left to give it and the dot beside it went over the edge.
//   - The keyboard sheet did not fit its own panel, so it scrolled and cut its
//     footnote in half — see the group at the bottom of this file.
//
// These are pumped at real window sizes rather than the test default, because
// the test default is 800x600 and neither defect appears there.

import 'dart:io';

import 'package:bel/src/app/bel_app.dart';
import 'package:bel/src/app/shortcuts.dart';
import 'package:bel/src/canvas/module_host.dart';
import 'package:bel/src/clock/meter_clock.dart';
import 'package:bel/src/data/providers.dart';
import 'package:bel/src/panels/shortcuts_sheet.dart';
import 'package:bel/src/storage/config_store.dart';
import 'package:bel/src/storage/startup_config.dart';
import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fonts the application ships, loaded so that "does the row fit" is a
/// question about Bel and not about the test binding.
///
/// Without this every glyph is the placeholder font's square em box, which is
/// far wider than Inter or Google Sans Code — the status bar then overflows by
/// 299 px at a width where the real one has room to spare, and the test is
/// measuring a typeface nobody ships. Read with `readAsBytesSync`: an awaited
/// real read inside a `testWidgets` body never completes.
Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      loader.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(File(path).readAsBytesSync()),
        ),
      );
    }
    await loader.load();
  }

  await load('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
  ]);
  await load('Google Sans Code', [
    'assets/fonts/GoogleSansCode-Regular.ttf',
    'assets/fonts/GoogleSansCode-Medium.ttf',
  ]);
}

/// The smallest window the application supports.
///
/// **The same numbers as `minimumSize` in `macos/Runner/MainFlutterWindow.swift`.**
/// There is no way to share them — that file is compiled before Dart runs — so
/// this test is what keeps the two honest. Raise one and this fails until the
/// other moves.
const Size kMinimumWindow = Size(960, 768);

/// The canvas a window size produces: the status bar, the tab strip and the
/// canvas's own inset come off the height.
Size _canvasFor(Size window) =>
    Size(window.width - Space.md * 2, window.height - 40 - 32 - Space.md * 2);

/// The longest content the status bar can be asked to hold.
///
/// The calibration chip caps at 220 px and ellipsis, so anything past that name
/// renders the same — but the *default* target is "Streaming (−14 LUFS)", which
/// is 100 px short of the cap, and that is what let a real overflow through: at
/// 950 px every width gate was open and the row ran 18 px past its edge.
///
/// **Silence, not a capture device.** This asked for a device by an id no
/// machine has, and what a device that will not open produces is not a status
/// bar — it is the engine-failure screen, one centred paragraph that fits every
/// width and fails nothing. Whether the 121 widths below sweep the bar or that
/// paragraph then depends on whether the machine running them happens to have
/// an input miniaudio will fall back to, which is the difference between this
/// developer's laptop and a headless CI runner. The source label costs the row
/// nothing anyway: the picker is `Flexible` and shortens with an ellipsis, so
/// it can give back everything but its dot — and a target name at the cap
/// squeezes it that far, which is what makes this the case that catches the
/// picker's own row overflowing as well. The fixed width in the bar is the
/// target chip, and that is what this sets.
const _longNames = StartupConfig(
  settings: AppSettings(
    sourceKind: AudioSourceKind.silence,
    calibrationId: 'worst-case',
  ),
  calibrations: [
    Calibration(
      id: 'worst-case',
      name: 'Apple Digital Masters — Podcast Delivery (−16 LUFS mono)',
      lufsTarget: -16,
      lufsTolerance: 1,
      truePeakMax: -1,
      loudnessRangeMax: 8,
    ),
  ],
);

Future<void> _pumpApp(
  WidgetTester tester,
  Size window, {
  StartupConfig config = const StartupConfig(),
}) async {
  tester.view.physicalSize = window * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final store = ConfigStore.disabled();
  addTearDown(store.dispose);
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(config),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const BelApp()),
  );
  await tester.pump();

  // **The bar has to be on screen for a sweep of it to mean anything.** A
  // source that will not open replaces the whole window with the engine-failure
  // screen, which is one centred paragraph: it fits every width, overflows
  // nothing, and passes at all 221 of them. Nothing else in this file would
  // notice — a row that was never laid out cannot overflow — so the sweep would
  // go green on the day the bar stopped fitting. See `_longNames`.
  expect(
    find.text('RESET'),
    findsOneWidget,
    reason:
        'The status bar is not on screen, so this width proves nothing about '
        'it. The engine failed to open the configured source and the window is '
        'showing the failure screen instead.',
  );
}

/// One module, alone, at exactly the pixels a grid rect gets on [canvas].
class _Solo extends StatefulWidget {
  const _Solo({required this.kind, required this.rect});

  final ModuleKind kind;
  final GridRect rect;

  @override
  State<_Solo> createState() => _SoloState();
}

class _SoloState extends State<_Solo> with SingleTickerProviderStateMixin {
  late final BelEngine engine = BelEngine.start(source: BelSource.silence);
  late final MeterClock clock = MeterClock(engine: engine, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BelTheme(
    colors: BelColors.precisionInstrument,
    child: Material(
      color: BelColors.precisionInstrument.background,
      child: ModuleHost(
        spec: ModuleSpec(id: 'solo', kind: widget.kind, rect: widget.rect),
        engine: engine,
        clock: clock,
        calibration: BuiltInCalibrations.fallback,
        selected: false,
        onMenu: () {},
      ),
    ),
  );
}

Future<void> _pumpSolo(
  WidgetTester tester, {
  required ModuleKind kind,
  required int columns,
  required int rows,
  required Size canvas,
}) async {
  final rect = GridRect(column: 0, row: 0, columns: columns, rows: rows);
  final size = GridGeometry(size: canvas).rectFor(rect).size;

  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _Solo(kind: kind, rect: rect),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(_loadFonts);

  // A `RenderFlex` overflow is reported through the error reporter, which the
  // test framework turns into a failure, so pumping the bar at a width where it
  // does not fit *is* the assertion. Stepping rather than sampling: the row is
  // a sum of fixed widths and the gates that drop items are cliffs, so a
  // regression can be twenty pixels wide and sit between two round numbers.
  group('the status bar fits its row', () {
    // From 600, which is where the bar's irreducible set — the source, the
    // clock, the delivery target, SETTINGS and RESET — starts to fit at all.
    // Below that there is nothing left to drop that the bar's own rule allows
    // dropping, and it is a third of the supported minimum window.
    for (var width = 600.0; width <= 2560.0; width += 20) {
      testWidgets('at ${width.toInt()} px', (tester) async {
        await _pumpApp(tester, Size(width, 900));
      });
    }

    testWidgets('at the supported minimum', (tester) async {
      await _pumpApp(tester, kMinimumWindow);
    });

    // The same sweep with the longest content the bar can hold, at five pixels
    // rather than twenty.
    //
    // Both changes are here because of one bug, and either alone would have
    // missed it: the row overflowed by 18 px at 950, which the twenty-pixel
    // stride steps straight over, and only with a target name long enough to
    // reach the chip's 220 px cap. It was reported from a running application
    // against a suite of 137 green tests.
    //
    // The band stops at 1200 because every gate the bar has is below it and the
    // row only gets slacker above; the stride is what makes this affordable.
    for (var width = 600.0; width <= 1200.0; width += 5) {
      testWidgets('at ${width.toInt()} px with the longest names', (
        tester,
      ) async {
        await _pumpApp(tester, Size(width, 900), config: _longNames);
      });
    }
  });

  // Not "renders without throwing" — a painter that declines to draw throws
  // nothing at all. The assertion is that the *placeholder* is absent, which is
  // the only thing that distinguishes a module from an empty panel.
  //
  // Both the default size and the *minimum legal* one. The minimum is the case
  // that catches things: a one-row Number Box shipped drawing a title bar and
  // nothing else, and it was found by rendering every kind at its smallest
  // legal size rather than at the comfortable one. A threshold checked only at
  // the default is a threshold checked at one size per kind.
  group('every module draws at the supported minimum window', () {
    final canvas = _canvasFor(kMinimumWindow);

    for (final kind in ModuleKind.values) {
      for (final (variant, columns, rows) in <(String, int, int)>[
        ('default size', kind.defaultColumns, kind.defaultRows),
        ('minimum size', kind.minColumns, kind.minRows),
      ]) {
        testWidgets('${kind.name} at its $variant', (tester) async {
          await _pumpSolo(
            tester,
            kind: kind,
            columns: columns,
            rows: rows,
            canvas: canvas,
          );
          expect(
            find.byType(ModuleTooSmall),
            findsNothing,
            reason:
                '${kind.name} at its $variant does not fit the smallest window '
                'the application allows. Either the module needs less room, or '
                'its declared minimum is below what it can draw in, or the '
                'minimum window has to grow — a module that opens as a '
                'placeholder is a module nobody will keep.',
          );
        });
      }
    }
  });

  // The other half of the same rule. Below its floor a module must say so,
  // because the alternative is not a smaller meter — it is a blank panel with a
  // title bar, which reads as a fault rather than as a size.
  group('a module below its pixel floor says so', () {
    for (final kind in ModuleKind.values) {
      testWidgets(kind.name, (tester) async {
        // The canvas that makes this kind's module exactly one pixel short of
        // its floor in both axes, once the title bar and the frame's inset are
        // taken off. Solved rather than guessed: a canvas picked small enough
        // to be obviously under makes a module shorter than its own title bar,
        // and what that proves is that `Column` overflows, not that the gate
        // works.
        const chrome = Space.smd * 2;
        final module = Size(
          kind.minBodyWidth + chrome - 1,
          kind.minBodyHeight + ModuleFrame.titleBarHeight + chrome - 1,
        );
        final stride = Size(
          (module.width + Space.sm) / kind.defaultColumns,
          (module.height + Space.sm) / kind.defaultRows,
        );

        await _pumpSolo(
          tester,
          kind: kind,
          columns: kind.defaultColumns,
          rows: kind.defaultRows,
          canvas: Size(
            stride.width * kGridColumns - Space.sm,
            stride.height * kGridRows - Space.sm,
          ),
        );
        expect(find.byType(ModuleTooSmall), findsOneWidget);
      });
    }
  });

  test('every kind declares a floor a module can actually be drawn in', () {
    for (final kind in ModuleKind.values) {
      expect(kind.minBodyWidth, greaterThan(0), reason: kind.name);
      expect(kind.minBodyHeight, greaterThan(0), reason: kind.name);
    }
  });

  // **The keyboard sheet is the one panel asserted to fit.** Every other panel
  // is a list that may legitimately be longer than the window; this one is a
  // reference table, and a reference table that has to be scrolled to be read
  // is one the reader gives up on. It scrolled for a whole phase, and what the
  // fold cut in half was the footnote — the only line on the sheet that is not
  // derivable from the rows above it.
  //
  // Two windows because the sheet's width is fixed at 880: the minimum window
  // is the one that can be narrower than the panel wants, and the default is
  // the one everybody actually opens it in. Both platforms because the two
  // spellings of a chord are different lengths — `Ctrl+Shift+Tab` is the widest
  // string on the sheet and `⌃⇧⇥` is one of the narrowest, and it is the wide
  // one that decides whether the columns fit.
  group('the keyboard sheet fits without scrolling', () {
    for (final window in [kMinimumWindow, const Size(1280, 800)]) {
      for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
        testWidgets('at ${window.width.toInt()} px on ${platform.name}', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            await _pumpSheet(tester, window);

            // A `RenderFlex` overflow inside the rows is reported through the
            // error reporter and fails the test on its own; this is the other
            // half, and it is the half no exception announces.
            final position = tester
                .state<ScrollableState>(
                  find.descendant(
                    of: find.byType(PanelScaffold),
                    matching: find.byType(Scrollable),
                  ),
                )
                .position;

            expect(
              position.maxScrollExtent,
              0,
              reason:
                  'The keyboard sheet is ${position.maxScrollExtent} px taller '
                  'than the panel it is drawn in, so it scrolls and its '
                  'footnote is below the fold. Either a column has to give up '
                  'a group or the rows have to give up their air.',
            );

            // **And every description is still one line.** Height alone does
            // not catch a column that is too narrow: the descriptions wrap,
            // which costs height the panel happens to have, and the sheet
            // passes a scroll check while reading like a squeezed table. Two
            // lines of description beside one keycap is also the shape that
            // makes a row hard to attribute to its own chord.
            const line = 13 * 1.45; // BelType.body, one line.
            for (final shortcut in belShortcuts) {
              expect(
                tester.getSize(find.text(shortcut.description)).height,
                lessThan(line * 1.5),
                reason:
                    '"${shortcut.description}" wraps onto a second line, so '
                    'its column is narrower than the table needs.',
              );
            }
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }

    // Below the supported minimum the sheet stacks into one column and scrolls
    // again, which is allowed — what is not allowed is two columns too narrow
    // to hold their own keycaps, because a keycap does not shrink and a `Row`
    // that cannot fit one clips it in release with nothing said. Pumping it is
    // most of the assertion: an overflow fails the test on its own.
    testWidgets('and stacks rather than clipping below it', (tester) async {
      await _pumpSheet(tester, const Size(800, 600));

      const line = 13 * 1.45;
      for (final shortcut in belShortcuts) {
        expect(
          tester.getSize(find.text(shortcut.description)).height,
          lessThan(line * 1.5),
          reason: '"${shortcut.description}" wraps in the stacked layout.',
        );
      }
    });
  });
}

/// The keyboard sheet, open, over nothing else.
///
/// The application is not pumped: the sheet reads no measurement and owns no
/// engine, and pumping `BelApp` to reach it would make this test depend on a
/// capture device opening.
Future<void> _pumpSheet(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: belThemeData(BelColors.precisionInstrument),
      // Above the `Navigator`, where the application puts it and where
      // `showBelPanel` looks for it.
      builder: (context, child) =>
          BelTheme(colors: BelColors.precisionInstrument, child: child!),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showShortcutsSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
