// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Loudness and dynamics on one half-gauge, meeting at the true peak.
///
/// Decibel's name, kept because there is no better one for this. The gauge is
/// a single dB scale from −∞ at the left end to 0 at the right, on two rings:
/// short-term outside, integrated inside — outward is more volatile, which is
/// what a glance should skip past.
///
/// **Loudness fills from the left; Open Dynamic Range continues from its
/// tip.** That is not a decoration, it is the arithmetic drawn: ODR is true
/// peak minus loudness, so a dynamics arc stacked on the loudness tip ends at
/// exactly the true peak's position on the same scale, and the dark remainder
/// of the ring is the headroom to full scale, closing as the limiter works. A
/// dynamics arc reaching the right end is a peak at 0 dBTP; past it is over.
///
/// The outer ring's two tips carry their names, set along the arc outside it
/// the way a gauge face is engraved: LUFS-S rides the loudness tip, ODR-S the
/// dynamics tip. **Nothing else is printed on the rings.** They are read
/// against the two marks and the centre. Two other schemes have been tried
/// here and taken out, and neither should come back: every tip's own number
/// in the lane beside its ring — six small figures moving about a dial whose
/// centre already carried what matters — read as crowded, and the short-term
/// pair cut *into* its arcs read worse, because an upright figure held to a
/// bar that runs vertical at both ends of the dial is clipped to a sliver
/// exactly when the programme is loud or quiet enough to put a tip there.
/// **The dynamics tip carries no mark of its own either.** It ended in a muted
/// radial tick, and that was one mark too many: where the arc stops already
/// says where the peak stands, and a bar drawn across it put a third mark on a
/// dial whose other two — the target and the ceiling — are values somebody
/// set.
///
/// The right end carries the delivery ceiling as a red zone, the way the VU
/// meter's face carries its red sector: the region past the calibration's
/// true-peak ceiling is tinted on both rings, and the ceiling's value is
/// printed on its own radial tick. The target gets the same treatment on the
/// loudness side — a radial tick with the target value beside it, in
/// [OaaColors.over], the application's one colour for "the number you set".
///
/// The centre carries five readings in three rows: LUFS-S and ODR-S as a
/// small neutral row on top, LUFS-I and ODR-I under them, and TRUE PEAK
/// below. **Every one of the five prints its unit**, the way a Number Box
/// does: beside the value, on its baseline, in the unit face. Each label is
/// the reading's full name; the INTEGRATED heading went when the stack
/// stopped being all integrated. Only the delivered numbers — the integrated
/// pair and the peak — can turn warn or over; the short-term row is a
/// reading passing through and stays in the plain accent, the way the LUFS
/// meter's momentary and short-term readouts do — see [colorForState]: a
/// value wears the accent, and the palette's other colours say what is
/// wrong with one. A module too small for three rows drops the
/// short-term one and keeps the two that are delivered. **The three sections
/// stand apart on whatever the fitting leaves them**: the stack's size is
/// almost always decided by the chord a row has to cross rather than by the
/// height it has, so the five readings used to sit packed at the minimum gap
/// with the lower part of the dial's clear disc empty beneath them. The
/// surplus is divided between the two gaps instead — after the fitting, so
/// the figures are the size they always were. The loudness range
/// still has a module of its own. Every value is
/// taken raw from the measurement, never from the eased arc positions: easing
/// decides where a shape is drawn, not what the instrument says. The arcs are
/// [OaaColors.meterAccent], the reading's colour on every bar meter, and
/// shaded darker towards the silent end the way every bar meter's foot is —
/// [MeterFill]'s recipe, swept around a ring. **A verdict is worn only in
/// the centre.** The loudness arcs keep their ink past the target
/// tick: for a release the part of an arc that stood past the tick was redrawn
/// in [OaaColors.over], and a ring that turns red at its tip is a warning laid
/// over a level, on a gauge whose centre already prints the verdict. The tick
/// alone says where the target is, and how far past it the arc reaches is the
/// miss.
class SuperMeterModule extends StatefulWidget {
  const SuperMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<SuperMeterModule> createState() => _SuperMeterModuleState();
}

class _SuperMeterModuleState extends State<SuperMeterModule> {
  /// The tapered level scale, shared with every other level meter. No
  /// graticule is drawn on the rings — the gauge is read against its ticks'
  /// two printed ends and the marks on it — but every angle comes from this
  /// mapping, so the gauge and the bar meters agree about where −12 is.
  static const _scale = MeterScale.tapered(
    max: 0,
    ticks: [0, -3, -6, -9, -12, -18, -24, -30, -40],
  );

  /// The dynamics family's ink: the meters' accent lifted towards the text
  /// colour, so the arc that continues a loudness arc is visibly the same
  /// instrument's second voice and visibly not its first. One recipe, used by
  /// the name in [build] and the arcs in the painter — and, like
  /// [OaaColors.meterAccent] itself, taken once per palette, never in `paint`.
  static Color dynInkOf(OaaColors colors) =>
      Color.lerp(colors.meterAccent, colors.textPrimary, 0.55)!;

  /// Seconds for an arc to cover 63% of the distance to a new reading.
  ///
  /// The quantities behind the arcs advance on the engine's gating grid and
  /// nowhere else: a short-term reading is a 3 s window that slides in 100 ms
  /// steps, so it changes ten times a second however often it is read. The
  /// clock repaints at the engine's publish rate, about 47 Hz, so four frames
  /// in five drew the arc exactly where the frame before had left it and the
  /// fifth jumped. A bar a few pixels tall gets away with that; a half-gauge
  /// across the whole module does not, and it reads as an instrument
  /// stuttering rather than as a signal moving.
  ///
  /// **Arcs only.** Every number this module prints, and every colour it
  /// decides from one, is the measurement — drawn the frame it arrives. What
  /// is eased is where a shape is drawn to, which is what the analyser's
  /// response setting already does to its curve.
  static const double _tau = 0.05;

