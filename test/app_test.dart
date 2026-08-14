// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: BelTheme(
    colors: BelColors.precisionInstrument,
    child: Material(
      color: BelColors.precisionInstrument.background,
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
      const numeric = [BelType.readingSmall, BelType.tick];
      for (final style in [...numeric, BelType.reading(32)]) {
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      }
    });

    test('state colours are distinct', () {
      const colors = BelColors.precisionInstrument;
      final used = {
        for (final state in ReadingState.values) colorForState(state, colors),
      };
      // "Over" must never share a colour with anything else, or the one colour
      // in the interface that means something stops meaning it.
      expect(used.length, ReadingState.values.length);
      expect(colorForState(ReadingState.over, colors), colors.over);
    });
  });

  group('ReadoutPainter', () {
    test('reuses a laid-out paragraph until the string changes', () {
      final readout = ReadoutPainter(
        valueStyle: BelType.reading(32),
        unitStyle: BelType.unit,
        labelStyle: BelType.label,
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
