// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// The spacing scale. **No widget in this repository may use a raw number for
/// padding, margin, gap or size.**
///
/// That rule sounds pedantic and is not. Thirteen meter modules, six panels and a
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

  /// Between two panels, and around a dialog's content.
  ///
  /// Deliberately *not* the gutter between modules on the canvas: with 24
  /// columns there are 23 gutters across the screen, and 32 px each would spend
  /// a third of a laptop display on empty space. The canvas uses [sm] between
  /// modules and [md] around itself — see `GridGeometry`.
  static const double xl = 32;

  /// Major section separation.
  static const double xxl = 48;

  /// Full-bleed breathing room. Rare, and deliberate when used.
  static const double xxxl = 64;
}

/// The metrics every boxed control shares.
///
/// A button, a menu, a segmented control and a text field stand side by side in
/// a panel row, and three of them agreeing on a height while the fourth is two
/// pixels short is the defect nobody can name and everybody sees. Before this
/// existed each control derived its own height from its own type style and its
/// own padding, so a `BelButton` came out at 30, a `SegmentedControl` at 31.4
/// and a `BelTextField` at 28.9 — a row of controls that had never once been
/// the same height as each other.
///
/// One number, applied by the four controls in `panel.dart`. Anything that
/// wants a different height is not one of these controls.
abstract final class BelControl {
  /// The height of a button, menu, segmented control or field.
  static const double height = Space.xl;