  /// Seconds for an arc that has just come into existence to cover 63% of the
  /// way in from the silent end. Three times [_tau], because this is a
  /// different motion: not a reading moving, but a meter coming up.
  ///
  /// LUFS-S does not exist until three seconds of programme have passed, and
  /// ODR-S not until LUFS-S does; after a reset, or at the start of a song,
  /// both appear at once. An arc that popped into the middle of the dial at
  /// that moment read as a glitch rather than as a measurement arriving, so a
  /// reading that has just become defined starts from the dial's silent end
  /// and sweeps to its value over about half a second — the one moment where
  /// a shape on this module is not the measurement, and a deliberate one. The
  /// number in the centre is the measurement from the first frame.
  static const double _arriveTau = 0.15;

  /// How close, in dB or LU, an arriving arc comes to its reading before it is
  /// following rather than arriving — and switches to [_tau].
  static const double _arrived = 0.1;

  /// The level each arc is drawn at: [0] short-term LUFS, [1] integrated
  /// LUFS, [2] ODR-S, [3] ODR-I. NaN until that reading has a value, which is
  /// not a level of zero and is drawn as no arc at all.
  final List<double> _shown = List<double>.filled(4, double.nan);

  /// Which arcs are still on their way in from the silent end. See [_fold].
  final List<bool> _arriving = List<bool>.filled(4, false);

  /// The published measurement [_shown] was last folded for, and the engine
  /// time it was folded at.
  ///
  /// **Zero is a real generation to have never seen**, so this starts at -1: a
  /// source that published exactly once and then stopped must still get that
  /// one measurement folded in.
  int _seenGeneration = -1;
  double _seenElapsed = 0;

  /// Folds one published measurement into [_shown].
  ///
  /// **Called on a change of generation, never on a paint.** Paint also runs
  /// on a resize, a skin change and a selection, and an ease that advanced on
  /// those would travel while no audio did — the same defect as a spectrogram
  /// that scrolls when the window is dragged, and just as convincing.
  ///
  /// The coefficient is derived from *engine* time rather than counted in
  /// frames, so the arcs move at the same speed whether the meters are
  /// refreshing at 30, 60 or 120.
  void _advance(MeterSource engine) {
    final elapsed = engine.elapsedSeconds;
    final dt = elapsed - _seenElapsed;
    _seenElapsed = elapsed;

    // A reset takes the clock back to zero, and a first measurement has no
    // interval to derive a coefficient from: an arc that already exists snaps
    // on those frames rather than easing over an interval nobody measured.
    // `!(dt > 0)` rather than `dt <= 0`, so that a NaN takes this branch too:
    // a source whose link has gone quiet reports NaN seconds, and NaN compares
    // false against everything — an alpha computed from one is NaN, and a
    // single NaN folded into an arc's position stays there for the rest of the
    // session. An arc that does *not* yet exist takes neither coefficient on
    // the frame it appears; see [_fold].
    final snap = !(dt > 0) || _seenGeneration < 0;
    final alpha = snap ? 1.0 : 1 - math.exp(-dt / _tau);
    final arrival = snap ? 1.0 : 1 - math.exp(-dt / _arriveTau);

    _fold(0, engine.lufsShort, alpha, arrival);
    _fold(1, engine.lufsIntegrated, alpha, arrival);
    _fold(2, engine.odrShort, alpha, arrival);
    _fold(3, engine.odrIntegrated, alpha, arrival);
  }

  /// One arc. A reading that is not yet defined leaves the arc undrawn rather
  /// than easing towards a number nobody measured. A reading that has just
  /// become defined puts its arc at the silent end on this frame and lets the
  /// following frames sweep it in on [arrival] — the loudness arcs from the
  /// dial's floor, the dynamics arcs from a length of nothing, so they grow
  /// out of the loudness tip they sit on. See [_arriveTau] for why.
  void _fold(int i, double value, double alpha, double arrival) {
    final shown = _shown[i];
    if (value.isNaN) {
      _shown[i] = double.nan;
      _arriving[i] = false;
      return;
    }
    if (shown.isNaN) {
      _shown[i] = i < 2 ? MeterShape.dbFloor : 0.0;
      _arriving[i] = true;
      return;
    }
    final next = shown + (value - shown) * (_arriving[i] ? arrival : alpha);
    if (_arriving[i] && (value - next).abs() < _arrived) _arriving[i] = false;
    _shown[i] = next;
  }

  /// The wedge an arc has swept, rebuilt every frame.
  ///
  /// Deliberately **not** cached: it moves with the reading, so there is
  /// nothing to cache. It is reset and refilled rather than reallocated,
  /// because the frame path may not allocate — four arcs at the refresh rate
  /// is a `Path` two hundred times a second otherwise.
  final Path _swept = Path();

  /// The sector from [from] round to [to], apex at the centre.
  Path _sweptTo(Offset centre, double radius, double from, double to) {
    _swept.reset();
    _swept.moveTo(centre.dx, centre.dy);
    _swept.arcTo(
      Rect.fromCircle(center: centre, radius: radius),
      from,
      to - from,
      false,
    );
    _swept.close();
    return _swept;
  }

  final _lufs = ValueParagraph();
  final _odr = ValueParagraph();
  final _truePeak = ValueParagraph();
  final _target = ValueParagraph();
  final _ceiling = ValueParagraph();
  final _lufsShort = ValueParagraph();
  final _odrShort = ValueParagraph();
  ui.Paragraph? _lufsShortLabel;
  ui.Paragraph? _odrShortLabel;
  ui.Paragraph? _lufsLabel;
  ui.Paragraph? _odrLabel;
  ui.Paragraph? _truePeakLabel;
  ui.Paragraph? _lufsUnit;
  ui.Paragraph? _odrUnit;
  ui.Paragraph? _lufsShortUnit;
  ui.Paragraph? _odrShortUnit;
  ui.Paragraph? _truePeakUnit;
  ui.Paragraph? _nameLoud;
  ui.Paragraph? _nameDyn;
  OaaColors? _colorsKey;

