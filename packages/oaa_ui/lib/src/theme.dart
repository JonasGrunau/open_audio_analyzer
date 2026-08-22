// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries the active [OaaColors] down the tree.
///
/// A plain [InheritedWidget] rather than a `ThemeExtension`, because almost
/// nothing in Open Audio Analyzer is a Material widget — the meters are
/// `CustomPainter`s and the panels are `Container`s with a hairline. Going
/// through `Theme.of` to reach a palette that Material never consults would be
/// ceremony for its own sake. [oaaThemeData] exists to make the handful of
/// Material widgets that do appear (menus, tooltips, text fields) agree with
/// the rest.
class OaaTheme extends InheritedWidget {
  const OaaTheme({required this.colors, required super.child, super.key});

  final OaaColors colors;

  static OaaColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<OaaTheme>();
    assert(theme != null, 'No OaaTheme in scope. Wrap the app in one.');
    return theme!.colors;
  }

  /// The palette if one is in scope, and null where there is none.
  ///
  /// For `showOaaPanel`, which asks whether the application installed a palette
  /// *above its `Navigator`* — where a route can see it — and falls back to the
  /// one captured at the call site when it did not. Everything else wants [of]:
  /// a widget that tolerates the palette being absent is a widget that will one
  /// day be drawn in somebody's guess at it.
  static OaaColors? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OaaTheme>()?.colors;

  /// Reads the palette without subscribing to changes.
  ///
  /// For use inside `CustomPainter` construction and other places on the paint
  /// path, where re-running on a skin change is the parent's job and
  /// registering a dependency per frame would be waste.
  static OaaColors read(BuildContext context) {
    final theme = context.getInheritedWidgetOfExactType<OaaTheme>();
    assert(theme != null, 'No OaaTheme in scope. Wrap the app in one.');
    return theme!.colors;
  }

  @override
  bool updateShouldNotify(OaaTheme oldWidget) => oldWidget.colors != colors;
}

/// A Material theme derived from [colors], so the stock widgets Open Audio
/// Analyzer does use do not arrive with their own opinions about blue.
ThemeData oaaThemeData(OaaColors colors) {
  // The brightness comes from the palette rather than from a guess at its
  // background, because Material uses it for things no Open Audio Analyzer
  // colour covers — menu scrims, overlay tints, the text-selection handle. A
  // light skin under a dark scheme gets all three wrong at once.
  //
  // **`outlineVariant` has to be named even though `outline` is right beside
  // it.** A `ColorScheme` role left unset is not a muted default — it is
  // `outlineVariant => _outlineVariant ?? onBackground`, and the two baseline
  // factories default `onBackground` to `Colors.white` and `Colors.black`. So
  // the rule under "Silence" in the signal-source menu was drawn at
  // `0xFFFFFFFF` across a `0xFF171A1E` menu: pure white, brighter than
  // `textPrimary`, the loudest thing anywhere in a graphite interface, and the
  // one value in the whole theme that came from no palette at all. It is
  // `hairline` now — the same rule `ModuleFrame` draws under a title bar and
  // the tab strip draws between its actions, at a step of eight counts.
  //
  // State every role this application leans on. The fallback for a boundary
  // colour is a foreground colour, and a foreground colour is never subtle.
  final scheme = colors.isLight
      ? ColorScheme.light(
          surface: colors.panel,
          onSurface: colors.textPrimary,
          primary: colors.accent,
          onPrimary: colors.panel,
          secondary: colors.accent,
          onSecondary: colors.panel,
          error: colors.over,
          onError: colors.panel,
          outline: colors.hairline,
          outlineVariant: colors.hairline,
        )
      : ColorScheme.dark(
          surface: colors.panel,
          onSurface: colors.textPrimary,
          primary: colors.accent,
          onPrimary: colors.background,
          secondary: colors.accent,
          onSecondary: colors.background,
          error: colors.over,
          onError: colors.background,
          outline: colors.hairline,
          outlineVariant: colors.hairline,
        );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    canvasColor: colors.panel,

    // `dividerColor` is the Material 2 reading of this and no longer the one
    // that decides anything: under Material 3 a `Divider` takes
    // `DividerTheme`, and falls through to `colorScheme.outlineVariant` where
    // there is none. Set here as well because the scheme's own
    // `outlineVariant` also answers for outlined fields and chips, and a rule
    // between two menu items wants the hairline the rest of the application
    // draws every division with — the one in `ModuleFrame` under a title bar,
    // the one in the tab strip.
    dividerColor: colors.hairline,
    // [OaaStroke.mark] rather than a hairline, and this is the one rule in the
    // application that wants the heavier weight. A menu is drawn on
    // `panelRaised`, one background step above the panel a `ModuleFrame`'s rule
    // divides — so the same `hairline` colour has eight counts of contrast to
    // work with there instead of thirteen, and at a single pixel it fades to
    // the point where the menu reads as one unbroken list. Half a pixel more
    // gives it back without reaching for a brighter colour.
    dividerTheme: DividerThemeData(
      color: colors.hairline,
      thickness: OaaStroke.mark,
      space: Space.sm,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,

    // Material's default ripple is wrong for this: it is a soft, slow, organic
    // animation on an interface whose entire premise is instrument precision.
    // Selection is shown by a hairline changing colour instead.
    textTheme: TextTheme(
      bodyMedium: OaaType.body.copyWith(color: colors.textPrimary),
      bodySmall: OaaType.caption.copyWith(color: colors.textMuted),
      labelSmall: OaaType.label.copyWith(color: colors.textMuted),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.panelRaised,
        border: Border.all(color: colors.hairline, width: OaaStroke.hairline),
        borderRadius: OaaRadius.allSm,
      ),
      textStyle: OaaType.caption.copyWith(color: colors.textPrimary),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
