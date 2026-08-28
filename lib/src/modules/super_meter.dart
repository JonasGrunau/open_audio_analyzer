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
/// exactly the true peak's position on the same scale — marked with its own
/// grey tick — and the dark remainder of the ring is the headroom to full
/// scale, closing as the limiter works. A dynamics arc reaching the right end
/// is a peak at 0 dBTP; past it is over.
///
/// The outer ring's two tips carry their names, set along the arc outside it
/// the way a gauge face is engraved: LUFS-S rides the loudness tip, ODR-S the
/// dynamics tip. Each arc's own reading is printed flat in the dark lane
/// inside it — raw from the measurement, positioned by the eased tip, hung
/// just behind it on the loudness side and mid-arc on the dynamics side so
/// the two never fight over the boundary they share. A reading that would
/// overprint the target's or the ceiling's printed number is skipped for that
/// frame instead: the centre repeats both integrated readings, so nothing is
/// lost but the duplicate. **A tip value wears its arc's ink**, never a
/// verdict's: the integrated arc is drawn neutral past the target and its
/// value follows, because a red number at the tip beside the red target
/// number read as one figure. The verdict colours live in the centre.
///
/// The right end carries the delivery ceiling as a red zone, the way the VU
/// meter's face carries its red sector: the region past the calibration's
/// true-peak ceiling is tinted on both rings, and the ceiling's value is
/// printed on its own radial tick. The target gets the same treatment on the
/// loudness side — a radial tick with the target value beside it, in
/// [OaaColors.over], the application's one colour for "the number you set".
///
/// The centre repeats the two integrated readings — LUFS and ODR — because
/// they are what gets delivered, with TRUEPEAK MAX under them, and LRA as the
/// last row where the module is tall enough to carry a fourth. Every value is
/// taken raw from the measurement, never from the eased arc positions: easing
/// decides where a shape is drawn, not what the instrument says.
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

  /// The dynamics family's ink: the arc colour lifted towards the text
  /// colour, because an arc can afford to recede and a printed number cannot.
  /// One recipe, used by the names in [build] and the values in the painter.
  static Color dynInkOf(OaaColors colors) =>
      Color.lerp(colors.meterFill, colors.textPrimary, 0.55)!;

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

  /// The level each arc is drawn at: [0] short-term LUFS, [1] integrated
  /// LUFS, [2] ODR-S, [3] ODR-I. NaN until that reading has a value, which is
  /// not a level of zero and is drawn as no arc at all.
  final List<double> _shown = List<double>.filled(4, double.nan);

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

    // A reset takes the clock back to zero, and a first measurement has
    // nothing to travel from. Snap rather than sweep up out of the floor,
    // which would be a picture of a programme that did not happen.
    // `!(dt > 0)` rather than `dt <= 0`, so that a NaN takes this branch too:
    // a source whose link has gone quiet reports NaN seconds, and NaN compares
    // false against everything — an alpha computed from one is NaN, and a
    // single NaN folded into an arc's position stays there for the rest of the
    // session.
    final alpha = !(dt > 0) || _seenGeneration < 0
        ? 1.0
        : 1 - math.exp(-dt / _tau);

    _fold(0, engine.lufsShort, alpha);
    _fold(1, engine.lufsIntegrated, alpha);
    _fold(2, engine.odrShort, alpha);
    _fold(3, engine.odrIntegrated, alpha);
  }

  /// One arc. A reading that is not yet defined leaves the arc undrawn rather
  /// than easing towards a number nobody measured, and the first reading after
  /// one snaps for the same reason.
  void _fold(int i, double value, double alpha) {
    final shown = _shown[i];
    _shown[i] = value.isNaN || shown.isNaN
        ? value
        : shown + (value - shown) * alpha;
  }

  /// The sector of the dial that lies beyond the target, and the geometry it
  /// was built for.
  ///
  /// Held across frames because **nothing on the frame path may allocate**, and
  /// a `Path` is the one thing an angular clip needs. It moves only when the
  /// module is resized or the delivery target changes, so it is rebuilt from
  /// those rather than per frame — the same bargain the graticules and the
  /// shaded fills in the other modules make.
  Path? _beyond;
  Offset _beyondCentre = Offset.zero;
  double _beyondRadius = 0;
  double _beyondFrom = double.nan;
  double _beyondTo = double.nan;

  /// The wedge an arc has swept, rebuilt every frame.
  ///
  /// Separate from [_beyond] and deliberately **not** cached: it moves with the
  /// reading, so there is nothing to cache. It is reset and refilled rather
  /// than reallocated, because the frame path may not allocate — four arcs at
  /// the refresh rate is a `Path` two hundred times a second otherwise.
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

  /// A wedge from [from] round to [to], apex at the centre.
  ///
  /// Deep enough to reach the outermost ring, which makes it the clip for both
  /// loudness arcs: every ring is inside the same radius, and the only
  /// boundary that matters is the radial one at the target.
  Path _sectorBeyond(Offset centre, double radius, double from, double to) {
    if (_beyond != null &&
        _beyondCentre == centre &&
        _beyondRadius == radius &&
        _beyondFrom == from &&
        _beyondTo == to) {
      return _beyond!;
    }
    _beyondCentre = centre;
    _beyondRadius = radius;
    _beyondFrom = from;
    _beyondTo = to;
    return _beyond = Path()
      ..moveTo(centre.dx, centre.dy)
      ..arcTo(
        Rect.fromCircle(center: centre, radius: radius),
        from,
        to - from,
        false,
      )
      ..close();
  }

  final _lufs = ValueParagraph();
  final _odr = ValueParagraph();
  final _truePeak = ValueParagraph();
  final _range = ValueParagraph();
  final _target = ValueParagraph();
  final _ceiling = ValueParagraph();
  final _tipLufsS = ValueParagraph();
  final _tipLufsI = ValueParagraph();
  final _tipOdrS = ValueParagraph();
  final _tipOdrI = ValueParagraph();
  ui.Paragraph? _integratedLabel;
  ui.Paragraph? _lufsLabel;
  ui.Paragraph? _odrLabel;
  ui.Paragraph? _truePeakLabel;
  ui.Paragraph? _rangeLabel;
  ui.Paragraph? _nameLoud;
  ui.Paragraph? _nameDyn;
  OaaColors? _colorsKey;

  @override
  void dispose() {
    _lufs.dispose();
    _odr.dispose();
    _truePeak.dispose();
    _range.dispose();
    _target.dispose();
    _ceiling.dispose();
    _tipLufsS.dispose();
    _tipLufsI.dispose();
    _tipOdrS.dispose();
    _tipOdrI.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_colorsKey != colors) {
      _colorsKey = colors;
      final style = OaaType.label.copyWith(color: colors.textFaint);
      _integratedLabel = layoutParagraph('INTEGRATED', style);
      _lufsLabel = layoutParagraph('LUFS', style);
      _odrLabel = layoutParagraph('ODR', style);
      _truePeakLabel = layoutParagraph('TRUEPEAK MAX', style);
      _rangeLabel = layoutParagraph('LRA', style);
      // The tip names, each in its family's ink rather than the label grey:
      // they ride moving tips, and a name the same colour as its arc is what
      // says which tip it is naming without a legend.
      _nameLoud = layoutParagraph(
        'LUFS-S',
        OaaType.label.copyWith(color: colors.meterFill),
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
       // Derived from `meterFill`, never from a text colour: `textMuted` sits
       // lighter than `meterFill` under the dark palette and darker under a
       // light one, so the two rings would swap which looked emphasised when
       // the skin changed. Built here rather than in `paint`, which is on the
       // frame path and allocates nothing.
       _shortFill = colors.meterFill.withValues(alpha: 0.55),
       // The dynamics arcs are the same instrument's second voice, and the
       // palette has no second hue to give them: [OaaColors.accent] means "in
       // spec" and [OaaColors.over] means over, on every surface. So they are
       // told apart by *weight* instead — half the ring's width, see
       // [_dynWidth] — and can then afford most of their ring's strength,
       // which they need: a printed value hangs off each of them now. At the
       // 0.42 and 0.28 they were first drawn at, the arcs vanished into the
       // track and the values were left labelling nothing.
       _dynFill = colors.meterFill.withValues(alpha: 0.70),
       _dynFillShort = colors.meterFill.withValues(alpha: 0.45),
       // Where a loudness arc runs past the target, in [OaaColors.over]. The
       // short-term ring keeps its 0.55 so the rings hold the same weights on
       // both sides of the line — a warning that also promoted the outer ring
       // would say two things at once.
       _over = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _overShort = colors.over.withValues(alpha: 0.55),
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
       // whole gauge is aimed at, and the arc standing past it is drawn in
       // the same colour — one statement told twice rather than two colours
       // to learn.
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
       // sits on three different backdrops — the empty track, the ring's own
       // fill, and [OaaColors.over] past the line — so the same mark reads at
       // three contrasts. That is a real effect, and it was judged not worth
       // cutting the arcs to fix.
       _targetSlot = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.heavy),
       // The true peak's own mark: where a dynamics arc ends, which is the
       // one point on the ring that is a measurement of something other than
       // loudness. [OaaColors.textMuted] because it reports where a peak
       // stands, and red is reserved for the two numbers somebody *set*.
       _truePeakMark = (Paint()
         ..color = colors.textMuted
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.heavy),
       _overTickStyle = OaaType.tick.copyWith(color: colors.over),
       _loudTickStyle = OaaType.tick.copyWith(color: colors.meterFill),
       _dynTickStyle = OaaType.tick.copyWith(
         color: _SuperMeterModuleState.dynInkOf(colors),
       ),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final MeterScale scale;
  final _SuperMeterModuleState state;

  final Paint _track;
  final Paint _arc;
  final Paint _dynArc;
  final Paint _over;
  final Paint _ceilingZone;
  final Paint _target;
  final Paint _targetSlot;
  final Paint _truePeakMark;
  final Color _shortFill;
  final Color _dynFill;
  final Color _dynFillShort;
  final Color _overShort;
  final TextStyle _overTickStyle;
  final TextStyle _loudTickStyle;
  final TextStyle _dynTickStyle;

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
    // The height of one printed tip value, from the style rather than a
    // layout: OaaType.tick is line-height 1.0, so the paragraph is exactly
    // its font size tall.
    final tipHeight = OaaType.tick.fontSize!;
    // Whether the gauge is big enough to print readings at the tips at all.
    // Below this the text would outweigh the rings it annotates, and the
    // centre still carries the two numbers that get delivered.
    final roomForTips = outer >= 72;
    // The lane between the rings. Sized to the rings when it is only a
    // separation; widened to hold a row of tick-sized text when the tips
    // print their values into it.
    final gap = roomForTips
        ? math.max(ring * 0.85, tipHeight + Space.xs)
        : ring * 0.85;
    final inkHeight = nameBand + outer;
    final centre = Offset(
      size.width / 2,
      (size.height - inkHeight) / 2 + nameBand + outer,
    );

    _track.strokeWidth = ring;
    _arc.strokeWidth = ring;
    _dynArc.strokeWidth = ring * _dynWidth;
    _over.strokeWidth = ring;
    _ceilingZone.strokeWidth = ring;

    // The target and the ceiling, as angles. Wanted by both rings — the ticks
    // are drawn on each and the sectors clip each arc — so neither is
    // recomputed inside the loop.
    final targetFraction = scale.fractionOf(calibration.lufsTarget);
    final targetAngle = _angleOf(targetFraction);
    final ceilingFraction = scale.fractionOf(calibration.truePeakMax);
    final beyond = state._sectorBeyond(
      centre,
      outer + ring,
      targetAngle,
      // A little past the right end, so the clip's edge never shaves it.
      _ringWidth,
    );

    // The integrated readings and their colours. Wanted twice — by the arcs
    // and tips and by the centre — and taken **raw**, from the measurement
    // rather than from the eased arc positions: a pass or fail is a fact
    // about a number somebody delivered, and easing decides where a shape is
    // drawn, never what it says.
    final integrated = engine.lufsIntegrated;
    final integratedState = classify(
      Metric.lufsIntegrated,
      integrated,
      calibration,
    );
    final integratedColor = colorForState(integratedState, colors);
    final odrIntegrated = engine.odrIntegrated;
    final odrIntegratedColor = colorForState(
      classify(Metric.odrIntegrated, odrIntegrated, calibration),
      colors,
    );

    // What the inner ring's loudness arc is drawn in *below* the target,
    // which is not always its verdict's colour: a verdict of
    // [ReadingState.over] is already drawn past the target by the clipped
    // pass, and painting the rest of the arc red as well erases the one thing
    // the cut exists to show — the size of the miss. An over-target ring
    // therefore falls back to the neutral colour below the line; the centre
    // readout is red either way, and it is the reading that gets delivered.
    final integratedBase = integratedState == ReadingState.over
        ? colorForState(ReadingState.neutral, colors)
        : integratedColor;

    final innerClear = outer - 2 * ring - gap;

    // The inner ring's tip values sit on this circle, just inside the ring;
    // the target's and the ceiling's numbers one row further in. Two rows
    // rather than one because the integrated reading spends its life a
    // decibel or so either side of the target — that is what a target is for
    // — and a tip value sharing the target's row was hidden by it exactly
    // when the material was mastered to spec.
    final tipRadius = innerClear - Space.xxs - tipHeight / 2;
    final markRadius = tipRadius - tipHeight - Space.xs;

    // Where the centre's heading will go — see the centre, below. Wanted
    // here because a mark's number that would land on it is not printed.
    final integratedLabel = state._integratedLabel!;
    final headingRect = Rect.fromLTWH(
      centre.dx - integratedLabel.longestLine / 2,
      centre.dy - innerClear * 0.72,
      integratedLabel.longestLine,
      integratedLabel.height,
    );

    // --- The target's and the ceiling's own numbers --------------------------
    // Each on its tick's radial, in the mark's own colour, inside the rings.
    // Drawn before the rings only in code — nothing else reaches the clear
    // disc — and kept as rects so a tip value crossing one can yield to it.
    Rect? targetRect;
    Rect? ceilingRect;
    if (innerClear > 56) {
      targetRect = _tipValue(
        canvas,
        centre,
        state._target.of(
          calibration.lufsTarget.toStringAsFixed(1),
          _overTickStyle,
        ),
        targetAngle,
        markRadius,
        headingRect,
        null,
        null,
      );
      ceilingRect = _tipValue(
        canvas,
        centre,
        state._ceiling.of(
          calibration.truePeakMax.toStringAsFixed(1),
          _overTickStyle,
        ),
        _angleOf(ceilingFraction),
        markRadius,
        headingRect,
        targetRect,
        null,
      );
    }

    // Where the outer ring's tip names ride, resolved inside the ring loop.
    // Each rests at its home end until its arc has a tip to name: the
    // loudness name at the silent end, the dynamics name at full scale.
    var nameLoudAngle = _startAngle;
    var nameDynAngle = _startAngle + _sweepAngle;

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
          _arc.color = i == 1 ? integratedBase : _shortFill;
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

          // Whatever ran past the target, again, in [OaaColors.over] and
          // clipped to the sector beyond the tick as well — the two clips
          // intersect, so this pass is bounded by the reading at one end and
          // the target at the other.
          //
          // **The same arc redrawn under a clip, not a second arc starting at
          // the target.** Two arcs meeting at the tick would meet cap to cap,
          // and the seam would be a lump straddling the target with the over
          // colour nosing into the good side of it. Clipping puts the colour
          // boundary exactly where the target is, which is the only place it
          // is true.
          if (_startAngle + sweep > targetAngle) {
            _over.color = i == 0 ? _overShort : colors.over;
            canvas.clipPath(beyond);
            canvas.drawArc(bounds, _startAngle, sweep, false, _over);
          }
          canvas.restore();
        }
      }

      // --- Open Dynamic Range, stacked on the loudness tip -----------------
      // The arc spans [loudness, loudness + ODR] on the same dB scale, so its
      // moving end lands exactly on the true peak — see the module header.
      // Both of its ends are cut by the clip: the start is the loudness tip's
      // boundary, and the end is a value of its own, marked with the grey
      // true-peak tick. Only when the peak stands at full scale does the clip
      // open past the scale's end, so the arc reaches the track's end there
      // rather than stopping a half pixel inside it.
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
          if (peakFraction < 1) {
            _radialTick(canvas, centre, dynTo, radius - ring, radius, false);
          }
        }
      }

      // Target tick on both rings, so each can be compared against it without
      // the eye travelling. Over the arcs, because the reading it judges is
      // drawn up to it and often past it.
      _radialTick(canvas, centre, targetAngle, radius - ring, radius, true);

      if (i == 0) {
        if (!loudFraction.isNaN) nameLoudAngle = _angleOf(loudFraction);
        if (!dynTo.isNaN) nameDynAngle = dynTo;
      }

      // --- The tips' own numbers --------------------------------------------
      // Flat in the dark lane inside the ring: the outer pair between the
      // rings, the inner pair in the clear disc, each raw from the
      // measurement and positioned by the eased tip. The loudness value hangs
      // just behind its tip; the dynamics value sits mid-arc, so the two
      // never meet at the boundary they share — and either yields entirely,
      // for a frame, rather than overprint a number already standing.
      final drawTips = i == 0 ? roomForTips : roomForTips && innerClear > 56;
      if (drawTips) {
        final rowRadius = i == 0 ? outer - ring - gap / 2 : tipRadius;
        Rect? loudRect;
        final rawLoud = i == 0 ? engine.lufsShort : integrated;
        if (!level.isNaN && !rawLoud.isNaN) {
          final value = (i == 0 ? state._tipLufsS : state._tipLufsI).of(
            Metric.lufsShort.format(rawLoud),
            i == 0
                ? _loudTickStyle
                : OaaType.tick.copyWith(color: integratedBase),
          );
          final half = value.longestLine / 2 / rowRadius;
          final at = math.max(
            _angleOf(loudFraction) - half - Space.xs / rowRadius,
            _startAngle + half,
          );
          loudRect = _tipValue(
            canvas,
            centre,
            value,
            at,
            rowRadius,
            targetRect,
            ceilingRect,
            null,
          );
        }
        final rawOdr = i == 0 ? engine.odrShort : odrIntegrated;
        if (!dynFrom.isNaN && !rawOdr.isNaN) {
          final value = (i == 0 ? state._tipOdrS : state._tipOdrI).of(
            Metric.odrShort.format(rawOdr),
            _dynTickStyle,
          );
          _tipValue(
            canvas,
            centre,
            value,
            (dynFrom + dynTo) / 2,
            rowRadius,
            loudRect,
            targetRect,
            ceilingRect,
          );
        }
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
    // The two integrated readings side by side, TRUEPEAK MAX under them, LRA
    // last — see the module header. Sized off the gauge rather than the
    // module, because the readout lives inside the rings.
    final truePeakMax = engine.truePeakMax;
    final lufsText = Metric.lufsIntegrated.format(integrated);
    final odrText = Metric.odrIntegrated.format(odrIntegrated);

    // Every glyph in a reading is a digit, a minus or a point, and the
    // reading face is monospaced, so the width is arithmetic and not a
    // measurement — no second layout to find out whether the first fitted.
    // The two columns share the clear width between the rings.
    final columnWidth = innerClear * 1.5 - Space.sm;
    final glyphs = math.max(5, math.max(lufsText.length, odrText.length));
    final fontSize = math
        .min(outer * 0.17, columnWidth / (glyphs * 0.62))
        .clamp(11.0, 96.0)
        .toDouble();

    final lufsValue = state._lufs.of(
      lufsText,
      OaaType.reading(fontSize).copyWith(color: integratedColor),
    );
    final odrValue = state._odr.of(
      odrText,
      OaaType.reading(fontSize).copyWith(color: odrIntegratedColor),
    );

    final lufsLabel = state._lufsLabel!;
    final odrLabel = state._odrLabel!;

    final rowWidth = lufsValue.longestLine + Space.md + odrValue.longestLine;
    final lufsLeft = centre.dx - rowWidth / 2;
    final odrLeft = lufsLeft + lufsValue.longestLine + Space.md;

    var top = headingRect.top;
    canvas.drawParagraph(integratedLabel, headingRect.topLeft);
    top += integratedLabel.height + Space.xs;

    canvas.drawParagraph(
      lufsLabel,
      Offset(
        lufsLeft + (lufsValue.longestLine - lufsLabel.longestLine) / 2,
        top,
      ),
    );
    canvas.drawParagraph(
      odrLabel,
      Offset(odrLeft + (odrValue.longestLine - odrLabel.longestLine) / 2, top),
    );
    top += lufsLabel.height + Space.xxs;

    canvas.drawParagraph(lufsValue, Offset(lufsLeft, top));
    canvas.drawParagraph(odrValue, Offset(odrLeft, top));
    top += lufsValue.height + Space.xs;

    // TRUEPEAK MAX, the number the ceiling zone is about. Red exactly when it
    // stands in that zone.
    top += _row(
      canvas,
      centre.dx,
      top,
      state._truePeakLabel!,
      state._truePeak.of(
        Metric.truePeakMax.format(truePeakMax),
        OaaType.readingSmall.copyWith(
          color: colorForState(
            classify(Metric.truePeakMax, truePeakMax, calibration),
            colors,
          ),
        ),
      ),
    );

    // LRA, where the module is tall enough to carry a fourth row. Decibel's
    // Super Meter stops at true peak; the loudness range survives here
    // because it is the other number a target can put a limit on, and the
    // Loudness Distribution is not always on the canvas.
    if (size.height > 200) {
      _row(
        canvas,
        centre.dx,
        top + Space.xxs,
        state._rangeLabel!,
        state._range.of(
          Metric.loudnessRange.format(engine.loudnessRange),
          OaaType.readingSmall.copyWith(
            color: colorForState(
              classify(Metric.loudnessRange, engine.loudnessRange, calibration),
              colors,
            ),
          ),
        ),
      );
    }
  }

  /// One radial tick between [inner] and [outerRadius]. The target's carries
  /// a slot under it — see [_targetSlot]; the true peak's is a reported
  /// value, not a set one, and takes the muted mark instead.
  void _radialTick(
    Canvas canvas,
    Offset centre,
    double angle,
    double inner,
    double outerRadius,
    bool isTarget,
  ) {
    final direction = Offset(math.cos(angle), math.sin(angle));
    final from = centre + direction * inner;
    final to = centre + direction * outerRadius;
    if (isTarget) {
      canvas.drawLine(from, to, _targetSlot);
      canvas.drawLine(from, to, _target);
    } else {
      canvas.drawLine(from, to, _truePeakMark);
    }
  }

  /// One tip's number, flat, centred at [angle] on the circle of [radius] —
  /// skipped entirely when it would overprint something already standing.
  /// Returns the rect it covered, so the next label can yield to it in turn.
  Rect? _tipValue(
    Canvas canvas,
    Offset centre,
    ui.Paragraph value,
    double angle,
    double radius,
    Rect? avoidA,
    Rect? avoidB,
    Rect? avoidC,
  ) {
    final at =
        centre +
        Offset(math.cos(angle), math.sin(angle)) * radius -
        Offset(value.longestLine / 2, value.height / 2);
    final rect = Rect.fromLTWH(at.dx, at.dy, value.longestLine, value.height);
    if ((avoidA != null && rect.overlaps(avoidA)) ||
        (avoidB != null && rect.overlaps(avoidB)) ||
        (avoidC != null && rect.overlaps(avoidC))) {
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

  /// One label-and-value row, centred on [cx] with its top at [top]. Returns
  /// the height it used.
  double _row(
    Canvas canvas,
    double cx,
    double top,
    ui.Paragraph label,
    ui.Paragraph value,
  ) {
    final total = label.longestLine + Space.xs + value.longestLine;
    canvas.drawParagraph(label, Offset(cx - total / 2, top));
    canvas.drawParagraph(
      value,
      Offset(cx - total / 2 + label.longestLine + Space.xs, top - 1),
    );
    return value.height;
  }

  @override
  bool shouldRepaint(_SuperMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      oldDelegate.scale != scale ||
      !identical(oldDelegate.engine, engine);
}
