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
//   - The single bar this replaced overflowed its own row by 121 px at the
//     smallest window the platform allowed. A `Row` that cannot fit its
//     children does not shrink them; in a release build it clips them silently.
//   - The source picker overflowed its *own* row, inside the bar, where the
//     bar's width gates cannot see it: the name was capped at 220 px but never
//     made flexible, so it took its natural width however little the bar had
//     left to give it and the dot beside it went over the edge.
//   - The keyboard sheet did not fit its own panel, so it scrolled and cut its
//     footnote in half — see the group at the bottom of this file.
//
// The window has two bars since the readings moved out of the top one, and the
// second row brought a failure this file could not previously have: the
// document's name is centred in the *window* rather than between its
// neighbours, which means it is a layer of a `Stack` and not a child of the
// row — and two layers of a Stack overlap in silence. No exception, no stripe,
// no clipped control; just a name printed underneath a button. So the sweeps
// below measure the distance from that name to every control in the row as well
// as pumping for overflow, and the widths both rows do their arithmetic on are
// held against the widgets themselves. A gate is only as good as the number it
// was measured from, and twice that number was a string the running application
// had already replaced.
//
// These are pumped at real window sizes rather than the test default, because
// the test default is 800x600 and neither defect appears there.

import 'dart:io';

import 'package:oaa/src/app/bar_controls.dart';
import 'package:oaa/src/app/file_menu.dart';
import 'package:oaa/src/app/oaa_app.dart';
import 'package:oaa/src/app/preset_file.dart';
import 'package:oaa/src/app/shortcuts.dart';
import 'package:oaa/src/app/transport_readout.dart';
import 'package:oaa/src/app/window_chrome.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/modules/number_box.dart';
import 'package:oaa/src/panels/settings_panel.dart';
import 'package:oaa/src/panels/shortcuts_sheet.dart';
import 'package:oaa/src/plugin/plugin_link.dart';
import 'package:oaa/src/remote/remote_control.dart';
import 'package:oaa/src/remote/remote_display_service.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fonts the application ships, loaded so that "does the row fit" is a
/// question about Open Audio Analyzer and not about the test binding.
///
/// Without this every glyph is the placeholder font's square em box, which is
/// far wider than Inter or Google Sans Code — the bars then overflow by
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
///
/// **808 rather than 768 since the readings moved to a row of their own.** The
/// height is arithmetic on the canvas, not taste: a two-row Number Box had 4 px
/// of body to spare at 768 and the Alert Meter had exactly none, so the 40 px
/// the new row takes had to come out of the window. The module group at the
/// bottom of this file is what proves it — every kind, at its smallest legal
/// size, on the smallest window.
const Size kMinimumWindow = Size(960, 808);

/// The canvas a window size produces: both bars, the tab strip and the canvas's
/// own inset come off the height.
Size _canvasFor(Size window) => Size(
  window.width - Space.md * 2,
  window.height - BarMetrics.rowHeight * 2 - 32 - Space.md * 2,
);

