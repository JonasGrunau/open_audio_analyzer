// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Momentary, short-term and integrated loudness as three concentric arcs.
///
/// Decibel's name, kept because there is no better one for this. The arrangement
/// earns its space by making one relationship immediate: the three arcs share a
/// scale and a target tick, so a momentary arc running far past the integrated
/// one is a mix that is about to get louder than it should, and that is visible
/// as a shape rather than as three numbers to compare.
///
/// The innermost arc is the integrated reading — the number that actually gets
/// delivered — and it is the one the centre readout repeats. Outward from it is
/// increasingly short-term, which is increasingly volatile, which is what a
/// glance should skip past.
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
  static const _scale = MeterScale(min: -48, max: 0, step: 6);

  /// Seconds for an arc to cover 63% of the distance to a new reading.
  ///
  /// The three quantities behind the arcs advance on the engine's gating grid
  /// and nowhere else: a momentary reading is a 400 ms window that slides in
  /// 100 ms steps, so it changes exactly ten times a second however often it
  /// is read. The clock repaints at the engine's publish rate, about 47 Hz, so
  /// four frames in five drew the arc exactly where the frame before had left
  /// it and the fifth jumped. A bar a few pixels tall gets away with that; a
  /// 240 degree arc across the whole module does not, and it reads as an
  /// instrument stuttering rather than as a signal moving.
  ///
  /// Half the interval between readings, so each step is 87% travelled before
  /// the next one arrives, and an eighth of the momentary window, so the ease
  /// is much shorter than the shortest thing the measurement itself can
  /// resolve. It fills the gap between readings; it cannot smooth away
  /// anything a reading could have shown.
  ///
  /// **Arcs only.** Every number this module prints, and every colour it
  /// decides from one, is the measurement — drawn the frame it arrives. What
  /// is eased is where a shape is drawn to, which is what the analyser's
  /// response setting already does to its curve.
  static const double _tau = 0.05;

  /// The level each arc is drawn at, in LUFS: momentary, short-term,
  /// integrated. NaN until that reading has a value, which is not a level of
  /// zero and is drawn as no arc at all.
  final List<double> _shown = List<double>.filled(3, double.nan);

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

    _fold(0, engine.lufsMomentary, alpha);
    _fold(1, engine.lufsShort, alpha);
    _fold(2, engine.lufsIntegrated, alpha);
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

  /// A wedge from [from] round to [to], apex at the centre.
  ///
  /// Deep enough to reach the outermost ring, which makes it the clip for all
  /// three: every ring is inside the same radius, and the only boundary that
  /// matters is the radial one at the target.
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

  final _integrated = ValueParagraph();
  final _range = ValueParagraph();
  ui.Paragraph? _unit;
  ui.Paragraph? _rangeLabel;
  List<ui.Paragraph> _arcLabels = const [];
  double _arcLabelHeight = 0;
  Color? _labelColor;

  @override
  void dispose() {
    _integrated.dispose();
    _range.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_labelColor != colors.textFaint) {
      _labelColor = colors.textFaint;
      final style = OaaType.label.copyWith(color: colors.textFaint);
      _unit = layoutParagraph('LUFS', style);
      _rangeLabel = layoutParagraph('LRA', style);
      _arcLabels = [
        layoutParagraph('M', style),
        layoutParagraph('S', style),
        layoutParagraph('I', style),
      ];
      _arcLabelHeight = _arcLabels.first.height;
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
  }) : // Round, and the track and the fill have to agree: a round cap puts
       // half a ring of ink *beyond* each end of the sweep, so a butt track
       // under a round fill would be overrun at both ends of the scale. Given
       // the same cap, the fill's ends land exactly on the track's — and the
       // half ring the pair gained at the open end is what [_labelGap] carries.
       _track = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.round),
       _arc = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.round),
       // Derived from `meterFill`, never from a text colour: `textMuted` sits
       // lighter than `meterFill` under the dark palette and darker under a
       // light one, so the momentary and short-term arcs would swap which
       // looked emphasised when the skin changed. Built here rather than in
       // `paint`, which is on the frame path and allocates nothing.
       _shortFill = colors.meterFill.withValues(alpha: 0.55),
       // Where an arc runs past the target. The short-term ring keeps its 0.55
       // so the three rings hold the same weights on both sides of the line —
       // a warning that also promoted the middle ring would say two things at
       // once.
       _over = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.round),
       _overShort = colors.warn.withValues(alpha: 0.55),
       // [OaaStroke.heavy] where every other target mark in the application
       // takes [OaaStroke.mark], because this one is *radial* and the others
       // are axis-aligned. A horizontal target line at 1.5 px is drawn with
       // antialiasing off and lands on whole pixels at full strength; an angled
       // stroke cannot be, and antialiasing spreads the same 1.5 px across two
       // pixel columns at about half the alpha each. The nominal weight matched
       // and the contrast did not, which is why three deliberate ticks read as
       // three rendering artefacts. Two steps rather than one, because this
       // mark is also crossed by the arcs themselves: it has to be found over
       // the brightest ink on the module, not against the background.
       _target = (Paint()
         ..color = colors.textMuted
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.heavy),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final MeterScale scale;
  final _SuperMeterModuleState state;

  final Paint _track;
  final Paint _arc;
  final Paint _over;
  final Paint _target;
  final Color _shortFill;
  final Color _overShort;

  /// The gauge opens at the bottom: 150° round to 30°, clockwise. A full ring
  /// would have no beginning and no end, and a scale needs both.
  static const double _startAngle = 150 * math.pi / 180;
  static const double _sweepAngle = 240 * math.pi / 180;

  /// The width of one ring, as a fraction of the outer radius.
  static const double _ringWidth = 0.115;

  /// Where a ring's name sits, as a fraction of the ring's width, measured
  /// **along the arc** from its open end.
  ///
  /// An arc length rather than an angle, which is the whole point. The names
  /// used to lead the arcs by a fixed 0.12 radians, and a fixed angle is a
  /// fixed fraction of each radius — so the outermost name stood nearly twice
  /// as far from its own arc as the innermost did from its. Three names that
  /// each mark one ring then read as a diagonal drifting off the bottom of the
  /// gauge rather than as three labels. The same number of pixels for all
  /// three puts each name beside the arc it names.
  ///
  /// Half a ring of it is the round cap, which is ink the arc did not have when
  /// this was 0.7: the gap is measured from the *end of the sweep*, and the cap
  /// is a semicircle drawn past it. Clearance from what is actually on screen
  /// is what the eye reads, so the cap is paid for here rather than allowed to
  /// close on the names.
  static const double _labelGap = 1.2;

  /// The angular lead of the *outermost* name.
  ///
  /// It is the lowest ink on the face, so the layout is solved against it
  /// rather than against the arcs. Both terms of the arc length scale with the
  /// outer radius, so this angle does not depend on the module's size: the
  /// name sits on its ring's centreline, half a ring in from the outer edge.
  static const double _labelLead =
      _ringWidth * _labelGap / (1 - _ringWidth / 2);

  @override
  void paint(Canvas canvas, Size size) {
    if (engine.generation != state._seenGeneration) {
      state._advance(engine);
      state._seenGeneration = engine.generation;
    }

    // **The gauge is not a circle and must not be centred as one.** It opens
    // 120° at the bottom, so its ink reaches only `sin` of the way below the
    // centre that it does above it — and centring the notional circle instead
    // of the drawn shape left a band of dead space along the bottom of the
    // module a fifth of its height deep, with the ring labels stranded in it.
    // Solve for the radius that fills the box, then centre what is actually
    // drawn.
    final labelDrop = math.sin(_startAngle - _labelLead);
    final labelHalf = state._arcLabelHeight / 2;

    final outer = math.min(
      size.width / 2,
      (size.height - labelHalf) / (1 + labelDrop),
    );
    if (outer < 40) return;

    final inkHeight = outer * (1 + labelDrop) + labelHalf;
    final centre = Offset(
      size.width / 2,
      (size.height - inkHeight) / 2 + outer,
    );

    // Three rings and two gaps, sized off the module rather than fixed, so the
    // meter reads the same at 6x6 cells and at 12x12.
    //
    // The gap is nearly as wide as a ring on purpose. At a third of a ring the
    // arithmetic is fine and the display is not: two adjacent rings at similar
    // brightness read as one thick band with a seam, and the whole point of
    // three concentric arcs is being able to tell which is which at a glance.
    final ring = outer * _ringWidth;
    final gap = ring * 0.85;

    _track.strokeWidth = ring;
    _arc.strokeWidth = ring;
    _over.strokeWidth = ring;

    // The target, as an angle, and the sector of the dial past it. Both are
    // wanted by all three rings — the tick is drawn on each of them and the
    // sector clips each arc's warning colour — so neither is recomputed inside
    // the loop.
    final targetSweep = scale.fractionOf(calibration.lufsTarget) * _sweepAngle;
    final targetAngle = _startAngle + targetSweep;
    final beyond = state._sectorBeyond(
      centre,
      outer,
      targetAngle,
      _startAngle + _sweepAngle,
    );

    // The integrated reading, and the colour it is in. Both are wanted twice —
    // by the innermost arc and by the centre readout — and taken **raw**, from
    // the measurement rather than from the eased arc position: a pass or fail
    // is a fact about a number somebody delivered, and easing decides where a
    // shape is drawn, never what it says.
    final integrated = engine.lufsIntegrated;
    final integratedColor = colorForState(
      classify(Metric.lufsIntegrated, integrated, calibration),
      colors,
    );

    for (var i = 0; i < 3; i++) {
      final radius = outer - i * (ring + gap);
      if (radius < ring) break;
      final bounds = Rect.fromCircle(center: centre, radius: radius - ring / 2);

      canvas.drawArc(bounds, _startAngle, _sweepAngle, false, _track);

      // Where the arc is drawn to, which lags the reading by [_tau] and
      // nothing else — see the note on it. NaN here is a reading that does not
      // exist yet, and the arc is simply absent.
      final value = state._shown[i];
      if (!value.isNaN) {
        // The integrated arc is the only one with a pass/fail meaning, so it is
        // the only one that takes the signal colour. Colouring all three would
        // make the accent decorative, and an accent that is decoration cannot
        // also be a warning.
        _arc.color = i == 2
            ? integratedColor
            : (i == 0 ? colors.meterFill : _shortFill);
        final sweep = scale.fractionOf(value) * _sweepAngle;
        if (sweep > 0) {
          canvas.drawArc(bounds, _startAngle, sweep, false, _arc);

          // Whatever ran past the target, again, in the warning colour and
          // clipped to the sector beyond the tick.
          //
          // **The same arc redrawn under a clip, not a second arc starting at
          // the target.** Two arcs meeting at the tick would meet round cap to
          // round cap, and each cap is a semicircle half a ring long drawn
          // *past* its own end — so the seam would be a lump straddling the
          // target with the warning nosing half a ring into the good side of
          // it. Clipping puts the colour boundary exactly where the target is,
          // which is the only place it is true, and leaves the arc's own cap at
          // the reading intact.
          if (sweep > targetSweep) {
            _over.color = i == 1 ? _overShort : colors.warn;
            canvas.save();
            canvas.clipPath(beyond);
            canvas.drawArc(bounds, _startAngle, sweep, false, _over);
            canvas.restore();
          }
        }
      }

      // Target tick, on every ring, so the three can be compared against it
      // without the eye travelling to a legend. Over the arcs, because the
      // reading it judges is drawn up to it and often past it.
      final inner = radius - ring;
      canvas.drawLine(
        centre + Offset(math.cos(targetAngle), math.sin(targetAngle)) * inner,
        centre + Offset(math.cos(targetAngle), math.sin(targetAngle)) * radius,
        _target,
      );

      // Ring name, at the open end of the gauge, on the ring's own centreline
      // and the same arc length from every arc — see [_labelGap].
      final label = state._arcLabels[i];
      final labelRadius = radius - ring / 2;
      final labelAngle = _startAngle - ring * _labelGap / labelRadius;
      canvas.drawParagraph(
        label,
        centre +
            Offset(math.cos(labelAngle), math.sin(labelAngle)) * labelRadius -
            Offset(label.longestLine / 2, label.height / 2),
      );
    }

    // --- The centre ---------------------------------------------------------
    // Sized off the gauge rather than off the module's short side: the
    // readout lives inside the rings, so it has to scale with them.
    // The ceiling is high enough that the gauge is what limits the number, not
    // the constant. At 56 a Super Meter given a quarter of a 27" display drew
    // the same digits in the middle of a 700 px dial as one in a corner drew in
    // a 350 px one, and the readout stopped looking like the centre of the
    // instrument and started looking like a caption that had been left behind.
    final dial = outer * 2;

    // **The rings bound the readout, not the module.** `outer` is the outside
    // of the first arc; three rings and two gaps in, what is left is the clear
    // disc the number sits in. Sizing against `dial` alone is what put a
    // four-digit reading through the innermost arc on both sides: the old
    // `maxWidth` of `dial * 0.6` is 1.2 times `outer`, and the disc is only
    // 0.92 of it across.
    final innerRadius = outer - 2 * (ring + gap) - ring;

    // A chord, not the diameter. The number is not a line — it stands about
    // four tenths of the inner radius tall — and a box as wide as the circle
    // fits only if it has no height. At 0.8 of the radius its corners still
    // clear the arc.
    final textWidth = innerRadius * 1.6;

    // Every glyph in a reading is a digit, a minus or a point, and the reading
    // face is monospaced, so the width is arithmetic and not a measurement —
    // no second layout to find out whether the first one fitted. 0.62 em covers
    // Google Sans Code's 0.6 advance with a little slack.
    final text = Metric.lufsIntegrated.format(integrated);
    final fontSize = math
        .min(dial * 0.16, textWidth / (text.length * 0.62))
        .clamp(12.0, 120.0);

    final value = state._integrated.of(
      text,
      OaaType.reading(fontSize).copyWith(color: integratedColor),
      align: TextAlign.center,
      maxWidth: textWidth,
    );
    canvas.drawParagraph(
      value,
      Offset(centre.dx - textWidth / 2, centre.dy - value.height * 0.72),
    );

    final unit = state._unit!;
    canvas.drawParagraph(
      unit,
      Offset(centre.dx - unit.longestLine / 2, centre.dy + value.height * 0.32),
    );

    // LRA underneath, because "how far does it move" is the second question
    // asked of an integrated reading and the only other one that survives to
    // delivery.
    if (size.height > 140) {
      final range = state._range.of(
        Metric.loudnessRange.format(engine.loudnessRange),
        OaaType.readingSmall.copyWith(
          color: colorForState(
            classify(Metric.loudnessRange, engine.loudnessRange, calibration),
            colors,
          ),
        ),
      );
      final label = state._rangeLabel!;
      final total = label.longestLine + Space.xs + range.longestLine;
      final top = centre.dy + value.height * 0.32 + unit.height + Space.xs;
      canvas.drawParagraph(label, Offset(centre.dx - total / 2, top));
      canvas.drawParagraph(
        range,
        Offset(centre.dx - total / 2 + label.longestLine + Space.xs, top - 1),
      );
    }
  }

  @override
  bool shouldRepaint(_SuperMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      oldDelegate.scale != scale ||
      !identical(oldDelegate.engine, engine);
}