  /// The gap inside one, from the border to the text.
  static const double padding = Space.smd;
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
    this.isLight = false,
  });

  /// The canvas behind everything.
  final Color background;

  /// A module or panel surface.
  final Color panel;

  /// A surface that sits on top of a panel — menus, selected rows.
  final Color panelRaised;

  /// The only border colour.
  final Color hairline;

  /// A border that needs to be seen: selection, hover, an active module.
  ///
  /// Held at roughly 3:1 against [panel] in both shipped skins. The value this
  /// role carried before was 1.47:1 — a border whose entire job is to be seen,
  /// set to a colour that could not be, so every caller that actually needed
  /// visible selection reached past it for [accent] instead. Fixing the value
  /// is what makes the role usable and lets the signal hue go back to meaning
  /// one thing.
  ///
  /// Selection takes it at [BelStroke.emphasis]; keyboard focus is a hairline
  /// in [textPrimary], so the two are told apart by weight and brightness
  /// rather than by hue.
  final Color hairlineStrong;

  /// Readings, and anything the eye should land on first.
  final Color textPrimary;

  /// Labels and units.
  final Color textMuted;

  /// Scale ticks and disabled state.
  ///
  /// It used to carry a third job — the em dash that means "not measured" — and
  /// at 2.81:1 against [panel] that set the statement *this quantity was not
  /// measured* below the legibility floor while the numbers beside it sat at
  /// 15:1. A graticule tick is meant to recede; a statement about the data is
  /// not, and this one is the visible half of the rule that a quantity the
  /// engine does not compute is never rendered as a plausible number. The dash
  /// is [textMuted] now.
  final Color textFaint;

  /// In spec.
  ///
  /// **On the measurement surface this hue means exactly one thing.** The
  /// canvas, the modules and every verdict reserve it for "within the delivery
  /// target", and nothing there may borrow it — not a selected module, not the
  /// active tab, not a highlighted menu row. A teal border meaning "selected"
  /// beside a teal number meaning "in spec" is a meter you have to stop and
  /// think about before you can read, which is the one thing a meter may never
  /// be. Chrome that needs to stand out uses [hairlineStrong] or [textPrimary].
  ///
  /// Modal panels are the single exception, and it is a decision rather than a
  /// leak: a panel covers the canvas, so there is no reading on screen to be
  /// confused with, and an affirmative action that cannot be told from a
  /// secondary one is a worse failure than a hue serving two contexts. Note
  /// that selection *inside* a panel still uses [hairlineStrong] — the
  /// exception buys the primary button, not the highlight.
  final Color accent;

  /// Approaching a limit.
  final Color warn;

  /// Over a limit.
  ///
  /// Used for nothing else on the measurement surface. Two interaction states
  /// borrow it and are listed here rather than left to be discovered: the
  /// destructive button emphasis, and the outline of a layout drop the grid
  /// will refuse. Both are refusals, both are momentary, and neither can be on
  /// screen at the same time as a reading it might be mistaken for — but the
  /// honest version of "used for nothing else, ever" is this list.
  final Color over;

  /// The unfilled part of a bar or arc.
  ///
  /// **It has to be visible, because how much room is left is half of what a
  /// meter says.** Held at roughly 1.6:1 against [panel] in both shipped
  /// skins. The value this role carried before was 1.10:1 dark and 1.22:1
  /// light — a track indistinguishable from the surface behind it, which left
  /// a bar that showed its own fill and nothing else, and three Super Meter
  /// arcs whose extent you could only infer from the one that happened to be
  /// lit.
  ///
  /// The ceiling is [meterFill]: the track stays about 2.5:1 *below* the fill,
  /// so the reading is still the figure and the track is still the ground. A
  /// track raised until it competes is a second bar, which is worse than an
  /// invisible one.
  final Color meterTrack;

  /// The filled part, when it carries no pass/fail meaning of its own.
  final Color meterFill;

  /// Whether this palette is dark ink on a light ground.
  ///
  /// Not derived from [background], because a palette is free to be low
  /// contrast and the guess would be wrong exactly where it matters. It decides
  /// the Material [ColorScheme]'s brightness, which is what the few stock
  /// widgets Bel does use consult when they pick their own scrim and overlay
  /// colours — a light skin with a dark scheme gets dark menu shadows over pale
  /// panels and reads as a rendering fault.
  final bool isLight;

  /// Value equality, and it is load-bearing rather than tidy.
  ///
  /// Every module painter's `shouldRepaint` compares its palette. While the
  /// palette was a compile-time constant, identity was equality and the
  /// comparison was free. Skins end that: the palette is now built from a
  /// document, and without this a rebuild that produced an identical palette
  /// would re-rasterise all thirteen modules — and `BelTheme.updateShouldNotify`
  /// would notify the whole tree on every skin *re-read*, not every skin
  /// change.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BelColors &&
          other.background == background &&
          other.panel == panel &&
          other.panelRaised == panelRaised &&
          other.hairline == hairline &&
          other.hairlineStrong == hairlineStrong &&
          other.textPrimary == textPrimary &&
          other.textMuted == textMuted &&
          other.textFaint == textFaint &&
          other.accent == accent &&
          other.warn == warn &&
          other.over == over &&
          other.meterTrack == meterTrack &&
          other.meterFill == meterFill &&
          other.isLight == isLight;

  @override
  int get hashCode => Object.hash(
    background,
    panel,
    panelRaised,
    hairline,
    hairlineStrong,
    textPrimary,
    textMuted,
    textFaint,
    accent,
    warn,
    over,
    meterTrack,
    meterFill,
    isLight,
  );

  /// Precision Instrument — graphite, one signal hue, no gradients.
  static const BelColors precisionInstrument = BelColors(
    background: Color(0xFF0B0C0E),
    panel: Color(0xFF121417),
    panelRaised: Color(0xFF171A1E),
    hairline: Color(0xFF1F2328),
    hairlineStrong: Color(0xFF5A646E),
    textPrimary: Color(0xFFE6E8EB),
    textMuted: Color(0xFF8A9199),
    textFaint: Color(0xFF565E67),
    accent: Color(0xFF35E0C4),
    warn: Color(0xFFF2B01E),
    over: Color(0xFFFF4D4D),
    meterTrack: Color(0xFF323942),
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
  /// Both families are bundled — see the `fonts:` section of the application's
  /// pubspec, which is where they have to be declared rather than in this
  /// package (the reason is written down there).
  ///
  /// Bundling is not a nicety for a metering tool. Falling through to the
  /// platform's own faces means the digit width, the tracking and the cap
  /// height all differ between macOS, Windows and Linux, and a layout tuned on
  /// one of them is subtly wrong on the other two — readouts that fit on the
  /// machine it was designed on and ellipsise elsewhere.
  ///
  /// The fallback lists below stay as insurance. They cost nothing and they
  /// keep the interface legible rather than blank if an asset ever fails to
  /// load.
  static const String uiFamily = 'Inter';
  static const String monoFamily = 'Google Sans Code';

  static const List<String> _uiFallback = [
    'SF Pro Text',
    'Segoe UI',
    'Roboto',
    'DejaVu Sans',
  ];

  /// The other bundled face heads the mono list, ahead of the platform's own.
  ///
  /// Google Sans Code carries 674 glyphs where JetBrains Mono carried 1,363,
  /// and one character the application can actually print is not among them:
  /// `∞` U+221E, which `Metric.format` returns for a reading that is not
  /// finite. Nothing the engine produces is — every dB quantity is floored at
  /// `BEL_DB_FLOOR` before it leaves C — so this is the defensive branch of a
  /// formatter rather than a number on screen today, and a wire packet or a
  /// hand-built report can still reach it. Leaving it to the host means a
  /// glyph from Menlo on macOS, from Consolas on Windows and a tofu box on a
  /// machine with neither. Inter has it, Inter ships in this repository, and a
  /// deterministic wrong-width glyph beats three different right-width ones.
  ///
  /// Everything else the interface prints in this face — digits, the em dash
  /// that marks an unmeasured quantity, `−`, `±`, `·`, `×`, the box-drawing
  /// runs — is in Google Sans Code at the same 0.6 em advance as every other
  /// glyph in it, so the width arithmetic the readouts do is untouched.
  static const List<String> _monoFallback = [
    uiFamily,
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
