// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries the active [BelColors] down the tree.
///
/// A plain [InheritedWidget] rather than a `ThemeExtension`, because almost
/// nothing in Bel is a Material widget — the meters are `CustomPainter`s and
/// the panels are `Container`s with a hairline. Going through `Theme.of` to
/// reach a palette that Material never consults would be ceremony for its own
/// sake. [belThemeData] exists to make the handful of Material widgets that do
/// appear (menus, tooltips, text fields) agree with the rest.
class BelTheme extends InheritedWidget {
  const BelTheme({required this.colors, required super.child, super.key});

  final BelColors colors;

  static BelColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<BelTheme>();
    assert(theme != null, 'No BelTheme in scope. Wrap the app in one.');
    return theme!.colors;
  }

  /// Reads the palette without subscribing to changes.
  ///
  /// For use inside `CustomPainter` construction and other places on the paint
  /// path, where re-running on a skin change is the parent's job and
  /// registering a dependency per frame would be waste.
  static BelColors read(BuildContext context) {
    final theme = context.getInheritedWidgetOfExactType<BelTheme>();
    assert(theme != null, 'No BelTheme in scope. Wrap the app in one.');
    return theme!.colors;
  }

  @override
  bool updateShouldNotify(BelTheme oldWidget) => oldWidget.colors != colors;
}

/// A Material theme derived from [colors], so the stock widgets Bel does use
/// do not arrive with their own opinions about blue.
ThemeData belThemeData(BelColors colors) {
  // The brightness comes from the palette rather than from a guess at its
  // background, because Material uses it for things no Bel colour covers —
  // menu scrims, overlay tints, the text-selection handle. A light skin under
  // a dark scheme gets all three wrong at once.
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
        );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    canvasColor: colors.panel,
    dividerColor: colors.hairline,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,

    // Material's default ripple is wrong for this: it is a soft, slow, organic
    // animation on an interface whose entire premise is instrument precision.
    // Selection is shown by a hairline changing colour instead.
    textTheme: TextTheme(
      bodyMedium: BelType.body.copyWith(color: colors.textPrimary),
      bodySmall: BelType.caption.copyWith(color: colors.textMuted),
      labelSmall: BelType.label.copyWith(color: colors.textMuted),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.panelRaised,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
        borderRadius: BelRadius.allSm,
      ),
      textStyle: BelType.caption.copyWith(color: colors.textPrimary),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
