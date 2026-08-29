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
/// own padding, so a `OaaButton` came out at 30, a `SegmentedControl` at 31.4
/// and a `OaaTextField` at 28.9 — a row of controls that had never once been
/// the same height as each other.
///
/// One number, applied by the four controls in `panel.dart`. Anything that
/// wants a different height is not one of these controls.
abstract final class OaaControl {
  /// The height of a button, menu, segmented control or field.
  static const double height = Space.xl;

  /// The gap inside one, from the border to the text.
  static const double padding = Space.smd;
}

/// Corner radii. Small, because measurement instruments are not soft.
abstract final class OaaRadius {
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
abstract final class OaaStroke {
  static const double hairline = 1;

  /// Meter scales, needles, graticule marks, and the rule between menu items —
  /// which is drawn on `panelRaised`, where a hairline has less of a step to
  /// stand on than it does anywhere else. See `oaaThemeData`.
  static const double mark = 1.5;

  /// Emphasis on a target line or an active selection.
  static const double emphasis = 2;

  /// A mark that has to be found *across* other ink, rather than read against
  /// the background.
  ///
  /// The super meter's target tick is the case this exists for: it is radial,
  /// so antialiasing spreads it across two pixel columns, and it crosses three
  /// arcs whose fill is the brightest thing on the module. At [emphasis] it
  /// read as an artefact of the arcs rather than as the one number the whole
  /// gauge is aimed at. Nothing that sits on the background needs this.
  static const double heavy = 3;
}

/// The colour palette.
///
/// Instances of this class are what a "skin" is. The default below is the
/// Precision Instrument palette; user skins deserialise into the same shape,
/// which is why every colour a module might need is named here rather than
/// derived at the call site.
@immutable
class OaaColors {
  const OaaColors({
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
  ///
  /// It carried a second job until the menus were reworked — the well a menu's
  /// current value sat in — and lost it for being too good at the first one.
  /// A menu is drawn on [panelRaised], two steps above this, so a row recessed
  /// all the way here read as a hole punched in the menu rather than as a row
  /// of it. The band is a wash of [hairlineStrong] now; see `OaaMenuRow`.
  final Color background;

  /// A module or panel surface.
  final Color panel;

  /// A surface that sits on top of a panel — a menu, a selected row, a chosen
  /// segment.
  ///
  /// A *menu's* selected row is the exception: the menu is already drawn on
  /// this, so there is no step up left in the surfaces and it takes a wash of
  /// [hairlineStrong] over this instead.
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
  /// Selection takes it at [OaaStroke.emphasis]; keyboard focus is a hairline
  /// in [textPrimary], so the two are told apart by weight and brightness
  /// rather than by hue.
  ///
  /// A menu's current row takes the same role as an *area* rather than as an
  /// edge — a quarter of the way from [panelRaised] to this — because a row is
  /// not a border and because the menu is already drawn on the highest surface
  /// the palette names. See `OaaMenuRow`.
  final Color hairlineStrong;

  /// Panel and menu text, and anything the eye should land on first.
  ///
  /// **Not a reading.** A module's numbers are [accent] or the colour of their
  /// verdict; this is the ink of the interface around them — a menu label, a panel's body text, a
  /// focus hairline, the report the panels print. A meter drawn in the same
  /// colour as the chrome it sits in is a meter you have to look for.
  final Color textPrimary;

  /// Labels and units — and the one reading that is neither, the Loudness
  /// Distribution's LRA. See [accent] for why that one is grey.
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

  /// A reading, and a reading in spec.
  ///
  /// **On the measurement surface this hue means exactly one thing: this is a
  /// measurement.** Every value the fourteen modules print takes it — with no
  /// target to judge it against, or with one it meets — and nothing else
  /// there may borrow it: not a selected module, not the active tab, not a
  /// highlighted menu row. A teal border meaning "selected" beside a teal
  /// number meaning "the signal" is a meter you have to stop and think about
  /// before you can read, which is the one thing a meter may never be. Chrome
  /// that needs to stand out uses [hairlineStrong] or [textPrimary].
  ///
  /// **One reading is the exception, and it is not a value standing on its
  /// own.** The Loudness Distribution prints LRA between the two marks of the
  /// dimension line that measures it, and in the signal hue that read as a
  /// separate label which happened to be collinear with them rather than as
  /// part of the annotation. It wears the caliper's [textMuted] instead. A
  /// reading with a picture of its own around it is the only shape that argues
  /// for this; a number on its own never is.
  ///
  /// What the palette spends its other colours on is therefore what is *wrong*
  /// with a reading rather than what is right: [warn] approaching a limit,
  /// [over] past it, [textMuted] for a quantity nobody measured. See
  /// `colorForState`, which is where the mapping lives.
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

  /// Over a limit — and the limit itself.
  ///
  /// The delivery target line and its printed value wear this colour on every
  /// module that draws against the target, because the line and the readings
  /// past it are one statement: this is the number, that is what stands over
  /// it. Two interaction states also borrow it and are listed here rather than
  /// left to be discovered: the destructive button emphasis, and the outline
  /// of a layout drop the grid will refuse. Both are refusals, both are
  /// momentary, and neither can be on screen at the same time as a reading it
  /// might be mistaken for — but the honest version of "used for nothing else,
  /// ever" is this list.
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

  /// A filled mark that carries no pass/fail meaning of its own and is not a
  /// level reading: the VU needle, the bars of the report card and the report
  /// panel. **The level meters do not use it.** The Digital Meter's and the
  /// LUFS meter's fills and the Super Meter's arcs are [meterAccent] since
  /// 0.15, because a fill in a grey a step above its grey track was a level
  /// you had to look for. [MeterFill] still takes this as its default so that
  /// a caller has to say which it wants.
  final Color meterFill;

  /// The level meters' ink: [accent] taken down to 70 % of its lightness.
  ///
  /// The three meters whose fill runs most of a module's height — the LUFS
  /// Meter, the Digital Meter and the Super Meter's rings — wear this rather
  /// than the accent itself. At full strength a bar the size of a module in
  /// the colour of a 12 px pass mark was a light rather than a level, and the
  /// readouts beside it that turned green vanished into it. Derived rather
  /// than a fourteenth skin role, so a skin that sets its accent gets meters
  /// to match without a second value to keep in step; `MeterFill` still lifts
  /// a fill's top edge towards the text colour and shades its foot darker
  /// still, so the reading stays the brightest thing in the bar and the floor
  /// the darkest.
  ///
  /// **Not for the frame path.** It converts through HSL and allocates; a
  /// painter takes it once, in its constructor, like every other colour it
  /// derives.
  Color get meterAccent => shade(accent, 0.7);

  /// The lit corner of a module: [panel] with [panelLift] added to its HSL
  /// lightness.
  ///
  /// Decibel's panels are lit from the top left — brightest in the corner,
  /// fading back to the panel's own colour four fifths of the way across and
  /// down — and `ModuleFrame` paints the same light, from this colour at the
  /// corner to [panel], under the title bar and the body alike. Derived rather
  /// than a fourteenth skin role, like [meterAccent], so a skin that sets its
  /// panel gets a corner lit to match without a second value to keep in step.
  /// On a light skin the sum clamps: a white panel is lit white, because there
  /// is nothing lighter to lift it to, and its modules are barely lit at all —
  /// which is what a highlight on white paper looks like.
  ///
  /// **Not for the frame path.** It converts through HSL and allocates; the
  /// frame takes it once, in `build`, like every other colour a painter
  /// derives.
  Color get panelLit => lift(panel, panelLift);

  /// How far [panelLit] stands above [panel], in HSL lightness.
  ///
  /// About half of what Decibel does. Measured off a screenshot, its corner
  /// sits 17 of 255 above a base of 22 on a graphite panel — six and a half
  /// points of lightness — and at that strength the same light on this palette
  /// read as a spotlight rather than as a lit surface, and swallowed the
  /// hairline border at the corner, where the fill reached the border's own
  /// colour. Nine levels keeps the corner a step under [hairline] on the
  /// default skin, so the border still closes the panel where the light is
  /// brightest. Added rather than multiplied — [shade] multiplies — because a
  /// factor that lifts a graphite panel by this much lifts a mid-grey one a
  /// long way towards white, and the light on a panel is a step above whatever
  /// it lights: the same step on every skin.
  static const double panelLift = 0.035;

  /// [color] at [factor] of its HSL lightness — the one recipe this design has
  /// for a darker shade of a colour it already owns. [meterAccent] is the
  /// accent through it at 0.7, and the LUFS Meter's bars darken towards their
  /// edges with that ink through it again — see `MeterFill.sideLightness`. Its
  /// *floor* is not a shade but [deepen]. Lightness rather than a
  /// blend towards [background], because a shade has to be *darker* on every
  /// skin, and the background of a light one is not. [lift] goes the other
  /// way, and adds rather than multiplies — see [panelLift] for why. Allocates;
  /// never on the frame path.
  static Color shade(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * factor).clamp(0.0, 1.0))
        .toColor();
  }

