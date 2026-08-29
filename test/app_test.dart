// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:oaa/src/app/window_chrome.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: OaaTheme(
    colors: OaaColors.precisionInstrument,
    child: Material(
      color: OaaColors.precisionInstrument.background,
      child: child,
    ),
  ),
);

void main() {
  group('ModuleFrame', () {
    testWidgets('titles are uppercased and the body is isolated', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 200,
            height: 100,
            child: ModuleFrame(title: 'LUFS-I', child: Text('body')),
          ),
        ),
      );

      expect(find.text('LUFS-I'), findsOneWidget);

      // A RepaintBoundary around the body is not a detail. Without it, a
      // spectrogram scrolling at 60 fps marks the whole panel dirty and the
      // hairline border is re-rastered with it, every frame, forever.
      expect(
        find.descendant(
          of: find.byType(ModuleFrame),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });

    testWidgets('the menu affordance only appears when it does something', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 200,
            height: 100,
            child: ModuleFrame(title: 'Peak', child: SizedBox()),
          ),
        ),
      );
      expect(find.byType(GestureDetector), findsNothing);

      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 200,
            height: 100,
            child: ModuleFrame(
              title: 'Peak',
              onMenu: () => tapped = true,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(GestureDetector));
      expect(tapped, isTrue);
    });
  });

  group('WindowDragArea', () {
    // The menu bar is the window's title bar on macOS, so every control in
    // it sits under this widget's gesture recognisers. It answered a double
    // click with a zoom, and a `DoubleTapGestureRecognizer` holds the gesture
    // arena until `kDoubleTapTimeout` expires — so nothing underneath could
    // resolve a tap for 300 ms and the whole row felt like an application that
    // was busy. The gesture is back and the recogniser is not: what the bar
    // recognises is a single tap, which resolves on the pointer up like the
    // buttons' own do, and the pair is counted in `MainFlutterWindow.swift`.
    //
    // **Real on macOS and vacuous everywhere else**, because the widget is its
    // own child off macOS. That is the right way round: the defect only ever
    // existed on the platform where the tests mean something — so the two
    // expectations below are the platform's rather than a constant.
    const chrome = MethodChannel('oaa/window_chrome');
    late List<String> calls;

    setUp(() {
      calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(chrome, (call) async {
            calls.add(call.method);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(chrome, null),
      );
    });

    testWidgets('a control under it answers on release, and alone', (
      tester,
    ) async {
      var pressed = false;
      await tester.pumpWidget(
        _wrap(
          WindowDragArea(
            child: OaaButton(label: 'RESET', onPressed: () => pressed = true),
          ),
        ),
      );

      await tester.tap(find.text('RESET'));
      // One frame, no elapsed time. A held arena would still be holding.
      await tester.pump();

      expect(pressed, isTrue);
      // The other half of it: a click a control took is not also a click on
      // the title bar, or double-clicking RESET would zoom the window.
      expect(calls, isEmpty);
    });

    testWidgets('a click the bar itself wins is a click on a title bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const WindowDragArea(
            // The menu bar reduced to the part that matters here: a filled
            // box, which is opaque to a hit test. `deferToChild` sees a click
            // only where something under it does, and the bar's own fill is
            // what answers for it between the controls.
            child: ColoredBox(color: Color(0xFF121417)),
          ),
        ),
      );

      await tester.tapAt(const Offset(200, 20));
      await tester.pump();

      expect(calls, Platform.isMacOS ? ['titleBarClick'] : isEmpty);
    });
  });

  group('cached text', () {
    // The trap this guards is silent in both directions, which is why it is
    // worth a test that reads source rather than pixels: a paragraph laid out
    // with no width gets a line box a megapixel wide, so aligning it centre or
    // right draws the glyph half a megapixel from where the caller paints it —
    // and `longestLine` still reports the ink, so every measurement taken
    // around the label agrees that it is exactly where it is not. The `M` and
    // `S` under the LUFS meter's bars were invisible this way for a phase.
    test('nothing aligns a paragraph inside a box it never asked for', () {
      final offenders = <String>[];

      for (final directory in const [
        'lib/src/modules',
        'packages/oaa_ui/lib/src',
      ]) {
        for (final file in Directory(directory).listSync().whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          // Calls are matched whole — the alignment and the width are often on
          // different lines — and only the two alignments that move the ink
          // are at issue. `TextAlign.left` in an infinite box is a no-op.
          for (final call in RegExp(
            r'(layoutParagraph|\.of)\((?:[^()]|\([^()]*\))*\)',
            dotAll: true,
          ).allMatches(file.readAsStringSync())) {
            final text = call.group(0)!;
            if (!text.contains('TextAlign.center') &&
                !text.contains('TextAlign.right')) {
              continue;
            }
            if (text.contains('maxWidth')) continue;
            offenders.add('${file.path}: ${text.split('\n').first}');
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });

  group('design tokens', () {
    test('the spacing scale is strictly increasing', () {
      const scale = [
        Space.xxs,
        Space.xs,
        Space.sm,
        Space.smd,
        Space.md,
        Space.lg,
        Space.xl,
        Space.xxl,
        Space.xxxl,
      ];
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]));
      }
      expect(scale.first, 2);
      expect(scale.last, 64);
    });

    test('every numeric style uses tabular figures', () {
      // A readout whose digits change width jitters while you watch it. This
      // is the one typographic rule that is worth a test.
      const numeric = [OaaType.readingSmall, OaaType.tick];
      for (final style in [...numeric, OaaType.reading(32)]) {
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      }
    });

    test('a reading is the accent, and a problem is its own colour', () {
      const colors = OaaColors.precisionInstrument;
      final used = {
        for (final state in ReadingState.values) colorForState(state, colors),
      };
      // Four colours for five states: a reading with no verdict and a reading
      // in spec are both the signal hue, because the hue says "this is a
      // measurement" and the palette spends its other colours on what is
      // *wrong* with one.
      expect(used.length, ReadingState.values.length - 1);
      expect(
        colorForState(ReadingState.neutral, colors),
        colorForState(ReadingState.inSpec, colors),
      );
      // "Over" must never share a colour with anything else, or the one colour
      // in the interface that means something stops meaning it.
      expect(colorForState(ReadingState.over, colors), colors.over);
      // And no reading is ever the ink of the chrome around it. This is the
      // assertion that would have caught the state these five were in for
      // eleven phases: a number in `textPrimary` beside a menu label in
      // `textPrimary`.
      for (final state in ReadingState.values) {
        expect(colorForState(state, colors), isNot(colors.textPrimary));
      }
    });
  });

  group('Material theme', () {
    // Every skin, because the failure below is per-brightness: the unset role
    // resolved to white under the dark factory and to black under the light
    // one, so a test on one palette passes while the other skin is wrong.
    for (final skin in BuiltInSkins.all) {
      test('${skin.name} draws a divider in its own hairline', () {
        final colors = oaaColorsFromSkin(skin);
        final theme = oaaThemeData(colors);

        // The rule between two menu items, resolved the way a Material 3
        // `Divider` resolves it: `DividerTheme` first, then the scheme.
        expect(theme.dividerTheme.color, colors.hairline);
        expect(theme.colorScheme.outlineVariant, colors.hairline);
        // Heavier than a border on purpose — a hairline has eight counts of
        // contrast against `panelRaised` and reads as nothing there.
        expect(theme.dividerTheme.thickness, OaaStroke.mark);

        // The assertion that would have caught it. `outlineVariant` unset
        // falls back to `onBackground`, which the baseline factories default
        // to pure white and pure black — so the divider in the signal-source
        // menu was `0xFFFFFFFF` on a `0xFF171A1E` menu, brighter than any
        // colour the palette names. A boundary colour that equals a text
        // colour is a boundary colour nobody chose.
        for (final role in [
          theme.colorScheme.outlineVariant,
          theme.colorScheme.outline,
        ]) {
          expect(role, isNot(colors.textPrimary));
          expect(role, isNot(const Color(0xFFFFFFFF)));
          expect(role, isNot(const Color(0xFF000000)));
        }
      });
    }
  });

  group('ReadoutPainter', () {
    test('reuses a laid-out paragraph until the string changes', () {
      final readout = ReadoutPainter(
        valueStyle: OaaType.reading(32),
        unitStyle: OaaType.unit,
        labelStyle: OaaType.label,
      );
      addTearDown(readout.dispose);

      const color = Color(0xFFE6E8EB);
      final first = readout.value('-14.2', color, 32, 200);
      final again = readout.value('-14.2', color, 32, 200);

      // The whole point of the cache: a value changes continuously, but the
      // string rounded to one decimal changes about ten times a second. Laying
      // out on the other fifty frames is pure waste.
      expect(identical(first, again), isTrue);

      final changed = readout.value('-14.3', color, 32, 200);
      expect(identical(first, changed), isFalse);
    });
  });
}