/// The longest content the status bar can be asked to hold.
///
/// The calibration chip caps at 220 px and ellipsis, so anything past that name
/// renders the same — but the *default* target is "Streaming (−14 LUFS)", which
/// is 100 px short of the cap, and that is what let a real overflow through: at
/// 950 px every width gate was open and the row ran 18 px past its edge.
///
/// **Silence, not a capture device.** This asked for a device by an id no
/// machine has, and what a device that will not open produces is neither bar —
/// it is the engine-failure screen, one centred paragraph that fits every width
/// and fails nothing. Whether the widths below sweep the rows or that paragraph
/// then depends on whether the machine running them happens to have an input
/// miniaudio will fall back to, which is the difference between this developer's
/// laptop and a headless CI runner. The source label costs the row nothing
/// anyway: the picker is `Flexible` and shortens with an ellipsis, so it can
/// give back everything but its dot, its border and the seam after it — and a
/// target name at the cap squeezes it that far, which is what makes this the
/// case that catches the picker's own row overflowing as well. The fixed width
/// in the status bar is the target chip, and that is what this sets.
///
/// The menu bar has nothing this can lengthen: every control in it wears a fixed
/// word, which is a property `BarMetrics` depends on and one this file asserts
/// — see the group that measures them.
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
  bool inWindowMenu = false,
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
      // **The whole suite runs on a macOS host, where FILE is never built.**
      // The menu is in the system menu bar there, so the button that replaces
      // it on Windows and Linux would take part in no sweep in this file — and
      // it is 50-odd pixels in a row measured in tens of them.
      if (inWindowMenu) fileMenuInWindowProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const OaaApp()),
  );
  await tester.pump();

  // **The bar has to be on screen for a sweep of it to mean anything.** A
  // source that will not open replaces the whole window with the engine-failure
  // screen, which is one centred paragraph: it fits every width, overflows
  // nothing, and passes at all 221 of them. Nothing else in this file would
  // notice — a row that was never laid out cannot overflow — so the sweep would
  // go green on the day the bar stopped fitting. See `_longNames`.
  expect(
    find.byType(PublishSwitch),
    findsOneWidget,
    reason:
        'The menu bar is not on screen, so this width proves nothing about '
        'either row. The engine failed to open the configured source and the '
        'window is showing the failure screen instead.',
  );

  _expectDocumentName(tester, window);
}

/// The document's name is centred in the window and touches nothing.
///
/// **Neither half of this can fail loudly on its own.** The name is a layer of a
/// `Stack` rather than a child of the row — the only way to centre it in the
/// window when the groups either side of it are not the same width — and a Stack
/// lays its layers on top of one another without complaint. So an overflow check
/// sees nothing, a golden nobody has taken sees nothing, and what ships is a
/// name printed underneath a button.
///
/// Centred *in the window* rather than between the two groups, which is the
/// stronger claim and the one worth holding: it is what makes the row read as a
/// title bar, and it is the assertion that fails if a control is added to one
/// side and the arithmetic is not re-done.
void _expectDocumentName(
  WidgetTester tester,
  Size window, {
  String name = kUnnamedPreset,
}) {
  final title = find.text(name.toUpperCase());

  if (window.width >= kMinimumWindow.width) {
    expect(
      title,
      findsOneWidget,
      reason:
          'The open document has no name on screen at ${window.width.toInt()} '
          'px, which is at or above the narrowest window the application '
          'supports. The name is allowed to be dropped — it is the first thing '
          'to go — but not at a width somebody can actually arrange meters in.',
    );
  } else if (title.evaluate().isEmpty) {
    return;
  }

  final ink = tester.getRect(title);
  expect(
    (ink.center.dx - window.width / 2).abs(),
    lessThan(1),
    reason:
        'The document name is centred at ${ink.center.dx.toStringAsFixed(1)} '
        'px in a ${window.width.toInt()} px window, which is '
        '${(ink.center.dx - window.width / 2).abs().toStringAsFixed(1)} px off '
        'centre. The two groups either side of it are what the room is measured '
        'from, so a control added to one of them without moving that arithmetic '
        'shows up here.',
  );

  // Every control in the top row, whichever group it belongs to. Read off the
  // render objects rather than through a finder per label, so that a control
  // added to the row is covered by this the day it is added.
  for (final finder in [find.byType(BarButton), find.byType(BarSwitch)]) {
    for (final element in finder.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.top >= BarMetrics.rowHeight) continue;

      final gap = rect.left >= ink.right
          ? rect.left - ink.right
          : ink.left - rect.right;
      expect(
        gap,
        greaterThanOrEqualTo(BarMetrics.titleGap - 1),
        reason:
            'The document name is ${gap.toStringAsFixed(1)} px from a control '
            'in the menu bar at ${window.width.toInt()} px, where the row '
            'states ${BarMetrics.titleGap.toInt()}. A negative number here is '
            'a name drawn underneath a button, which nothing else in this file '
            'or in the application will report.',
      );
    }
  }
}

