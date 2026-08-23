// SPDX-License-Identifier: GPL-3.0-or-later
//
// How a menu says which row it already holds.
//
// Every menu in the application once marked its current value by making it the
// *lightest* row in the menu, which put the emphasis on the one choice pressing
// it cannot change and left the options you can still take reading as the
// disabled ones. The fix was a fill, and the fill was [OaaColors.background] —
// the deepest surface in the skin, under a menu drawn two steps above it, which
// read as a hole punched in the menu rather than as a row of it.
//
// What ships now is three signals and none of them is a hue: a band spanning
// the menu edge to edge, a check in the column every row of that menu reserves,
// and the label in [OaaColors.textPrimary]. Nothing about a screenshot says
// which of those is meant to be there, and the widget suite would not notice
// any of them going, so all three are asserted here — along with the thing that
// is easiest to lose by accident: an action menu, which has no current value,
// must get none of it.
//
// The band itself is asserted twice over: that it is the one `OaaMenuRow`
// computes, and — the part that is a claim about the *design* rather than about
// the code — that what that computes can actually be seen against the surface
// the menu is drawn on. Both fills this row has carried failed that: 1.13:1 for
// `background`, and 1.09:1 for `hairline` in the dark skin against 1.31:1 for
// the same value in the light one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/canvas/menus.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

Finder _rowOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(OaaMenuRow));

/// The fill of the row holding [label], or `null` when it has none.
Color? _fillOf(WidgetTester tester, String label) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(of: _rowOf(label), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).color;
}

/// Whether the row holding [label] carries the check.
bool _checked(WidgetTester tester, String label) => find
    .descendant(of: _rowOf(label), matching: find.byType(OaaGlyph))
    .evaluate()
    .isNotEmpty;

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

/// WCAG's ratio, which is a poor model of how a near-black band reads against a
/// near-black surface but is the only number both skins can be held to.
double _contrast(Color a, Color b) {
  final (hi, lo) = a.computeLuminance() > b.computeLuminance()
      ? (a.computeLuminance(), b.computeLuminance())
      : (b.computeLuminance(), a.computeLuminance());
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final skin in BuiltInSkins.all) {
    final colors = oaaColorsFromSkin(skin);

    test('${skin.id} draws a band that can be seen on the menu', () {
      // The floor is under the mix `OaaMenuRow` uses, which lands at about
      // 1.22:1 in both shipped skins, and over both fills that came before it.
      expect(
        _contrast(OaaMenuRow.bandOn(colors), colors.panelRaised),
        greaterThan(1.15),
        reason: 'a band nobody can see is a menu with no current value',
      );
    });

    testWidgets('a module setting menu bands and checks its current value in '
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

      expect(
        _fillOf(tester, SpectrumTilt.db3.label),
        OaaMenuRow.bandOn(colors),
      );
      expect(_checked(tester, SpectrumTilt.db3.label), isTrue);
      for (final tilt in SpectrumTilt.values.where(
        (tilt) => tilt != SpectrumTilt.db3,
      )) {
        expect(
          _fillOf(tester, tilt.label),
          isNull,
          reason: '${tilt.label} is not the current value',
        );
        expect(
          _checked(tester, tilt.label),
          isFalse,
          reason: '${tilt.label} is not the current value',
        );
      }

      // The band spans the menu rather than sitting inside it as a chip: the
      // filled row is exactly as wide as the row above it, which is as wide as
      // the menu Material's own content box.
      final filled = tester.getSize(_rowOf(SpectrumTilt.db3.label));
      final unfilled = tester.getSize(_rowOf(SpectrumTilt.values.first.label));
      expect(filled.width, unfilled.width);
      expect(
        filled.width,
        tester.getSize(find.byType(ListBody)).width,
        reason: 'the band reaches both sides of the menu',
      );

      // And every row of a menu that holds a value is indented past the check,
      // whether it carries one or not, so the labels do not step sideways when
      // the value moves.
      expect(
        tester.getTopLeft(find.text(SpectrumTilt.db3.label)).dx,
        tester.getTopLeft(find.text(SpectrumTilt.values.last.label)).dx,
      );
    });

    testWidgets('a menu of actions fills nothing, checks nothing and indents '
        'nothing in ${skin.id}', (tester) async {
      // `selected: null` is not `selected: false`. Every row in an action menu
      // is something you can do, so none of them is an option that lost —
      // collapsing the two greyed out and un-filled every action menu in the
      // application at once, and now would indent them past a check column
      // none of their rows can ever carry.
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
      expect(_checked(tester, 'Duplicate'), isFalse);
      expect(
        tester.widget<Text>(find.text('Duplicate')).style?.color,
        colors.textPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Delete')).style?.color,
        colors.over,
      );
      expect(
        tester.getTopLeft(find.text('Duplicate')).dx -
            tester.getTopLeft(_rowOf('Duplicate')).dx,
        Space.md,
        reason: 'an action menu indents by the padding and nothing else',
      );
    });

    testWidgets('a panel menu bands and checks its current value in ${skin.id}', (
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
      expect(_checked(tester, 'Podcast'), isFalse);
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color ==
                      OaaMenuRow.bandOn(colors),
            )
            .evaluate(),
        hasLength(1),
        reason: 'exactly one row in the menu is the current value',
      );
    });
  }
}
