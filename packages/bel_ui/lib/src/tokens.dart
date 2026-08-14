// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// The spacing scale. **No widget in this repository may use a raw number for
/// padding, margin, gap or size.**
///
/// That rule sounds pedantic and is not. Twelve meter modules, six panels and a
/// canvas built by different people over different weeks drift apart one
/// `EdgeInsets.all(11)` at a time, and the result reads as amateur long before
/// anybody can point at which value is wrong. A closed set makes the drift
/// impossible rather than merely discouraged.
///
/// The scale doubles from 2 to 64 with 12, 24 and 48 filled in, because pure
/// doubling leaves a 16→32 gap that every real layout needs something inside.
abstract final class Space {
  /// Hairline separation. Between a value and its unit, and nowhere else.
  static const double xxs = 2;

  /// Inside a dense readout.
  static const double xs = 4;

  /// The default gap between related things.
  static const double sm = 8;

  /// Between a label and what it labels.
  static const double smd = 12;

  /// Standard padding inside a panel or module.
  static const double md = 16;

  /// Between unrelated groups inside one panel.
  static const double lg = 24;

  /// Between modules on the canvas, and around the canvas itself.
  static const double xl = 32;

  /// Major section separation.
  static const double xxl = 48;

  /// Full-bleed breathing room. Rare, and deliberate when used.
  static const double xxxl = 64;
}

/// Corner radii. Small, because measurement instruments are not soft.
abstract final class BelRadius {
  /// Meters, scales, anything with a graticule. Sharp corners read as precise.
  static const Radius none = Radius.zero;

  /// Chips and inline badges.
  static const Radius xs = Radius.circular(2);

  /// Buttons, fields, module frames.
  static const Radius sm = Radius.circular(4);

  /// Panels and dialogs. The largest radius in the system.
  static const Radius md = Radius.circular(8);

  static const BorderRadius allXs = BorderRadius.all(xs);
  static const BorderRadius allSm = BorderRadius.all(sm);
  static const BorderRadius allMd = BorderRadius.all(md);
}

/// Stroke widths. There is exactly one border weight, and it is a hairline.
///
/// Depth in this design comes from background steps and hairlines, never from
/// shadows. Shadows imply floating cards; measurement gear is machined panels
/// that sit flush with each other, and the difference is most of why one looks
/// professional and the other looks like a web dashboard.
abstract final class BelStroke {
  static const double hairline = 1;

  /// Meter scales, needles, graticule marks.
  static const double mark = 1.5;

  /// Emphasis on a target line or an active selection.
  static const double emphasis = 2;
}

/// The colour palette.
///
/// Instances of this class are what a "skin" is. The default below is the
/// Precision Instrument palette; user skins deserialise into the same shape,
/// which is why every colour a module might need is named here rather than
/// derived at the call site.
@immutable
class BelColors {
  const BelColors({
    required this.background,
    required this.panel,
    required this.panelRaised,
    required this.hairline,
    required this.hairlineStrong,
    required this.textPrimary,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.warn,
    required this.over,
    required this.meterTrack,
    required this.meterFill,
  });

  /// The canvas behind everything.
  final Color background;

  /// A module or panel surface.
  final Color panel;

  /// A surface that sits on top of a panel — menus, selected rows.
  final Color panelRaised;

  /// The only border colour.
  final Color hairline;

  /// A border that needs to be seen: focus, selection, active module.
  final Color hairlineStrong;

  /// Readings, and anything the eye should land on first.
  final Color textPrimary;

  /// Labels and units.
  final Color textMuted;

  /// Scale ticks, disabled state, and the em dash that means "not measured".
  final Color textFaint;

  /// In spec. The single signal hue in the whole interface — which is what
  /// makes it mean something.
  final Color accent;

  /// Approaching a limit.
  final Color warn;

  /// Over a limit. Used for nothing else, ever.
  final Color over;

  /// The unfilled part of a bar or arc.
  final Color meterTrack;

  /// The filled part, when it carries no pass/fail meaning of its own.
  final Color meterFill;

  /// Precision Instrument — graphite, one signal hue, no gradients.
  static const BelColors precisionInstrument = BelColors(
    background: Color(0xFF0B0C0E),
    panel: Color(0xFF121417),
    panelRaised: Color(0xFF171A1E),
    hairline: Color(0xFF1F2328),
    hairlineStrong: Color(0xFF2E343C),
    textPrimary: Color(0xFFE6E8EB),
    textMuted: Color(0xFF8A9199),
    textFaint: Color(0xFF565E67),
    accent: Color(0xFF35E0C4),
    warn: Color(0xFFF2B01E),
    over: Color(0xFFFF4D4D),
    meterTrack: Color(0xFF1A1E23),
    meterFill: Color(0xFF6E7A85),
  );
}

/// Type styles.
///
/// Two families, and the split is functional rather than decorative: prose and
/// labels are proportional, every number is monospaced with tabular figures.
///
/// Tabular figures are not a nicety here. A loudness readout updates many times
/// a second, and with proportional digits the number's width changes as the
/// digits change, so the whole readout jitters left and right while you watch
/// it. It is the single most obvious tell of a meter written by somebody who
/// does not use meters.
abstract final class BelType {
  /// Bundled in Phase 2. Until then these fall through to whatever the
  /// platform offers, which is a real monospace on all five targets — good
  /// enough to build against, not good enough to ship, because the tracking and
  /// digit width differ per platform and the layout is tuned to one of them.
  static const String uiFamily = 'Inter';
  static const String monoFamily = 'JetBrains Mono';

  static const List<String> _uiFallback = [
    'SF Pro Text',
    'Segoe UI',
    'Roboto',
    'DejaVu Sans',
  ];

  static const List<String> _monoFallback = [
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ];

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // --- Numbers ------------------------------------------------------------

  /// The one big number in a module. Sized by the module, not fixed here.
  static TextStyle reading(double size) => TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: size,
    height: 1.0,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.5,
    fontFeatures: _tabular,
  );

  /// Secondary numbers: scale ticks, per-channel values, table cells.
  static const TextStyle readingSmall = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w400,
    fontFeatures: _tabular,
  );

  /// Numbers on a scale or graticule. Small enough to disappear until wanted.
  static const TextStyle tick = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: 10,
    height: 1.0,
    fontWeight: FontWeight.w400,
    fontFeatures: _tabular,
  );

  // --- Words --------------------------------------------------------------

  /// A module's title, and panel section headers. Uppercase, tracked out.
  static const TextStyle label = TextStyle(
    fontFamily: uiFamily,
    fontFamilyFallback: _uiFallback,
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  );

  /// The unit next to a reading, and any inline annotation.
  static const TextStyle unit = TextStyle(
    fontFamily: uiFamily,
    fontFamilyFallback: _uiFallback,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w500,
  );

  /// Body text in panels and dialogs.
  static const TextStyle body = TextStyle(
    fontFamily: uiFamily,
    fontFamilyFallback: _uiFallback,
    fontSize: 13,
    height: 1.45,
    fontWeight: FontWeight.w400,
  );

  /// Explanatory text under a control.
  static const TextStyle caption = TextStyle(
    fontFamily: uiFamily,
    fontFamilyFallback: _uiFallback,
    fontSize: 11,
    height: 1.4,
    fontWeight: FontWeight.w400,
  );
}