  @override
  void dispose() {
    _lufs.dispose();
    _odr.dispose();
    _truePeak.dispose();
    _target.dispose();
    _ceiling.dispose();
    _lufsShort.dispose();
    _odrShort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_colorsKey != colors) {
      _colorsKey = colors;
      final style = OaaType.label.copyWith(color: colors.textFaint);
      // Each label is the reading's full name — LUFS-S, ODR-I — because the
      // stack carries no INTEGRATED heading any more: with two pairs in it,
      // a heading naming one block would leave the other's rows implied.
      _lufsShortLabel = layoutParagraph('LUFS-S', style);
      _odrShortLabel = layoutParagraph('ODR-S', style);
      _lufsLabel = layoutParagraph('LUFS-I', style);
      _odrLabel = layoutParagraph('ODR-I', style);
      // Not "TRUE PEAK MAX": the rows above it already read integrated, and
      // the number is the ceiling zone's own.
      _truePeakLabel = layoutParagraph('TRUE PEAK', style);
      // Each reading's unit, the way a Number Box prints one: beside the
      // value, on its baseline, in the unit face. The labels above name the
      // *columns*, and "LUFS-I" over "−12.8 LUFS" is the same repetition a
      // Number Box makes with its title — a distance in LU under a label
      // that reads ODR-I is not one somebody should have to infer.
      //
      // **Each of the five asks its own metric**, rather than the short-term
      // pair borrowing the integrated pair's paragraphs. The four strings are
      // identical today — `lufsShort` and `lufsIntegrated` are both LUFS,
      // `odrShort` and `odrIntegrated` both LU — and sharing on that would be
      // a module printing one metric's unit after another metric's number,
      // silently, the day the two stop agreeing. Four paragraphs laid out
      // once per palette is not a cost worth that.
      final unitStyle = OaaType.unit.copyWith(color: colors.textMuted);
      _lufsUnit = layoutParagraph(Metric.lufsIntegrated.unit, unitStyle);
      _odrUnit = layoutParagraph(Metric.odrIntegrated.unit, unitStyle);
      _lufsShortUnit = layoutParagraph(Metric.lufsShort.unit, unitStyle);
      _odrShortUnit = layoutParagraph(Metric.odrShort.unit, unitStyle);
      _truePeakUnit = layoutParagraph(Metric.truePeakMax.unit, unitStyle);
      // The tip names, each in its family's ink rather than the label grey:
      // they ride moving tips, and a name the same colour as its arc is what
      // says which tip it is naming without a legend.
      _nameLoud = layoutParagraph(
        'LUFS-S',
        OaaType.label.copyWith(color: colors.meterAccent),
      );
      _nameDyn = layoutParagraph(
        'ODR-S',
        OaaType.label.copyWith(color: dynInkOf(colors)),
      );
    }