  /// [color] deepened: the same hue, HSV saturation up by a third and value
  /// down to 70 %. What the floor of a level meter is when its reading is
  /// [color] — see `MeterFill`.
  ///
  /// **Measured, then adapted.** Decibel's loudness bars run from their accent
  /// at the top to a floor colour that is not that accent shaded: sampled
  /// down one, `#5bbefd` (H 203°, S 0.64, V 0.99) becomes `#304dea` (H 231°,
  /// S 0.79, V 0.92) — a quarter more saturated, a little darker, and turned
  /// 28° towards blue. A shade — [shade] — takes a colour towards black, and
  /// a bar with a blackened foot reads as a bar in shadow; a deepened floor
  /// keeps the colour vivid and reads as the same paint, thicker. The turn is
  /// the one part not taken: it was, for an afternoon, and a teal that ran to
  /// blue at its floor read as a bar in two colours rather than one paint —
  /// on a blue the turn is a nuance, on any other hue it is a second hue. So
  /// the hue holds, and the value goes further down than measured to supply
  /// the darkness the turn towards blue, the darkest hue, was supplying in
  /// the reference. HSV rather than HSL because the measured saturation
  /// *rises* in HSV and falls in HSL; the space in which the number moves
  /// with the impression is the one to state it in. Allocates; never on the
  /// frame path.
  static Color deepen(Color color) {
    final hsv = HSVColor.fromColor(color);
    return hsv
        .withSaturation((hsv.saturation * 1.33).clamp(0.0, 1.0))
        .withValue((hsv.value * 0.7).clamp(0.0, 1.0))
        .toColor();
  }

