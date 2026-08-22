// SPDX-License-Identifier: GPL-3.0-or-later
//
// The direction of a menu's selected row.
//
// Every menu in the application marked its current value by making it the
// *lightest* row in the menu, which put the emphasis on the one choice pressing
// it cannot change and left the options you can still take reading as the
// disabled ones. The row is recessed now — see `OaaMenuRow`. There is nothing in
// the widget suite that would notice it flipping back, and nothing about a
// screenshot says which way round it is meant to be, so the direction is
// asserted here as an inequality rather than as a colour: the selected row is
// **darker than the surface the menu is drawn on**, in every skin.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/canvas/menus.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// The fill of the row holding [label], or `null` when it has none.
///
/// The row's own decoration is the outermost one inside it; a panel menu's
/// selection mark is a second, nested one, so this takes the first.
Color? _fillOf(WidgetTester tester, String label) {
  final row = find.ancestor(
    of: find.text(label),
    matching: find.byType(OaaMenuRow),
  );
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: row, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color;
}

Future<void> _pump(
  WidgetTester tester,
  OaaColors colors,
  Widget Function(BuildContext) home,
) => tester.pumpWidget(
  MaterialApp(
    theme: oaaThemeData(colors),
    builder: (context, child) => OaaTheme(colors: colors, child: child!),
    home: Material(
      color: colors.background,
      child: Builder(builder: home),
    ),
  ),
);

void main() {
  for (final skin in BuiltInSkins.all) {
    final colors = oaaColorsFromSkin(skin);

    test('${skin.id} recesses rather than raises', () {
      // What makes the fill legible at all, and the half of the rule no widget
      // test can see: a skin whose background is not a step *down* from its
      // raised panel would mark the current value by making it lighter again,
      // with every widget below still passing.
      expect(
        colors.background.computeLuminance(),
        lessThan(colors.panelRaised.computeLuminance()),
        reason: 'the fill a selected menu row takes must be the deeper surface',
      );
    });

    testWidgets('a module setting menu recesses its current value in '
        '${skin.id}', (tester) async {
      await _pump(
        tester,
        colors,
        (context) => Center(
          child: GestureDetector(
            onTap: () => showMenu<SpectrumTilt>(
              context: context,
              color: colors.panelRaised,
              position: menuPositionAt(context, Offset.zero),
              items: [
                for (final tilt in SpectrumTilt.values)
                  oaaMenuItem(
                    context,
                    tilt,
                    tilt.label,
                    selected: tilt == SpectrumTilt.db3,
                  ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(_fillOf(tester, SpectrumTilt.db3.label), colors.background);
      for (final tilt in SpectrumTilt.values.where(
        (tilt) => tilt != SpectrumTilt.db3,
      )) {
        expect(
          _fillOf(tester, tilt.label),
          isNull,
          reason: '${tilt.label} is not the current value',
        );
      }
    });

    testWidgets('a menu of actions fills nothing and mutes nothing in '
        '${skin.id}', (tester) async {
      // `selected: null` is not `selected: false`. Every row in an action menu
      // is something you can do, so none of them is an option that lost —
      // collapsing the two greyed out and un-filled every action menu in the
      // application at once.
      await _pump(
        tester,
        colors,
        (context) => Center(
          child: GestureDetector(
            onTap: () => showMenu<int>(
              context: context,
              color: colors.panelRaised,
              position: menuPositionAt(context, Offset.zero),
              items: [
                oaaMenuItem(context, 0, 'Duplicate'),
                oaaMenuItem(context, 1, 'Delete', color: colors.over),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(_fillOf(tester, 'Duplicate'), isNull);
      expect(_fillOf(tester, 'Delete'), isNull);
      expect(
        tester.widget<Text>(find.text('Duplicate')).style?.color,
        colors.textPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Delete')).style?.color,
        colors.over,
      );
    });

    testWidgets('a panel menu recesses its current value in ${skin.id}', (
      tester,
    ) async {
      await _pump(
        tester,
        colors,
        (context) => Center(
          child: PanelMenu<String>(
            label: 'Streaming',
            selected: 'streaming',
            options: const [
              (value: 'streaming', label: 'Streaming'),
              (value: 'podcast', label: 'Podcast'),
            ],
            onSelected: (_) {},
          ),
        ),
      );

      // The control's own label carries the same string as its selected row, so
      // the menu is opened by tapping the control and read by the row that
      // arrived on top of it.
      await tester.tap(find.text('Streaming'));
      await tester.pumpAndSettle();

      expect(_fillOf(tester, 'Podcast'), isNull);
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color ==
                      colors.background,
            )
            .evaluate(),
        hasLength(1),
        reason: 'exactly one row in the menu is the current value',
      );
    });
  }
}