    return MeterBody(
      painter: _SuperMeterPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        scale: _scale,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _SuperMeterPainter extends MeterPainter {
  _SuperMeterPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.scale,
    required this.state,
    required Listenable repaint,
  }) : // **Every end is square** — the gauge's two ends at the diameter, and
       // the readings' moving tips. The ends were round through one release
       // and went back: a half-gauge whose feet are rounded reads as a horse-
       // shoe rather than as a scale cut at its two extremes, and the LUFS
       // meter beside it has square feet.
       //
       // The fills are still **cut back to the reading** by
       // [_SuperMeterModuleState._sweptTo] rather than trusting the stroke's
       // own end, and the clips still open a little past each fixed end: an
       // arc that ends exactly on the clip's edge loses the antialiased half
       // pixel of its cap to it, and a fixed end that sits a hair inside the
       // track's reads as a dark seam.
       _track = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _arc = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       // The dynamics arcs, at half the ring's width — see [_dynWidth].
       _dynArc = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       // The reading's colour, as on every bar meter: [OaaColors.meterAccent]
       // at full strength on the integrated ring and at 0.55 on the
       // short-term one, so the ring a glance should skip past recedes.
       // Derived from the accent and never from a text colour, which sits
       // lighter than the fill under the dark palette and darker under a
       // light one — the two rings would swap which looked emphasised when
       // the skin changed. Built here rather than in `paint`, which is on the
       // frame path and allocates nothing.
       _ink = colors.meterAccent,
       _shortFill = colors.meterAccent.withValues(alpha: 0.55),
       // The dynamics arcs are the same instrument's second voice, told apart
       // by *weight* — half the ring's width, see [_dynWidth] — and by the
       // lighter ink of [_SuperMeterModuleState.dynInkOf]. Most of their
       // ring's strength, because at the 0.42 and 0.28 they were first drawn
       // at they vanished into the track.
       _dynFill = _SuperMeterModuleState.dynInkOf(
         colors,
       ).withValues(alpha: 0.90),
       _dynFillShort = _SuperMeterModuleState.dynInkOf(
         colors,
       ).withValues(alpha: 0.55),
       // [MeterFill]'s ramp, around a ring: the floor colour —
       // [OaaColors.deepen] of the ink — swept from the silent end and fading
       // into the ink by `1 − MeterFill.plateau` of the dial, so a full arc
       // wears the bar meters' gradient exactly and a shorter one starts at
       // the same floor. A sweep cannot be stretched to an arc the way the
       // bars' shader is stretched to a fill, so the ramp is anchored to the
       // silent end rather than proportional; the tip of a short arc is a
       // touch deeper than a bar's would be. The short-term ring's is scaled
       // by its 0.55 so the two rings keep their weights along the whole of
       // their length. The colours are taken here; the sweeps themselves want
       // the centre and are built in `paint`, once per layout — see
       // `_footCentre`.
       _footArc = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _footArcShort = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _footColors = [
         OaaColors.deepen(colors.meterAccent),
         OaaColors.deepen(colors.meterAccent).withValues(alpha: 0),
       ],
       _footColorsShort = [
         OaaColors.deepen(colors.meterAccent).withValues(alpha: 0.55),
         OaaColors.deepen(colors.meterAccent).withValues(alpha: 0),
       ],
       // The ceiling zone: the stretch of track past the calibration's
       // true-peak ceiling, on both rings — the same statement as the VU
       // face's red sector, in the same colour at the same reticence.
       _ceilingZone = (Paint()
         ..color = colors.over.withValues(alpha: 0.30)
         ..style = PaintingStyle.stroke),
       // [OaaStroke.heavy] where every other target mark in the application
       // takes [OaaStroke.mark], because this one is *radial* and the others
       // are axis-aligned. A horizontal target line at 1.5 px is drawn with
       // antialiasing off and lands on whole pixels at full strength; an
       // angled stroke cannot be, and antialiasing spreads the same 1.5 px
       // across two pixel columns at about half the alpha each.
       //
       // [OaaColors.over], like every target mark: the tick is the number the
       // whole gauge is aimed at, and the one red thing on the loudness side
       // of the dial — the arc standing past it keeps its own ink.
       _target = (Paint()
         ..color = colors.over
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.heavy),
       // The tick's backdrop, drawn first and at the tick's own width — so the
       // tick covers it exactly and none of it reaches the screen.
       //
       // That width is the decision, not an oversight. Standing the slot out
       // either side of the tick cuts a visible notch across every arc at the
       // target, and that change has been made and reverted three times.
       // **Do not make it again without asking.** What it was for: one tick
       // sits on two different backdrops — the empty track and the ring's own
       // fill — so the same mark reads at two contrasts. That is a real
       // effect, and it was judged not worth cutting the arcs to fix.
       _targetSlot = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.heavy),
       _overTickStyle = OaaType.tick.copyWith(color: colors.over),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final MeterScale scale;
  final _SuperMeterModuleState state;

  final Paint _track;
  final Paint _arc;
  final Paint _dynArc;
  final Paint _footArc;
  final Paint _footArcShort;
  final Paint _ceilingZone;
  final Paint _target;
  final Paint _targetSlot;
  final Color _ink;
  final Color _shortFill;
  final Color _dynFill;
  final Color _dynFillShort;
  final List<Color> _footColors;
  final List<Color> _footColorsShort;
  final TextStyle _overTickStyle;

  /// The centre and outer radius the sweeps were built for. A sweep gradient
  /// is anchored to a point, so it cannot be stretched under an arc the way
  /// [MeterFill] stretches its linear one under a fill — they are rebuilt
  /// when the layout moves, which is a resize and never a frame.
  Offset? _footCentre;
  double _footOuter = 0;

  /// A half-gauge over the top: −π at the left end, 0 at the right, in screen
  /// angles (y down). The scale's fraction maps straight onto it.
  static const double _startAngle = -math.pi;
  static const double _sweepAngle = math.pi;

  /// The width of one ring, as a fraction of the outer radius.
  static const double _ringWidth = 0.115;

  /// The width of a dynamics arc, as a fraction of the ring's. Narrower than
  /// the loudness arc it continues from, on the same centre line: a thinner
  /// stroke picking up where a thicker one stopped reads as a second quantity
  /// measured along the same scale, which is what it is.
  static const double _dynWidth = 0.5;

  /// The lane between the rings, as a fraction of a ring's width. A
  /// separation and nothing more, since nothing is printed into it.
  static const double _laneWidth = 0.6;

  /// Advance of one glyph of [OaaType.reading], in ems. Google Sans Code is
  /// 0.6 and the style tightens it by half a pixel; the slack is what keeps
  /// this an upper bound rather than a measurement.
  static const double _glyphAdvance = 0.62;

  /// The height of a line of [OaaType.reading], in ems.
  static const double _lineHeight = 1.2;

  /// The true peak's size against the two readings above it. Smaller, because
  /// the peak is where the dynamics arc already ends; still a reading.
  static const double _peakScale = 0.6;

  /// The short-term row's size against the integrated pair under it — the
  /// same step down as [_peakScale] on the other side, so the two rows
  /// around the delivered pair recede equally and the eye lands between
  /// them.
  static const double _shortScale = 0.6;

  /// The smallest reading face the centre will set, in pixels. Under it a
  /// figure is chrome rather than a number; the stack drops its short-term
  /// row first to stay above it, and holds here rather than shrink further.
  static const double _minReading = 11;

  /// Between the centre's three sections — the short-term pair, the
  /// integrated pair, the true peak. The floor, and what the fitting reserves.
  ///
  /// [Space.sm] and not the [Space.xs] it was: a section here is a label over
  /// a value already separated by [Space.xxs], so at four pixels the gap
  /// *between* sections was barely wider than the gap inside one and the five
  /// readings ran together as a single block of digits. The stack pays for it
  /// in face size — the fitting below spends whatever is left after the gaps —
  /// which is the right way round: three groups that read as three are worth
  /// more than a point of height on each.
  static const double _sectionGap = Space.sm;

  /// What a section gap opens to once the stack has been fitted.
  ///
  /// The fit is nearly always bound by the chord a row must cross rather than
  /// by the height it has, so the five readings stood packed at the floor gap
  /// in the upper part of the clear disc with the rest of it empty beneath
  /// them. Whatever the fit leaves over is divided between the gaps up to
  /// here, which is why it is spent *after* the fitting and not inside it:
  /// giving the height budget a larger gap to reserve would have bought the
  /// same separation by shrinking the figures, and the room was already
  /// there.
  static const double _sectionGapMax = Space.lg;

  double _angleOf(double fraction) => _startAngle + fraction * _sweepAngle;

  @override
  void paint(Canvas canvas, Size size) {
    if (engine.generation != state._seenGeneration) {
      state._advance(engine);
      state._seenGeneration = engine.generation;
    }

    // **The gauge is a half-disc and must not be centred as a circle.** Its
    // ink stops at the diameter, plus the tip names riding outside the outer
    // ring — solve for the radius that fills the box less that margin, then
    // centre what is actually drawn.
    final nameBand = OaaType.label.fontSize! * 1.2 + Space.xxs;
    final outer = math.min(size.width / 2 - nameBand, size.height - nameBand);
    if (outer < 40) return;

    final ring = outer * _ringWidth;
    final gap = ring * _laneWidth;
    final inkHeight = nameBand + outer;
    final centre = Offset(
      size.width / 2,
      (size.height - inkHeight) / 2 + nameBand + outer,
    );

    _track.strokeWidth = ring;
    _arc.strokeWidth = ring;
    _dynArc.strokeWidth = ring * _dynWidth;
    _footArc.strokeWidth = ring;
    _footArcShort.strokeWidth = ring;
    _ceilingZone.strokeWidth = ring;

    // The sweeps. Skia wants a sweep's angles in [0, 2π], so the silent end
    // is π here where the arcs themselves are drawn from −π: the same point
    // on the dial. The floor colour runs clockwise from there over the top
    // and is gone where the bars' plateau would begin.
    if (_footCentre != centre || _footOuter != outer) {
      _footCentre = centre;
      _footOuter = outer;
      final from = math.pi;
      final to = math.pi * (2 - MeterFill.plateau);
      _footArc.shader = ui.Gradient.sweep(
        centre,
        _footColors,
        null,
        TileMode.clamp,
        from,
        to,
      );
      _footArcShort.shader = ui.Gradient.sweep(
        centre,
        _footColorsShort,
        null,
        TileMode.clamp,
        from,
        to,
      );
    }

    // The target and the ceiling, as angles. Wanted by both rings — the ticks
    // are drawn on each and the ceiling zone tints each — so neither is
    // recomputed inside the loop.
    final targetFraction = scale.fractionOf(calibration.lufsTarget);
    final targetAngle = _angleOf(targetFraction);
    final ceilingFraction = scale.fractionOf(calibration.truePeakMax);

    // The integrated readings and their colours, for the centre — taken
    // **raw**, from the measurement rather than from the eased arc positions:
    // a pass or fail is a fact about a number somebody delivered, and easing
    // decides where a shape is drawn, never what it says. The arcs themselves
    // wear no verdict: an inner ring painted red below the target as well as
    // past it would erase the one thing the cut at the target exists to show,
    // which is the size of the miss.
    final integrated = engine.lufsIntegrated;
    final integratedColor = colorForState(
      classify(Metric.lufsIntegrated, integrated, calibration),
      colors,
    );
    final odrIntegrated = engine.odrIntegrated;
    final odrIntegratedColor = colorForState(
      classify(Metric.odrIntegrated, odrIntegrated, calibration),
      colors,
    );

    final innerClear = outer - 2 * ring - gap;

    // The target's and the ceiling's numbers stand inside this circle, just
    // inside the inner ring — see [_tipValue] for how a number near the
    // diameter is kept from running under the ring.
    final markLimit = innerClear - Space.xxs;

    // --- The centre's stack, sized before anything is drawn ------------------
    // Five readings in three rows — the short-term pair, the integrated pair,
    // the true peak — fitted here rather than where they are painted, because
    // the marks' numbers below yield to the top of the stack, and the top is
    // a row whose width follows the fitted size. Every glyph in a reading is
    // a digit, a minus or a point, and the reading face is monospaced, so
    // every width is arithmetic and not a measurement — no second layout to
    // find out whether the first fitted.
    final truePeakMax = engine.truePeakMax;
    final lufsText = Metric.lufsIntegrated.format(integrated);
    final odrText = Metric.odrIntegrated.format(odrIntegrated);
    final lufsShortText = Metric.lufsShort.format(engine.lufsShort);
    final odrShortText = Metric.odrShort.format(engine.odrShort);
    final lufsLabel = state._lufsLabel!;
    final odrLabel = state._odrLabel!;
    final lufsShortLabel = state._lufsShortLabel!;
    final odrShortLabel = state._odrShortLabel!;
    final lufsUnit = state._lufsUnit!;
    final odrUnit = state._odrUnit!;
    final lufsShortUnit = state._lufsShortUnit!;
    final odrShortUnit = state._odrShortUnit!;
    final glyphs = math.max(5, math.max(lufsText.length, odrText.length));
    final glyphsShort = math.max(
      5,
      math.max(lufsShortText.length, odrShortText.length),
    );

    // The stack's top: most of the way up the clear disc, pulled down on a
    // small module until the short-term labels — the one row whose width is
    // fixed — sit inside the chord there rather than under the inner ring,
    // and never below halfway, where nothing fits anyway.
    final shortLabelsWidth =
        lufsShortLabel.longestLine + Space.md + odrShortLabel.longestLine;
    final labelsHalf = shortLabelsWidth / 2 + Space.xs;
    final riseCap = labelsHalf < innerClear
        ? math.sqrt(innerClear * innerClear - labelsHalf * labelsHalf)
        : 0.0;
    final stackRise = math.max(
      innerClear * 0.5,
      math.min(innerClear * 0.78, riseCap),
    );
    final stackTop = centre.dy - stackRise;
    final labelHeight = lufsLabel.height;

    // Fitted twice, like the single pair before it: to the chord over each
    // values row — taken at the highest position the row can occupy, which
    // is the narrowest chord it can meet — and to the height between the
    // stack's top and the diameter. The units are a fixed face and take
    // their width off the chord before the digits are sized.
    final shortValuesTop = stackTop + labelHeight + Space.xxs;
    final riseShortRow = centre.dy - shortValuesTop;
    final chordShort = riseShortRow < innerClear
        ? 2 * math.sqrt(innerClear * innerClear - riseShortRow * riseShortRow)
        : 0.0;
    final intValuesTop = shortValuesTop + _sectionGap + labelHeight + Space.xxs;
    final riseIntRow = centre.dy - intValuesTop;
    final chordInt = riseIntRow < innerClear
        ? 2 * math.sqrt(innerClear * innerClear - riseIntRow * riseIntRow)
        : 0.0;
    // Each row's units come off its own chord before that row's digits are
    // sized: a unit is a fixed face and does not shrink with the figure it
    // follows, so on the short-term row — whose digits are [_shortScale] of
    // the pair below — it takes proportionally more of the width.
    final unitsWidth =
        lufsUnit.longestLine + odrUnit.longestLine + 2 * Space.xs;
    final shortUnitsWidth =
        lufsShortUnit.longestLine + odrShortUnit.longestLine + 2 * Space.xs;
    final byWidthShort =
        (chordShort - Space.md - 2 * Space.sm - shortUnitsWidth) /
        (2 * glyphsShort * _glyphAdvance * _shortScale);
    final byWidth =
        (chordInt - Space.md - 2 * Space.sm - unitsWidth) /
        (2 * glyphs * _glyphAdvance);
    final byHeight =
        (stackRise -
            2 * (labelHeight + Space.xxs) -
            2 * _sectionGap -
            Space.sm) /
        (_lineHeight * (_shortScale + 1 + _peakScale));
    final fitAll = math.min(
      outer * 0.2,
      math.min(byWidthShort, math.min(byWidth, byHeight)),
    );

    // A module too small for three rows keeps two: the short-term row is
    // the one that goes, because it is the reading passing through, and the
    // integrated pair then stands where the top row stood. Refitted without
    // it, since the chord and the height both change — the same judgement
    // the LUFS meter makes about its readout floor, one row at a time.
    final showShort = fitAll >= _minReading;
    final riseIntAlone = centre.dy - (stackTop + labelHeight + Space.xxs);
    final chordIntAlone = riseIntAlone < innerClear
        ? 2 * math.sqrt(innerClear * innerClear - riseIntAlone * riseIntAlone)
        : 0.0;
    final fitThree = math.min(
      outer * 0.2,
      math.min(
        (chordIntAlone - Space.md - 2 * Space.sm - unitsWidth) /
            (2 * glyphs * _glyphAdvance),
        (stackRise - labelHeight - Space.xxs - _sectionGap - Space.sm) /
            (_lineHeight * (1 + _peakScale)),
      ),
    );
    final fontSize = (showShort ? fitAll : fitThree)
        .clamp(_minReading, 96.0)
        .toDouble();

    // The short-term row, laid out now because the marks' numbers yield to
    // the rect it covers. In the plain accent and judged by nothing, the way
    // the LUFS meter's momentary and short-term readouts are — see
    // `colorForState`: a value wears the accent, and warn and over are worn
    // by what gets delivered. Each one asks [inkForReading] rather than taking
    // the accent for the pair, because either can be an em dash on its own:
    // the dynamics reading needs a peak as well as a level and arrives
    // second. Each label and its value share a column as wide as the wider of
    // the two — a label is a fixed face, and centred over a small value the
    // two names ran into each other.
    final shortSize = OaaType.reading(fontSize * _shortScale);
    final lufsShortValue = state._lufsShort.of(
      lufsShortText,
      shortSize.copyWith(color: inkForReading(engine.lufsShort, colors)),
    );
    final odrShortValue = state._odrShort.of(
      odrShortText,
      shortSize.copyWith(color: inkForReading(engine.odrShort, colors)),
    );
    // A value and its unit are one group here too, centred under a label
    // that at this size is often wider than both together.
    final lufsShortPair =
        lufsShortValue.longestLine + Space.xs + lufsShortUnit.longestLine;
    final odrShortPair =
        odrShortValue.longestLine + Space.xs + odrShortUnit.longestLine;
    final lufsShortGroup = math.max(lufsShortPair, lufsShortLabel.longestLine);
    final odrShortGroup = math.max(odrShortPair, odrShortLabel.longestLine);
    final shortRowWidth = lufsShortGroup + Space.md + odrShortGroup;

    // The integrated pair. A value and its unit are one group, centred as
    // one under its label.
    final lufsValue = state._lufs.of(
      lufsText,
      OaaType.reading(fontSize).copyWith(color: integratedColor),
    );
    final odrValue = state._odr.of(
      odrText,
      OaaType.reading(fontSize).copyWith(color: odrIntegratedColor),
    );
    final lufsGroup = lufsValue.longestLine + Space.xs + lufsUnit.longestLine;
    final odrGroup = odrValue.longestLine + Space.xs + odrUnit.longestLine;
    final rowWidth = lufsGroup + Space.md + odrGroup;

    // TRUE PEAK, the number the ceiling zone is about — red exactly when it
    // stands in that zone — at [_peakScale] of the two above it. Laid out here
    // rather than where it is drawn because the gaps are divided from what the
    // stack actually measures, and it is the last thing in it.
    final truePeakValue = state._truePeak.of(
      Metric.truePeakMax.format(truePeakMax),
      OaaType.reading(fontSize * _peakScale).copyWith(
        color: colorForState(
          classify(Metric.truePeakMax, truePeakMax, calibration),
          colors,
        ),
      ),
    );

    // The gap the three sections actually stand apart at: the floor, opened by
    // an equal share of whatever the fit left between the stack's ink and the
    // diameter, up to [_sectionGapMax]. The face is already decided, so this
    // spends room that would otherwise have gone nowhere.
    final stackInk =
        labelHeight +
        Space.xxs +
        lufsValue.height +
        truePeakValue.height +
        (showShort ? labelHeight + Space.xxs + lufsShortValue.height : 0);
    final sectionGap = ((stackRise - Space.sm - stackInk) / (showShort ? 2 : 1))
        .clamp(_sectionGap, _sectionGapMax);

    // The whole stack, for the marks' numbers to yield to.
    //
    // **The whole of it, not the top row.** It covered the top row alone while
    // the sections stood at the floor gap, which left the true peak row two
    // thirds of the way up the disc with nothing near it; now that the stack
    // spends the room below, that row ends a hair above the diameter — which
    // is exactly where the ceiling's own number stands, since a ceiling is
    // always within a decibel or two of full scale. A number a user set,
    // printed against the reading it judges, is the one thing this dial has
    // never allowed.
    final peakRowWidth =
        state._truePeakLabel!.longestLine +
        Space.xs +
        truePeakValue.longestLine +
        Space.xs +
        state._truePeakUnit!.longestLine;
    final readoutWidth = math.max(
      peakRowWidth,
      showShort ? math.max(shortRowWidth, rowWidth) : rowWidth,
    );
    final readoutRect = Rect.fromLTWH(
      centre.dx - readoutWidth / 2,
      stackTop,
      readoutWidth,
      stackInk + sectionGap * (showShort ? 2 : 1),
    );

    // --- The target's and the ceiling's own numbers --------------------------
    // Each on its tick's radial, in the mark's own colour, inside the rings.
    // Drawn before the rings only in code — nothing else reaches the clear
    // disc — and either yields to the heading, and the second to the first,
    // rather than overprint a number already standing.
    if (innerClear > 56) {
      final targetRect = _tipValue(
        canvas,
        centre,
        state._target.of(
          calibration.lufsTarget.toStringAsFixed(1),
          _overTickStyle,
        ),
        targetAngle,
        markLimit,
        readoutRect,
      );
      _tipValue(
        canvas,
        centre,
        state._ceiling.of(
          calibration.truePeakMax.toStringAsFixed(1),
          _overTickStyle,
        ),
        _angleOf(ceilingFraction),
        markLimit,
        readoutRect,
        targetRect,
      );
    }

    // Where the outer ring's tip names ride, resolved inside the ring loop.
    // With nothing to ride, both rest at the silent end, which is where both
    // tips are.
    //
    // **The dynamics name parked at the dial's right end until now**, because
    // its default was the end of the sweep — so before a note was played
    // ODR-S sat at full scale, which on a gauge face is a tip standing at the
    // ceiling. It is the one thing a meter must never claim for a quantity
    // nobody has measured, and it moved the whole width of the dial on the
    // first frame of audio. The dynamics arc is *stacked on* the loudness
    // tip, so with no dynamics reading its name belongs at that tip too and
    // the separation rule below slides it clockwise until it clears LUFS-S.
    var nameLoudAngle = _startAngle;
    var nameDynAngle = _startAngle;

    // --- The rings -----------------------------------------------------------
    // Ring 0 is the outer, short-term pair; ring 1 the inner, integrated one.
    for (var i = 0; i < 2; i++) {
      final radius = outer - i * (ring + gap);
      final mid = radius - ring / 2;
      final bounds = Rect.fromCircle(center: centre, radius: mid);
      // Half a ring's width as an angle at this radius: how far past each
      // fixed end the swept clips open, so the clip's edge never shaves an
      // end that coincides with the track's.
      final cap = ring / 2 / mid;

      canvas.drawArc(bounds, _startAngle, _sweepAngle, false, _track);

      // The ceiling zone, over the track and under the arcs: the stretch of
      // scale past the delivery ceiling is a place, and it is tinted whether
      // or not anything has reached it.
      if (ceilingFraction < 1) {
        canvas.drawArc(
          bounds,
          _angleOf(ceilingFraction),
          (1 - ceilingFraction) * _sweepAngle,
          false,
          _ceilingZone,
        );
      }

      // --- Loudness, filling clockwise from the left end -------------------
      final level = state._shown[i];
      final loudFraction = level.isNaN ? double.nan : scale.fractionOf(level);
      if (!level.isNaN) {
        final sweep = loudFraction * _sweepAngle;
        if (sweep > 0) {
          _arc.color = i == 1 ? _ink : _shortFill;
          canvas.save();
          canvas.clipPath(
            state._sweptTo(
              centre,
              outer + ring,
              _startAngle - cap,
              _startAngle + sweep,
            ),
          );
          canvas.drawArc(bounds, _startAngle, sweep, false, _arc);
          // The floor colour over it, under the same clip, and never drawn
          // further round than it reaches: past the plateau the sweep is
          // transparent, and a stroke carried on to the right end would put
          // its antialiased edge on the dial's seam.
          canvas.drawArc(
            bounds,
            _startAngle,
            math.min(sweep, _sweepAngle * (1 - MeterFill.plateau)),
            false,
            i == 1 ? _footArc : _footArcShort,
          );
          canvas.restore();
        }
      }

      // --- Open Dynamic Range, stacked on the loudness tip -----------------
      // The arc spans [loudness, loudness + ODR] on the same dB scale, so its
      // moving end lands exactly on the true peak — see the module header.
      // Both of its ends are cut by the clip: the start is the loudness tip's
      // boundary, and the end is the peak itself, unmarked. Only when the peak
      // stands at full scale does the clip open past the scale's end, so the
      // arc reaches the track's end there rather than stopping a half pixel
      // inside it.
      final odr = state._shown[i + 2];
      var dynFrom = double.nan;
      var dynTo = double.nan;
      if (!level.isNaN && !odr.isNaN && odr > 0) {
        final peakFraction = scale.fractionOf(level + odr);
        if (peakFraction > loudFraction) {
          dynFrom = _angleOf(loudFraction);
          dynTo = _angleOf(peakFraction);
          _dynArc.color = i == 1 ? _dynFill : _dynFillShort;
          canvas.save();
          canvas.clipPath(
            state._sweptTo(
              centre,
              outer + ring,
              dynFrom,
              peakFraction >= 1 ? cap : dynTo,
            ),
          );
          canvas.drawArc(bounds, dynFrom, dynTo - dynFrom, false, _dynArc);
          canvas.restore();
        }
      }

      // Target tick on both rings, so each can be compared against it without
      // the eye travelling. Over the arcs, because the reading it judges is
      // drawn up to it and often past it.
      _radialTick(canvas, centre, targetAngle, radius - ring, radius);

      if (i == 0) {
        if (!loudFraction.isNaN) nameLoudAngle = _angleOf(loudFraction);
        // Its own tip where the arc has one, and the loudness tip where it
        // has not — an ODR of nothing is an arc of no length starting there.
        nameDynAngle = dynTo.isNaN ? nameLoudAngle : dynTo;
      }
    }

    // --- Names, riding the outer tips ----------------------------------------
    // Set along the arc outside the outer ring, the way a gauge face is
    // engraved: LUFS-S at the loudness tip, ODR-S at the dynamics tip, which
    // is the true peak. Only the outer ring is named — the inner one is what
    // the centre block spells out as INTEGRATED. When the two tips converge,
    // the dynamics name gives way clockwise rather than overprint.
    final nameLoud = state._nameLoud!;
    final nameDyn = state._nameDyn!;
    final nameRadius = outer + Space.xxs;
    final halfLoudName = nameLoud.longestLine / 2 / nameRadius;
    final halfDynName = nameDyn.longestLine / 2 / nameRadius;
    final namePad = Space.xs / nameRadius;
    var aLoud = nameLoudAngle.clamp(_startAngle + halfLoudName, -halfLoudName);
    var aDyn = nameDynAngle.clamp(_startAngle + halfDynName, -halfDynName);
    if (aDyn - aLoud < halfLoudName + halfDynName + namePad) {
      aDyn = aLoud + halfLoudName + halfDynName + namePad;
      if (aDyn > -halfDynName) {
        aDyn = -halfDynName;
        aLoud = aDyn - halfLoudName - halfDynName - namePad;
      }
    }
    _tipName(canvas, centre, nameLoud, aLoud, nameRadius);
    _tipName(canvas, centre, nameDyn, aDyn, nameRadius);

    // --- The centre -----------------------------------------------------------
    // The stack sized above, drawn top to bottom. The short-term row is
    // centred as a row of its own rather than column-aligned with the
    // integrated pair: its digits are [_shortScale] of theirs while its units
    // are the same fixed face, so the two rows' columns cannot line up
    // anyway, and rows each centred read as a stack — the way the heading and
    // the peak row always did.
    final lufsLeft = centre.dx - rowWidth / 2;
    final odrLeft = lufsLeft + lufsGroup + Space.md;

    var top = stackTop;
    if (showShort) {
      final shortLeft = centre.dx - shortRowWidth / 2;
      final odrShortLeft = shortLeft + lufsShortGroup + Space.md;
      canvas.drawParagraph(
        lufsShortLabel,
        Offset(
          shortLeft + (lufsShortGroup - lufsShortLabel.longestLine) / 2,
          top,
        ),
      );
      canvas.drawParagraph(
        odrShortLabel,
        Offset(
          odrShortLeft + (odrShortGroup - odrShortLabel.longestLine) / 2,
          top,
        ),
      );
      top += labelHeight + Space.xxs;
      final lufsShortAt = shortLeft + (lufsShortGroup - lufsShortPair) / 2;
      final odrShortAt = odrShortLeft + (odrShortGroup - odrShortPair) / 2;
      canvas.drawParagraph(lufsShortValue, Offset(lufsShortAt, top));
      _unit(canvas, lufsShortUnit, lufsShortValue, lufsShortAt, top);
      canvas.drawParagraph(odrShortValue, Offset(odrShortAt, top));
      _unit(canvas, odrShortUnit, odrShortValue, odrShortAt, top);
      top += lufsShortValue.height + sectionGap;
    }

    canvas.drawParagraph(
      lufsLabel,
      Offset(lufsLeft + (lufsGroup - lufsLabel.longestLine) / 2, top),
    );
    canvas.drawParagraph(
      odrLabel,
      Offset(odrLeft + (odrGroup - odrLabel.longestLine) / 2, top),
    );
    top += labelHeight + Space.xxs;

    canvas.drawParagraph(lufsValue, Offset(lufsLeft, top));
    _unit(canvas, lufsUnit, lufsValue, lufsLeft, top);
    canvas.drawParagraph(odrValue, Offset(odrLeft, top));
    _unit(canvas, odrUnit, odrValue, odrLeft, top);
    top += lufsValue.height + sectionGap;

    _row(
      canvas,
      centre.dx,
      top,
      state._truePeakLabel!,
      truePeakValue,
      state._truePeakUnit!,
    );
  }

  /// [unit] after [value], which sits at ([left], [top]) — on the value's
  /// baseline, because a unit's x-height and a digit's cap-height do not
  /// agree and centring one against the other floats it.
  void _unit(
    Canvas canvas,
    ui.Paragraph unit,
    ui.Paragraph value,
    double left,
    double top,
  ) {
    canvas.drawParagraph(
      unit,
      Offset(
        left + value.longestLine + Space.xs,
        top + value.alphabeticBaseline - unit.alphabeticBaseline,
      ),
    );
  }

  /// The target's radial tick, between [inner] and [outerRadius], over the
  /// slot that backs it — see [_targetSlot]. The only tick the rings carry.
  void _radialTick(
    Canvas canvas,
    Offset centre,
    double angle,
    double inner,
    double outerRadius,
  ) {
    final direction = Offset(math.cos(angle), math.sin(angle));
    final from = centre + direction * inner;
    final to = centre + direction * outerRadius;
    canvas.drawLine(from, to, _targetSlot);
    canvas.drawLine(from, to, _target);
  }

  /// One mark's number, flat, on the radial at [angle] and wholly inside the
  /// circle of [limit] — skipped entirely when it would overprint something
  /// already standing. Returns the rect it covered, so the next label can
  /// yield to it in turn.
  ///
  /// Inside the circle, not centred on it: a flat rect on a radial near the
  /// diameter reaches sideways, so the ceiling's number — which sits by the
  /// right end — ran half under the ring when it was centred one text height
  /// in. The centre is pulled in by the rect's own reach along the radial,
  /// which is a text height at the top of the dial and half a width at its
  /// ends.
  Rect? _tipValue(
    Canvas canvas,
    Offset centre,
    ui.Paragraph value,
    double angle,
    double limit,
    Rect? avoidA, [
    Rect? avoidB,
  ]) {
    final direction = Offset(math.cos(angle), math.sin(angle));
    final reach =
        value.longestLine / 2 * direction.dx.abs() +
        value.height / 2 * direction.dy.abs();
    final at =
        centre +
        direction * (limit - reach) -
        Offset(value.longestLine / 2, value.height / 2);
    final rect = Rect.fromLTWH(at.dx, at.dy, value.longestLine, value.height);
    if ((avoidA != null && rect.overlaps(avoidA)) ||
        (avoidB != null && rect.overlaps(avoidB))) {
      return null;
    }
    canvas.drawParagraph(value, at);
    return rect;
  }

  /// One tip's name, set along the arc: rotated to the tangent at [angle],
  /// its baseline resting on the circle of [radius], reading clockwise —
  /// which over the top half of a dial is never upside down.
  void _tipName(
    Canvas canvas,
    Offset centre,
    ui.Paragraph name,
    double angle,
    double radius,
  ) {
    canvas.save();
    canvas.translate(
      centre.dx + math.cos(angle) * radius,
      centre.dy + math.sin(angle) * radius,
    );
    canvas.rotate(angle + math.pi / 2);
    canvas.drawParagraph(name, Offset(-name.longestLine / 2, -name.height));
    canvas.restore();
  }

  /// One label, value and unit row, centred on [cx] with its top at [top],
  /// the label and the unit set on the value's baseline — the three are
  /// different sizes, and top-aligned the label floated above the number it
  /// names.
  void _row(
    Canvas canvas,
    double cx,
    double top,
    ui.Paragraph label,
    ui.Paragraph value,
    ui.Paragraph unit,
  ) {
    final total =
        label.longestLine +
        Space.xs +
        value.longestLine +
        Space.xs +
        unit.longestLine;
    final left = cx - total / 2;
    canvas.drawParagraph(
      label,
      Offset(left, top + value.alphabeticBaseline - label.alphabeticBaseline),
    );
    final valueLeft = left + label.longestLine + Space.xs;
    canvas.drawParagraph(value, Offset(valueLeft, top));
    _unit(canvas, unit, value, valueLeft, top);
  }

  @override
  bool shouldRepaint(_SuperMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      oldDelegate.scale != scale ||
      !identical(oldDelegate.engine, engine);
}