  /// [color] with [amount] added to its HSL lightness, clamped — the one recipe
  /// this design has for a lighter tint of a colour it already owns, and the
  /// counterpart of [shade]. [panelLit] is the panel through it at
  /// [panelLift]. Allocates; never on the frame path.
  static Color lift(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// Whether this palette is dark ink on a light ground.
  ///
  /// Not derived from [background], because a palette is free to be low
  /// contrast and the guess would be wrong exactly where it matters. It decides
  /// the Material [ColorScheme]'s brightness, which is what the few stock
  /// widgets Open Audio Analyzer does use consult when they pick their own
  /// scrim and overlay colours — a light skin with a dark scheme gets dark menu
  /// shadows over pale panels and reads as a rendering fault.
  final bool isLight;

  /// Value equality, and it is load-bearing rather than tidy.
  ///
  /// Every module painter's `shouldRepaint` compares its palette. While the
  /// palette was a compile-time constant, identity was equality and the
  /// comparison was free. Skins end that: the palette is now built from a
  /// document, and without this a rebuild that produced an identical palette
  /// would re-rasterise all fourteen modules — and `OaaTheme.updateShouldNotify`
  /// would notify the whole tree on every skin *re-read*, not every skin
  /// change.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OaaColors &&
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

  /// Precision Instrument — graphite, one signal hue, lit from the top left.
  static const OaaColors precisionInstrument = OaaColors(
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
abstract final class OaaType {
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
  /// `OAA_DB_FLOOR` before it leaves C — so this is the defensive branch of a
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