/// The same, with a plugin attached — which is the only state in which the bar
/// carries a transport readout.
///
/// The readout is 132 px including its two gaps, the widest single item the bar
/// can gain, and it is the only one that is not always there: sweeping without a
/// plugin sweeps a row that is 132 px narrower than the widest one a user can
/// produce. Which is how the *last* status-bar overflow shipped — the sweep was
/// green at every width because it never rendered the case with the long name in
/// it.
///
/// The frames are the plugin's own, from `plugin/test/golden/wire_v2.bin`: a
/// HELLO, a transport rolling at 120 bpm in 7/8 with drop-frame timecode, and a
/// snapshot. Read synchronously — an awaited real read inside a `testWidgets`
/// body never completes.
Future<void> _pumpAppWithPlugin(
  WidgetTester tester,
  Size window, {
  StartupConfig config = const StartupConfig(),
}) async {
  tester.view.physicalSize = window * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final frames = File('plugin/test/golden/wire_v2.bin').readAsBytesSync();

  // Real socket work, so it has to happen where the real event loop can run it.
  final port = (await tester.runAsync(() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = probe.port;
    await probe.close();
    return free;
  }))!;

  final store = ConfigStore.disabled();
  addTearDown(store.dispose);
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(config),
      pluginLinkPortProvider.overrideWithValue(port),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const OaaApp()),
  );
  await tester.pump();

  final socket = (await tester.runAsync(
    () => Socket.connect(InternetAddress.loopbackIPv4, port),
  ))!;
  addTearDown(socket.destroy);

  await tester.runAsync(() async {
    socket.add(frames);
    await socket.flush();
  });

  _expectDocumentName(tester, window);

  // Pumped until the plugin is on screen, which is what puts the readout in the
  // row — above the readout's own width gate. Waiting on the *session* rather
  // than on the readout is deliberate: below that gate there is no readout to
  // wait for, and a helper that insisted on one would fail at every width where
  // the bar is correctly dropping it.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (find.text('DAW PLUGIN — FIXTURE').evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The plugin never reached the canvas, so the bar swept without it.');
    }
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }

  // **And the readout keeps its distance from the item in front of it**, which
  // an overflow check cannot see: the seam between the status bar's `Expanded`
  // group and its right-hand one was the only one in the row with no `SizedBox`
  // of its own, so the space there was whatever the window was not using. The
  // source name ellipsises before the row overflows, so from the readout's gate
  // up to about 1310 px the row fitted perfectly with the sample rate and
  // channel count printed flush against the playhead, and every width in this
  // sweep was green while it did.
  //
  // The seam is a `SizedBox` now — the source became a bordered chip, and a
  // hairline touching the elapsed clock's digits is the same defect one step
  // narrower — so this holds a width the layout states rather than one it
  // happens to have left over. That is worth keeping: the box is sized to
  // whichever item the group ends with, and this is the assertion that says
  // which one the readout is entitled to.
  final readout = find.byType(TransportReadout);
  if (readout.evaluate().isEmpty) return;

  final format = find.textContaining('kHz');
  expect(
    format,
    findsOneWidget,
    reason:
        'The readout is on screen at a width where the format readout is not, '
        'which is backwards: the format opens at a narrower row than the '
        'transport does.',
  );
  expect(
    tester.getRect(readout).left - tester.getRect(format).right,
    greaterThanOrEqualTo(Space.lg - precisionErrorTolerance),
    reason:
        'The transport readout is closer than one group gap to the format '
        'readout beside it. The row still fits — the source name gives way '
        'first — so nothing else in this file will fail.',
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
  late final OaaEngine engine = OaaEngine.start(source: OaaSource.silence);
  late final MeterClock clock = MeterClock(engine: engine, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OaaTheme(
    colors: OaaColors.precisionInstrument,
    child: Material(
      color: OaaColors.precisionInstrument.background,
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
  group('both bars fit their rows', () {
    // From 480, which is half the supported minimum window and below every gate
    // either row has. What is left there is each row's irreducible set — the
    // File menu, the pairing code, PUBLISH, SETTINGS, RESET and `?` above; the
    // source, the elapsed clock and the delivery target below — and they fit
    // with 33 px and 108 px to spare respectively. Below it there is nothing
    // left that either row's own rule allows dropping, and what happens is left
    // to the platform: macOS is the only one of the three that enforces a
    // minimum window at all.
    //
    // It was 600 while one row carried everything, and that number was the one
    // the whole file was anchored to: the bar fitted there with 8 px in hand.
    // Splitting the readings out is what bought the 120 px, and sweeping down to
    // where the rows actually stop is what keeps the claim honest.
    for (var width = 480.0; width <= 2560.0; width += 20) {
      testWidgets('at ${width.toInt()} px', (tester) async {
        await _pumpApp(tester, Size(width, 900));
      });
    }

    testWidgets('at the supported minimum', (tester) async {
      await _pumpApp(tester, kMinimumWindow);
    });

    // The same sweep with the longest content the status bar can hold, at five
    // pixels rather than twenty.
    //
    // Both changes are here because of one bug, and either alone would have
    // missed it: the row overflowed by 18 px at 950, which the twenty-pixel
    // stride steps straight over, and only with a target name long enough to
    // reach the chip's 220 px cap. It was reported from a running application
    // against a suite of 137 green tests.
    //
    // The band stops at 800 because every gate either row has is below it and
    // both only get slacker above — 555 and 663 in the status bar, 551 and 665
    // in the menu bar, and the width at which the document's name first has room
    // to be drawn at all. The stride is what makes stepping across five cliffs
    // affordable; twenty pixels steps over three of them.
    for (var width = 480.0; width <= 800.0; width += 5) {
      testWidgets('at ${width.toInt()} px with the longest names', (
        tester,
      ) async {
        await _pumpApp(tester, Size(width, 900), config: _longNames);
      });
    }

    // And the widest row the application can produce: everything above, plus a
    // connected plugin's transport readout.
    //
    // Twenty pixels rather than five, because each of these connects a real
    // socket and waits for a real plugin session — an order of magnitude dearer
    // than a pump. The band straddles the readout's own gate, which is the cliff
    // that matters: below it the status bar is the row every case above already
    // sweeps, and above it the row only gets slacker.
    //
    // **The gate is on the status bar's own width, which is the window's.**
    // Unlike the menu bar this row has no window buttons drawn over it, so its
    // padding is `Space.md` at both ends on all three platforms and its two
    // gates are one pair of numbers rather than two. The playhead therefore
    // appears at 663 px of window here, and this band starts well below it.
    for (var width = 600.0; width <= 900.0; width += 20) {
      testWidgets('at ${width.toInt()} px with a plugin attached', (
        tester,
      ) async {
        await _pumpAppWithPlugin(tester, Size(width, 900), config: _longNames);
      });
    }

    testWidgets('at the supported minimum with a plugin attached', (
      tester,
    ) async {
      await _pumpAppWithPlugin(tester, kMinimumWindow, config: _longNames);
    });

    // **And the row Windows and Linux actually draw.** Every case above is the
    // macOS menu bar, because that is the host this suite runs on and
    // `fileMenuInWindowProvider` answers the platform — so FILE, which exists
    // only where there is no system menu bar to put it in, took part in none of
    // them. It is the leading item of the row now, which makes it part of the
    // arithmetic the centred name is measured from as well as part of the sum
    // that has to fit.
    //
    // The two arrangements are within 2 px of each other — 80 px of window
    // buttons against 16 px of padding, the button and its group seam — which is
    // why one set of gates answers both. That is a claim, so it is swept: the
    // band stops at 800 because every gate either row has is below it, and the
    // longest names because the status bar's left group is what overflows first.
    for (var width = 480.0; width <= 800.0; width += 20) {
      testWidgets('at ${width.toInt()} px with the menu in the window', (
        tester,
      ) async {
        await _pumpApp(
          tester,
          Size(width, 900),
          config: _longNames,
          inWindowMenu: true,
        );
      });
    }

    testWidgets('at the supported minimum with the menu in the window', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        kMinimumWindow,
        config: _longNames,
        inWindowMenu: true,
      );
    });
  });

  // **The widths both rows do their arithmetic on, held against the widgets
  // they describe.** Every gate in either row is a sum of `BarMetrics` plus one
  // margin, so a number in that table that is no longer what the control
  // measures is a gate that is wrong everywhere at once — and the way that
  // fails is not a green suite going red. It is a row that fits at every width
  // this file sweeps until somebody renames a button.
  //
  // Two-sided on purpose. The upper bound is the one that matters: a label that
  // has grown past its number overflows a row that the arithmetic believes has
  // room. The lower bound is what keeps the table a measurement rather than a
  // guess with padding in it — a bound 40 px slack pushes every gate above it
  // out by 40 px, which drops controls at widths they would have fitted at.
  //
  // This is the file that loads the real typefaces, so it is the only place the
  // question can be asked at all.
  group('the bar metrics are what the controls measure', () {
    testWidgets('every width in the table', (tester) async {
      await _pumpApp(
        tester,
        const Size(2560, 900),
        config: _longNames,
        inWindowMenu: true,
      );

      void expectWidth(String what, Finder finder, double bound) {
        expect(
          finder,
          findsOneWidget,
          reason: 'No $what in the row to measure.',
        );
        final measured = tester.getSize(finder).width;
        expect(
          measured,
          lessThanOrEqualTo(bound + precisionErrorTolerance),
          reason:
              '$what measures ${measured.toStringAsFixed(1)} px where '
              'BarMetrics says ${bound.toStringAsFixed(0)}. Write the measured '
              'number there — every gate above this item is a sum that includes '
              'it, and the row is now that much wider than either bar believes.',
        );
        expect(
          measured,
          greaterThan(bound - 2),
          reason:
              '$what measures ${measured.toStringAsFixed(1)} px where '
              'BarMetrics says ${bound.toStringAsFixed(0)}, so the bound is '
              'slack and every gate above this item is that much too high — it '
              'drops a control at a width the row could have held it.',
        );
      }

      Finder button(String label) =>
          find.ancestor(of: find.text(label), matching: find.byType(BarButton));

      // The two drawn as marks have no text to be found by, which is what
      // `semanticLabel` is for — and `BarButton` asserts on a mark without one.
      Finder mark(String semanticLabel) => find.byWidgetPredicate(
        (widget) =>
            widget is BarButton && widget.semanticLabel == semanticLabel,
      );

      expectWidth('FILE', button('FILE'), BarMetrics.file);
      expectWidth('ANALYSE FILE', button('ANALYSE FILE'), BarMetrics.analyse);
      expectWidth('SETTINGS', mark('Settings'), BarMetrics.settings);
      expectWidth('RESET', mark('Restart the measurement'), BarMetrics.reset);
      expectWidth('the shortcut sheet button', button('?'), BarMetrics.help);
      expectWidth('ATTACH', button('ATTACH'), BarMetrics.attach);
      expectWidth(
        'the pairing code button',
        find.byType(PairingCodeButton),
        BarMetrics.pairingCode,
      );
      expectWidth(
        'the publish switch',
        find.byType(PublishSwitch),
        BarMetrics.publish,
      );
      expectWidth(
        'the elapsed clock',
        find.byType(ElapsedReadout),
        BarMetrics.elapsed,
      );

      // The delivery target's name is past the cap in this configuration, so
      // the chip is exactly it. Both chips are `BarChip`; this is the wider.
      final chips = [
        for (final element in find.byType(BarChip).evaluate())
          (element.renderObject! as RenderBox).size.width,
      ]..sort();
      expect(
        chips.last,
        BarMetrics.pickerCap,
        reason:
            'A picker holding a name longer than the cap measures '
            '${chips.last} px rather than the cap itself, so the number the '
            'status bar reserves for it is not the number it takes.',
      );
    });

    // The two the row cannot be asked for: one is a string no device on this
    // machine produces, and the other is a state a chip only reaches when the
    // window is narrow enough to squeeze it. Both are measured directly instead.
    testWidgets('the longest format readout, and an empty chip', (
      tester,
    ) async {
      Future<Size> sizeOf(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: OaaTheme(
              colors: OaaColors.precisionInstrument,
              child: Material(child: Center(child: child)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getSize(find.byWidget(child));
      }

      // What a 192 kHz interface with 24 inputs prints. The readout on screen
      // says `48.0 kHz · 2 ch` on almost every machine, and a gate measured
      // against that is 15 px short of one that is not.
      const longest = Text(
        '192.0 kHz · 24 ch',
        style: OaaType.readingSmall,
        maxLines: 1,
        softWrap: false,
      );
      final format = (await sizeOf(longest)).width;
      expect(
        format,
        lessThanOrEqualTo(BarMetrics.format + precisionErrorTolerance),
        reason:
            'The longest format readout measures '
            '${format.toStringAsFixed(1)} px, past the '
            '${BarMetrics.format.toStringAsFixed(0)} the status bar reserves.',
      );
      expect(format, greaterThan(BarMetrics.format - 2));

      // The chip with its name given up entirely: the dot, the seam after it,
      // the padding and the border. What is left of the source picker when the
      // row has taken everything it can, and therefore the floor both of the
      // status bar's gates are measured from.
      const empty = BarChip(text: '', lit: true);
      final floor = (await sizeOf(empty)).width;
      expect(
        floor,
        lessThanOrEqualTo(BarMetrics.chipFloor),
        reason:
            'An empty source chip measures ${floor.toStringAsFixed(1)} px, past '
            'the ${BarMetrics.chipFloor.toStringAsFixed(0)} the status bar '
            'believes it can shrink to.',
      );
      // Looser than the rest, and the slack is deliberate: a name squeezed to
      // nothing still leaves an ellipsis or a glyph of its own behind, which is
      // a state no pump can be talked into producing on demand.
      expect(floor, greaterThan(BarMetrics.chipFloor - 6));
    });
  });

  // **Which row a thing is in, which is the whole point of there being two.**
  // Everything you read is at the bottom edge of the window and everything you
  // press is at the top, and neither claim is one an overflow check or a gate
  // can make. A control that drifted back into the wrong row would look
  // perfectly correct to every other test in this file.
  group('the readings are in the bottom row and the commands in the top', () {
    testWidgets('at the supported minimum window', (tester) async {
      await _pumpApp(tester, kMinimumWindow);

      final window = kMinimumWindow;

      void expectIn(String what, Finder finder, {required bool top}) {
        expect(finder, findsOneWidget, reason: 'No $what on screen.');
        final rect = tester.getRect(finder);
        final row = top
            ? Rect.fromLTWH(0, 0, window.width, BarMetrics.rowHeight)
            : Rect.fromLTWH(
                0,
                window.height - BarMetrics.rowHeight,
                window.width,
                BarMetrics.rowHeight,
              );
        expect(
          row.contains(rect.center),
          isTrue,
          reason:
              '$what is centred at ${rect.center} , which is not in the '
              '${top ? 'menu bar across the top' : 'status bar across the '
                        'bottom'}.',
        );
      }

      // The readings, and the two menus that say what a reading is. The chips
      // by type rather than by the value they hold: which device this machine
      // has is not something a test can know, and a target name long enough to
      // be interesting is one the chip ellipsises.
      expectIn('the format readout', find.textContaining('kHz'), top: false);
      expectIn('the elapsed clock', find.byType(ElapsedReadout), top: false);
      expect(find.byType(BarChip), findsNWidgets(2));
      for (final (index, element) in find.byType(BarChip).evaluate().indexed) {
        expectIn('chip $index', find.byWidget(element.widget), top: false);
      }

      // The commands, and the document they act on.
      Finder mark(String semanticLabel) => find.byWidgetPredicate(
        (widget) =>
            widget is BarButton && widget.semanticLabel == semanticLabel,
      );

      expectIn('SETTINGS', mark('Settings'), top: true);
      expectIn('RESET', mark('Restart the measurement'), top: true);
      expectIn('ANALYSE FILE', find.text('ANALYSE FILE'), top: true);
      expectIn('the publish switch', find.byType(PublishSwitch), top: true);
      expectIn('ATTACH', find.byType(AttachButton), top: true);
      expectIn(
        'the document name',
        find.text(kUnnamedPreset.toUpperCase()),
        top: true,
      );
    });

    // **The mark and a long name, neither of which the sweep can reach.** Every
    // case in it pumps a document that has never been edited and is called
    // `Unnamed`: the modified dot is not drawn, and the name is a third of what
    // the title is allowed to grow to. Both change the *ink*, and the claim is
    // about where the ink sits.
    //
    // The dot's slot is reserved on both sides of the name for this reason —
    // one side only would move the name half a character the first time
    // somebody dragged a module, which is a title that shifts while you work.
    testWidgets('with the document edited and its name at the cap', (
      tester,
    ) async {
      const window = Size(1440, 900);
      const long = 'Mastering — client B, second pass';

      await _pumpApp(tester, window);
      final before = tester.getRect(find.text(kUnnamedPreset.toUpperCase()));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PublishSwitch)),
      );
      container.read(workspaceProvider.notifier).renamePreset(long);
      // Twice, and with time on the clock: the rename lands through a Riverpod
      // refresh, which is scheduled on a zero-duration timer rather than
      // applied inline.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(
        container.read(presetModifiedProvider),
        isTrue,
        reason: 'A renamed layout differs from the file, so the mark is on.',
      );

      _expectDocumentName(tester, window, name: long);

      // The same place either way: the name is centred on the window, and the
      // mark appears in room that was already being left for it.
      final after = tester.getRect(find.text(long.toUpperCase()));
      expect(
        after.center.dx,
        closeTo(before.center.dx, 1),
        reason:
            'The document name moved '
            '${(after.center.dx - before.center.dx).abs().toStringAsFixed(1)} px '
            "when it was edited and renamed. The mark's slot is reserved on "
            'both sides so that it cannot.',
      );
    });

    // **And FILE is the leading item of the top row, where a menu bar's first
    // menu is.** Only on the platforms that draw it: on macOS the File menu is
    // in the system menu bar and this button does not exist, which is why this
    // is pumped with the arrangement forced rather than left to the host.
    testWidgets('with FILE at the leading edge', (tester) async {
      await _pumpApp(tester, kMinimumWindow, inWindowMenu: true);

      final file = tester.getRect(
        find.ancestor(of: find.text('FILE'), matching: find.byType(BarButton)),
      );
      expect(file.left, WindowChrome.menuBarLeading);
      expect(file.center.dy, lessThan(BarMetrics.rowHeight));

      // Nothing in the row is further left, which is the claim `left` alone
      // does not make: a control at the same offset would be under it.
      for (final finder in [find.byType(BarButton), find.byType(BarSwitch)]) {
        for (final element in finder.evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          if (rect.top >= BarMetrics.rowHeight || rect == file) continue;
          expect(
            rect.left,
            greaterThanOrEqualTo(file.right),
            reason:
                'A control in the menu bar starts at ${rect.left} px, left of '
                'or on top of FILE, which is the first thing in the row.',
          );
        }
      }
    });
  });

  // **The bar has to fit in the state it is used in, not only in the state it
  // starts in, and the sweep above cannot reach the second one.** Every case
  // there pumps an application that has never published — the service is owned
  // privately by the workspace and the only way in is a switch that would bind
  // a real socket — so what a published bar measures is not swept anywhere.
  //
  // It used to matter. The remote group was a button whose label *grew* when it
  // published: `REMOTE` at 73 px became `REMOTE · ON` at 100, and `REMOTE · 12`
  // at 96. Its gate was therefore measured against a string the running
  // application replaced, and between roughly 620 and 648 px of row, publishing
  // to a display overflowed a row this suite swept green for a phase.
  //
  // What replaced the growing label is not a wider gate — it is a control whose
  // width cannot depend on its state at all: a fixed word and a track built
  // from `Space`. That is a property of one widget rather than of the row, so
  // it is held here, on the widget, where it can actually be checked.
  group('a bar switch is the same width in both states', () {
    testWidgets('its state changes no dimension', (tester) async {
      Future<Size> sizeAt(bool value) async {
        await tester.pumpWidget(
          MaterialApp(
            home: OaaTheme(
              colors: OaaColors.precisionInstrument,
              child: Material(
                child: Center(
                  child: BarSwitch(
                    label: 'PUBLISH',
                    value: value,
                    semanticLabel: 'Publish these meters to this network',
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getSize(find.byType(BarSwitch));
      }

      expect(await sizeAt(false), await sizeAt(true));
    });
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
            const line = 13 * 1.45; // OaaType.body, one line.
            for (final shortcut in oaaShortcuts) {
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
      for (final shortcut in oaaShortcuts) {
        expect(
          tester.getSize(find.text(shortcut.description)).height,
          lessThan(line * 1.5),
          reason: '"${shortcut.description}" wraps in the stacked layout.',
        );
      }
    });
  });

  group('the settings panel keeps its rows', () {
    // The settings panel's widest row, at the same window.
    //
    // **A `PanelRow` gives its control whatever it asks for and its label the
    // rest**, so a segmented control that outgrows the row does not overflow —
    // the label is `Expanded` and simply gets less, and `Source` is one word
    // that cannot give any back. It clips in release with nothing said, which
    // is the same silence a keycap in a column too narrow for it is caught for
    // above. Four segments is where the row started being worth measuring.
    testWidgets('the source row keeps its label at the supported minimum', (
      tester,
    ) async {
      await _pumpSettings(tester, kMinimumWindow);

      final label = find.text('Source');
      final needed = tester
          .renderObject<RenderBox>(label)
          .getMaxIntrinsicWidth(double.infinity);

      expect(
        tester.getSize(label).width,
        greaterThanOrEqualTo(needed - precisionErrorTolerance),
        reason:
            'The Source row gives its label '
            '${tester.getSize(label).width.toStringAsFixed(1)} px where the '
            'word needs ${needed.toStringAsFixed(1)}, so it is clipped. The '
            'segmented control beside it has grown — a segment added, or one '
            'given a longer word — and a `PanelRow` takes that out of the '
            'label rather than overflowing.',
      );
    });
  });
}

/// The settings panel, open, over nothing else — the same shape as
/// [_pumpSheet] and for the same reason.
///
/// The service and the link are constructed and never started: this is a
/// question about widths, and a case that bound two sockets to ask it would be
/// testing the network.
Future<void> _pumpSettings(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final store = ConfigStore.disabled();
  addTearDown(store.dispose);
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(const StartupConfig()),
    ],
  );
  addTearDown(container.dispose);

  final remote = RemoteDisplayService(null, abiVersion: 1);
  addTearDown(remote.dispose);
  final plugins = PluginLink(port: 0);
  addTearDown(plugins.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: oaaThemeData(OaaColors.precisionInstrument),
        builder: (context, child) =>
            OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOaaPanel<void>(
              context: context,
              builder: (_) => SettingsPanel(remote: remote, plugins: plugins),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The keyboard sheet, open, over nothing else.
///
/// The application is not pumped: the sheet reads no measurement and owns no
/// engine, and pumping `OaaApp` to reach it would make this test depend on a
/// capture device opening.
Future<void> _pumpSheet(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: oaaThemeData(OaaColors.precisionInstrument),
      // Above the `Navigator`, where the application puts it and where
      // `showOaaPanel` looks for it.
      builder: (context, child) =>
          OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
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
