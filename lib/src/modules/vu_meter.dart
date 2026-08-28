// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// A needle, on the movement the engine models.
///
/// The dial is not nostalgia. A VU is average-responding where every other
/// meter here is peak- or RMS-responding, and its 300 ms movement with a little
/// overshoot is a low-pass filter with a shape that happens to track perceived
/// level well — which is why people still mix to one. Both properties live in
/// `oaa_analysis.c`; this module draws the result and nothing else.
///
/// **0 VU is the calibration's reference level, not 0 dBFS.** That is the whole
/// point of the module: −18 dBFS reads 0 VU for EBU work and −20 dBFS for US
/// broadcast, and a VU meter pinned to digital full scale would sit at the
/// bottom of its scale for every programme ever made. The face says so in
/// as many words along its bottom edge, because it is the one thing about a VU
/// meter that is genuinely confusing and no amount of correct needle ballistics
/// explains it.
///
/// ---------------------------------------------------------------------------
/// The weight is in the scale, not in a surface
///
/// For eight phases this module was a hairline arc, eleven ticks and a
/// one-pixel needle — an outline of a dial rather than a dial. So the scale is
/// now a band along the rim rather than a line, in [OaaColors.meterTrack] up to
/// 0 VU and [OaaColors.over] above it over a tinted ring, with the standard
/// face's marks — −20 to +2 labelled, `−` and `+` past the ends — and a peak
/// lamp beside the dial that lights while the held peak stands in the red.
/// The needle is a taper in [OaaColors.meterFill], the instrument's own fill
/// colour, rising from behind the boxed reading that sits over the pivot: a
/// movement needs a hub, and a drawing of one does better with the number.
/// That is weight rather than decoration: at a glance the module says *how far
/// up the scale the programme is* from the proportion of the rim that is red,
/// before the needle is read at all.
///
/// **The module paints no surface of its own**, and two attempts at one are
/// written down here so they are not made again. Filling the sector the needle
/// can reach draws a pie slice, whose two straight edges are then the most
/// prominent lines on the module and mean nothing. Filling the whole body a
/// step down — [OaaColors.background], to read as glass set into the panel —
/// makes this the one module on the canvas that is not the colour of a module,
/// which is louder than anything it buys. A meter sits on the surface the frame
/// gives it, like the other thirteen.
class VuMeterModule extends StatefulWidget {
  const VuMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<VuMeterModule> createState() => _VuMeterModuleState();
}

/// The marks on a VU face, in VU. Not evenly spaced, and that is the standard
/// face rather than a stylistic choice — the scale crowds towards −20 because
/// the movement's deflection is linear in *voltage*, not in decibels.
const _vuMarks = <double>[-20, -15, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3];

/// Which of them get a number under them: the standard face's nine, −20 to +2.
/// +3 is the pin, and the `+` sign at the end of the arc marks it better than
/// a tenth digit would.
const _vuLabelled = <double>[-20, -10, -7, -5, -3, -1, 0, 1, 2];

/// The order the nine are placed in, which is the order the room runs out in
/// reverse. 0 is what the face is for and the two ends say how far it reaches;
/// the ones in between are the ones a small tile can do without.
const _labelOrder = <double>[0, -20, 2, -10, -7, -5, -3, -1, 1];

/// The widest reading the boxed readout has to hold, used to reserve its room
/// rather than measuring the live string.
///
/// The digits are tabular, but the *number of them* is not fixed — `+3.0` and
/// `-20.0` are two glyphs apart — and reserving from whatever happens to be on
/// screen is a box that changes its mind about whether it fits while you watch
/// the needle.
const _readingTemplate = '-20.0';

class _VuMeterModuleState extends State<VuMeterModule> {
  List<ui.Paragraph> _labels = const [];
  ui.Paragraph? _minus;
  ui.Paragraph? _plus;
  ui.Paragraph? _reference;
  ui.Paragraph? _referenceShort;
  ui.Paragraph? _template;
  final _reading = ValueParagraph();

  OaaColors? _builtColors;
  double? _builtReference;

  /// How much room the scale labels need, above the arc and beside it.
  ///
  /// The labels sit outside the arc, each one pushed out far enough that its
  /// *near* edge clears the arc by the same gap — which is what puts six boxes
  /// of three different widths on one visual radius rather than scattered
  /// along it.
  ///
  /// The two directions get different bounds because they are genuinely
  /// different problems, and using one number for both is what left a band of
  /// dead space above the dial. Straight up the reserve is exactly one label
  /// height; the label nearest vertical is the tallest thing over the arc and
  /// nothing beyond it reaches higher. Sideways it depends on the angle the
  /// sweep opens to, so it is bounded rather than solved.
  double _labelAbove = 0;
  double _labelBeside = 0;

  /// The bottom row: the reading on the left, what 0 VU means on the right.
  ///
  /// Reserved below the pivot rather than drawn on the face. Printing anything
  /// inside the dial is what a real VU does and it is wrong here: at 0 VU — the
  /// one reading anybody is looking for — the needle passes straight through
  /// the middle of the face.
  double _rowHeight = 0;
  double _rowBaseline = 0;
  double _readingWidth = 0;

  /// The loudest VU seen recently, in VU, and how long it has stood.
  ///
  /// A VU movement is deliberately slow, which is what makes it readable and
  /// also means the loudest moment of a phrase has come and gone before the
  /// needle finishes describing it. The mark on the rim is where the needle
  /// *reached*; it is the same quantity the needle draws and no second
  /// measurement, which is why it is held here rather than asked of the engine.
  double _peak = double.nan;
  double _held = 0;

  /// The published measurement [_peak] was last advanced for, and the engine
  /// time it was advanced at.
  ///
  /// **Zero is a real generation to have never seen**, so this starts at −1: a
  /// source that published exactly once and then stopped must still get that
  /// one measurement.
  int _seenGeneration = -1;
  double _seenElapsed = 0;

  /// How long the mark stands before it starts to fall, and how fast it falls.
  ///
  /// Long enough to read across a bar, short enough that it is describing this
  /// phrase and not the last one.
  static const double _peakHold = 1.6;
  static const double _peakFall = 14.0;

  /// Advances the peak mark for one published measurement.
  ///
  /// **Called on a change of generation, never on a paint.** Paint also runs on
  /// a resize, a skin change and a selection, and a mark that decayed on those
  /// would fall while no audio played — the same defect as a spectrogram that
  /// scrolls when the window is dragged, and just as convincing.
  ///
  /// The hold is measured in *engine* seconds rather than counted in frames, so
  /// it lasts as long whether the meters refresh at 30, 60 or 120.
  void _advance(MeterSource engine, double vu) {
    final elapsed = engine.elapsedSeconds;
    final dt = elapsed - _seenElapsed;
    _seenElapsed = elapsed;

    // A reset takes the clock back to zero, and a first measurement has nothing
    // to have fallen from. `!(dt > 0)` rather than `dt <= 0` so that a NaN
    // takes this branch too: a source whose link has gone quiet reports NaN
    // seconds, and a hold accumulated from one never expires again.
    //
    // `!(vu < _peak)` for the same reason on the other axis — an unmeasured
    // reading takes the mark with it rather than leaving the last one standing
    // over a face that is no longer reading anything.
    if (!(dt > 0) || _seenGeneration < 0 || !(vu < _peak)) {
      _peak = vu;
      _held = 0;
      return;
    }

    _held += dt;
    final falling = _held - _peakHold;
    if (falling > 0) {
      _peak = math.max(vu, _peak - _peakFall * math.min(dt, falling));
    }
  }

  @override
  void dispose() {
    _reading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final reference = widget.calibration.vuReference;

    if (_builtColors != colors || _builtReference != reference) {
      _builtColors = colors;
      _builtReference = reference;
      _labels = [
        for (final mark in _vuMarks)
          if (_vuLabelled.contains(mark))
            layoutParagraph(
              mark == 0
                  ? '0'
                  : (mark > 0 ? '+${mark.toInt()}' : '${mark.toInt()}'),
              // 0 VU is what the whole face is aimed at, so it is the one
              // number on it drawn like a reading rather than like a
              // graticule. Above it is over; below it recedes.
              OaaType.tick.copyWith(
                color: mark > 0
                    ? colors.over
                    : mark == 0
                    ? colors.textPrimary
                    : colors.textFaint,
                fontWeight: mark == 0 ? FontWeight.w500 : null,
              ),
            )
          else
            layoutParagraph('', OaaType.tick),
      ];
      // The face's end signs: what a real VU face prints past its last marks.
      // The minus end recedes like the scale under it; the plus end is the red
      // family's, like everything past 0.
      _minus = layoutParagraph(
        '−',
        OaaType.label.copyWith(color: colors.accent),
      );
      _plus = layoutParagraph('+', OaaType.label.copyWith(color: colors.over));
      _template = layoutParagraph(
        _readingTemplate,
        OaaType.readingSmall.copyWith(color: colors.textPrimary),
      );
      _reference = layoutParagraph(
        '0 VU = ${_dbfs(reference)} dBFS',
        OaaType.tick.copyWith(color: colors.textFaint),
      );
      _referenceShort = layoutParagraph(
        '${_dbfs(reference)} dBFS',
        OaaType.tick.copyWith(color: colors.textFaint),
      );

      var widest = 0.0;
      var tallest = 0.0;
      for (final label in _labels) {
        if (label.longestLine <= 0) continue;
        if (label.longestLine > widest) widest = label.longestLine;
        if (label.height > tallest) tallest = label.height;
      }
      _labelAbove = tallest;
      _labelBeside =
          math.sqrt(widest * widest + tallest * tallest) / 2 + widest / 2;

      _rowHeight = math.max(_template!.height, _reference!.height);
      _rowBaseline = math.max(
        _template!.alphabeticBaseline,
        _reference!.alphabeticBaseline,
      );
      // The readout box's width: the widest reading plus its padding. No unit
      // inside the box — the face is the unit.
      _readingWidth = _template!.longestLine + Space.sm * 2;
    }

    return MeterBody(
      painter: _VuPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

/// A dBFS level as the bottom row prints it: whole where it is whole, which
/// every delivery convention's reference level is.
String _dbfs(double dbfs) {
  final whole = dbfs.roundToDouble();
  return (dbfs - whole).abs() < 0.05
      ? whole.toInt().toString()
      : dbfs.toStringAsFixed(1);
}

class _VuPainter extends MeterPainter {
  _VuPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _redZone = (Paint()
         ..color = colors.over.withValues(alpha: 0.12)
         ..style = PaintingStyle.stroke),
       _band = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke),
       _bandOver = (Paint()
         ..color = colors.over
         ..style = PaintingStyle.stroke),
       _mark = (Paint()
         ..color = colors.textFaint
         ..strokeWidth = OaaStroke.hairline),
       _markOver = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark),
       _markZero = (Paint()
         ..color = colors.textPrimary
         ..strokeWidth = OaaStroke.emphasis),
       _peak = (Paint()
         ..color = colors.textPrimary
         ..strokeWidth = OaaStroke.mark),
       // The instrument's own fill colour, not a text colour: the needle is
       // the reading, and it should be the same voice as every other meter's
       // fill — a white needle was the brightest thing on the module and
       // outshone the number it pointed at.
       _needle = (Paint()..color = colors.meterFill),
       _lampOn = (Paint()..color = colors.over),
       _lampIdle = (Paint()..color = colors.hairline),
       _readoutFill = (Paint()..color = colors.panelRaised),
       _readoutBorder = (Paint()
         ..color = colors.hairline
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final _VuMeterModuleState state;

  final Paint _redZone;
  final Paint _band;
  final Paint _bandOver;
  final Paint _mark;
  final Paint _markOver;
  final Paint _markZero;
  final Paint _peak;
  final Paint _needle;
  final Paint _lampOn;
  final Paint _lampIdle;
  final Paint _readoutFill;
  final Paint _readoutBorder;

  /// The needle, as a taper.
  ///
  /// Built once with the painter — which is rebuilt on a skin change and not on
  /// a frame — and reset and refilled from there, because **nothing on the
  /// frame path may allocate** and a taper is the one thing here that cannot be
  /// drawn without a `Path`. The same bargain `_swept` makes in the super
  /// meter.
  final Path _pointer = Path();

  /// Where the scale labels have been put this frame, so the next one can be
  /// asked whether it fits. Held for the same reason as [_pointer]: the frame
  /// path may not allocate, and this is filled and refilled rather than built.
  /// Two extra slots for the `−` and `+` end signs, which take part in the
  /// same collision order.
  final List<Rect> _boxes = List<Rect>.filled(
    _vuLabelled.length + 2,
    Rect.zero,
  );

  /// How far the sweep may open, either side of vertical.
  ///
  /// Not a constant, because the module is not a constant shape. A VU tile is
  /// resized in width far more often than in height, and a face laid out for
  /// one aspect ratio leaves a third of the other empty — which is precisely
  /// what this module did: a 35° sweep in a 2:1 tile drew its ink across the
  /// middle half of the width and left the rest bare with the badge adrift in
  /// it. The sweep now opens until the face fills the box, between two bounds
  /// that both come from looking at it: under 35° the eleven marks collide,
  /// and over 55° it stops reading as a VU and starts reading as a speedometer.
  static const double _minHalfSweep = 35 * math.pi / 180;
  static const double _maxHalfSweep = 55 * math.pi / 180;

  /// Ends of the scale, in VU. The face crowds towards the bottom end because
  /// deflection is linear in voltage.
  static const double _minVu = -20;
  static const double _maxVu = 3;

  /// The gap between the arc and the near edge of a scale label.
  static const double _labelGap = Space.xs;

  /// How far past the last marks the `−` and `+` end signs stand, in radians.
  static const double _endSignLead = 0.12;

  /// The peak lamp's radius.
  static const double _lampRadius = 4;

  /// The pivot hub, as a fraction of the face radius.
  static const double _capShare = 0.045;

  /// The scale band's width, as a fraction of the face radius, and the floor
  /// and ceiling it is held between.
  ///
  /// Proportional so the dial scales as one object, bounded so that a meter in
  /// a two-cell tile still has a band rather than a hairline and a meter across
  /// half the canvas does not get a stripe.
  static const double _bandShare = 0.05;
  static const double _bandMin = 2.5;
  static const double _bandMax = 9;

  /// The most of the module's height the bottom row may take before it is
  /// dropped in favour of the dial.
  static const double _rowShare = 0.28;

  /// How far down the tile the dial is pushed, as a fraction of its height and
  /// never more than [Space.md]. Proportional so a small module gives up a
  /// couple of pixels rather than a fifth of its radius.
  static const double _dropShare = 0.08;

  /// Tick lengths, inward from the band, as fractions of the face radius.
  static const double _majorShare = 0.085;
  static const double _minorShare = 0.05;

  @override
  void paint(Canvas canvas, Size size) {
    // --- Geometry -----------------------------------------------------------
    // Solved rather than assumed. `face` is the rim's radius; everything else
    // is expressed against it, so the whole dial scales as one object and the
    // ink is centred in the tile instead of pinned to a corner of it.
    // No inset of its own: `ModuleFrame` already gives every module the same
    // margin on all four sides, and a painter that adds a second one is a
    // module that sits differently from the other thirteen.
    final availW = size.width;
    final availH = size.height;

    final above = _labelGap + state._labelAbove;
    final beside = _labelGap + state._labelBeside;

    // The bottom row is dropped rather than crushed when the tile cannot hold
    // it, and the room it would have taken goes back to the dial. The frame's
    // own title still says which meter this is.
    //
    // Height as well as width, because at the kind's own floor — 80 by 50 —
    // the row is a fifth of the module and the dial it leaves behind has a
    // radius of eleven pixels: a smudge with a footer. A row that has taken
    // more than [_rowShare] of the module has stopped being a caption.
    final row =
        availW >= state._readingWidth &&
            state._rowHeight + Space.sm <= availH * _rowShare
        ? state._rowHeight + Space.sm
        : 0.0;
    final showRow = row > 0;

    // Breathing room over the top of the scale, taken off the dial rather than
    // found in slack — a tile whose height binds has none, which is most of
    // them. Without it the topmost scale number sits a few pixels under the
    // frame's title rule while the hub has the bottom row under it, and the
    // whole instrument reads as having been pushed up against the ceiling.
    final drop = math.min(Space.md, availH * _dropShare);

    final vertical = availH - above - row - drop;
    final horizontal = availW / 2 - beside;
    if (vertical <= 0 || horizontal <= 0) return;

    // Pick the sweep that makes width and height bind at the same radius, then
    // clamp it into the readable range.
    final halfSweep = math
        .asin(
          ((1 + _capShare) * horizontal / vertical).clamp(
            math.sin(_minHalfSweep),
            math.sin(_maxHalfSweep),
          ),
        )
        .toDouble();
    final sinHalf = math.sin(halfSweep);

    final face = math.min(vertical / (1 + _capShare), horizontal / sinHalf);
    if (face <= 0) return;

    final cap = face * _capShare;

    // The row sits on the bottom edge and the dial is centred in what is left
    // of the tile, rather than the two being centred together as one block.
    // Centred together, a tile taller than the dial's own aspect left the row
    // floating in the middle of the lower half with a band of empty face under
    // it — a footer that had come away from the bottom of the instrument.
    final dial = face * (1 + _capShare) + above;
    final pivot = Offset(
      size.width / 2,
      drop + (availH - row - drop - dial) / 2 + face + above,
    );

    final zero = -math.pi / 2; // straight up
    final from = zero - halfSweep;
    final to = zero + halfSweep;
    final overStart = zero + _angleOf(0, halfSweep);

    final bandWidth = (face * _bandShare).clamp(_bandMin, _bandMax).toDouble();
    final rim = face - bandWidth; // the band's inner edge
    final bandBounds = Rect.fromCircle(
      center: pivot,
      radius: face - bandWidth / 2,
    );

    // --- The red zone -------------------------------------------------------
    // A ring under the rim rather than a sector: deep enough to take in the
    // band and the ticks that belong to it, and no deeper. A sector reaching
    // all the way to the pivot is a red pie slice, and it reads as a filled
    // reading rather than as a region of the scale.
    final zone = bandWidth + face * _majorShare * 1.3;
    _redZone.strokeWidth = zone;
    canvas.drawArc(
      Rect.fromCircle(center: pivot, radius: face - zone / 2),
      overStart,
      to - overStart,
      false,
      _redZone,
    );

    // --- The rim, in two pieces so "over" is part of the face ---------------
    _band.strokeWidth = bandWidth;
    _bandOver.strokeWidth = bandWidth;
    canvas.drawArc(bandBounds, from, overStart - from, false, _band);
    canvas.drawArc(bandBounds, overStart, to - overStart, false, _bandOver);

    // --- Marks --------------------------------------------------------------
    // Ticks run inward from the rim, onto the face where they have the whole
    // depth of the body to be read against.
    for (var i = 0; i < _vuMarks.length; i++) {
      final vu = _vuMarks[i];
      final angle = zero + _angleOf(vu, halfSweep);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final long = _vuLabelled.contains(vu);

      canvas.drawLine(
        pivot + direction * rim,
        pivot + direction * (rim - face * (long ? _majorShare : _minorShare)),
        vu > 0
            ? _markOver
            : vu == 0
            ? _markZero
            : _mark,
      );
    }

    // --- Labels -------------------------------------------------------------
    // Outside the rim. Inside, they are in the needle's sweep — at rest the
    // needle lay along the −20 mark and struck its own label through, and no
    // reading on the lower half of the face could be read without the needle
    // across it.
    //
    // Placed in the order they can be given up rather than left to right,
    // because on a small tile there is not room for all six: the scale crowds
    // towards −20 in *voltage*, so at a two-cell width `−5` and `−3` land on
    // top of each other and print as `−5−3`. Each one is drawn only if its box
    // clears every box already placed, so the face sheds the numbers nobody
    // would miss and keeps the ends and the reference.
    var placed = 0;
    for (final vu in _labelOrder) {
      final label = state._labels[_vuMarks.indexOf(vu)];
      if (label.longestLine <= 0) continue;
      final angle = zero + _angleOf(vu, halfSweep);
      final direction = Offset(math.cos(angle), math.sin(angle));

      // How far the label's own box extends along the radius it sits on. Push
      // the centre out by exactly that and every near edge lands on one
      // circle, whatever the angle — which is the difference between six
      // labels on a scale and six labels scattered near one.
      final half = Offset(label.longestLine / 2, label.height / 2);
      final extent =
          half.dx * direction.dx.abs() + half.dy * direction.dy.abs();
      final at = pivot + direction * (face + _labelGap + extent);
      final box = Rect.fromCenter(
        center: at,
        width: label.longestLine + Space.xs,
        height: label.height,
      );

      var clear = true;
      for (var i = 0; i < placed; i++) {
        if (_boxes[i].overlaps(box)) {
          clear = false;
          break;
        }
      }
      if (!clear) continue;
      _boxes[placed++] = box;
      canvas.drawParagraph(label, at - half);
    }

    // --- The end signs -------------------------------------------------------
    // `−` and `+` just past the last marks, the way the standard face prints
    // them: not values, but which way the scale runs — worth having exactly
    // because the labels between them are the first things a small tile sheds.
    for (final (side, sign) in [(-1, state._minus!), (1, state._plus!)]) {
      final angle = zero + side * (halfSweep + _endSignLead);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final half = Offset(sign.longestLine / 2, sign.height / 2);
      final extent =
          half.dx * direction.dx.abs() + half.dy * direction.dy.abs();
      final at = pivot + direction * (face + _labelGap + extent);
      final box = Rect.fromCenter(
        center: at,
        width: sign.longestLine + Space.xs,
        height: sign.height,
      );
      var clear = true;
      for (var i = 0; i < placed; i++) {
        if (_boxes[i].overlaps(box)) {
          clear = false;
          break;
        }
      }
      if (!clear) continue;
      _boxes[placed++] = box;
      canvas.drawParagraph(sign, at - half);
    }

    // --- The reading --------------------------------------------------------
    // The loudest channel. A stereo pair on one movement is what a mono VU
    // does, and showing the quieter of the two would understate the programme.
    //
    // NaN is not a level: a channel the engine does not measure — or one whose
    // link to a remote display has gone quiet, which is what fills these
    // arrays with NaN — leaves the face with no needle at all rather than one
    // resting confidently at the bottom of its scale.
    var loudest = double.nan;
    final channels = engine.channels.clamp(1, MeterShape.maxChannels);
    for (var c = 0; c < channels; c++) {
      final level = engine.vu[c];
      if (level.isNaN) continue;
      if (loudest.isNaN || level > loudest) loudest = level;
    }

    final vu = loudest - calibration.vuReference;

    if (engine.generation != state._seenGeneration) {
      state._advance(engine, vu);
      state._seenGeneration = engine.generation;
    }

    // --- The peak mark ------------------------------------------------------
    // On the rim, which is the only ink there, so it cannot be mistaken for a
    // graticule tick — those are all inside it.
    final peak = state._peak;
    if (!peak.isNaN && peak > _minVu) {
      final angle = zero + _angleOf(peak, halfSweep);
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        pivot + direction * (rim - bandWidth * 0.3),
        pivot + direction * (face + bandWidth * 0.3),
        _peak,
      );
    }

    // --- The needle ---------------------------------------------------------
    if (!vu.isNaN) {
      final angle = zero + _angleOf(vu, halfSweep);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final across = Offset(-direction.dy, direction.dx);

      // A taper, not a line. From the pivot outwards and no further back: the
      // needle used to start a little behind its own centre — a counterweight
      // a real movement has and a drawing of one does not need — and the tail
      // was longer than the cap meant to hide it, so a second short needle
      // stuck out of the bottom of the pivot pointing the opposite way.
      //
      // Wide enough at the root that the taper is still visible *outside* the
      // readout box, which covers everything around the pivot. Sized against
      // [cap] — the old hub's radius, kept as the measure of "near the pivot"
      // — rather than against the radius.
      final root = across * math.max(OaaStroke.emphasis, cap * 0.7);
      final tipHalf = across * math.max(OaaStroke.hairline * 0.6, face * 0.004);
      final tip = pivot + direction * (rim + bandWidth * 0.65);
      _pointer.reset();
      _pointer.moveTo(pivot.dx + root.dx, pivot.dy + root.dy);
      _pointer.lineTo(tip.dx + tipHalf.dx, tip.dy + tipHalf.dy);
      _pointer.lineTo(tip.dx - tipHalf.dx, tip.dy - tipHalf.dy);
      _pointer.lineTo(pivot.dx - root.dx, pivot.dy - root.dy);
      _pointer.close();
      canvas.drawPath(_pointer, _needle);
    }

    // --- The peak lamp -------------------------------------------------------
    // Beside the dial where a real face carries one, lit while the held peak
    // stands over 0 VU — the same hold the mark on the rim draws, so the two
    // can never disagree about whether the programme has been in the red.
    // Skipped when the tile leaves it no clear margin: a lamp on top of the
    // scale labels is furniture, not a signal.
    final lampX = availW - Space.xs - _lampRadius;
    if (lampX - _lampRadius >=
        pivot.dx + face * sinHalf + _labelGap + state._labelBeside) {
      canvas.drawCircle(
        Offset(lampX, pivot.dy - face * 0.5),
        _lampRadius,
        state._peak > 0 ? _lampOn : _lampIdle,
      );
    }

    // --- The readout box -----------------------------------------------------
    // Over the pivot, where a real movement has its hub: the number is the
    // meter's own statement of where the needle is, and the needle vanishing
    // behind it is what a pivot looks like when the pivot is a reading.
    if (!showRow) return;

    final boxHeight = state._rowHeight + Space.xs * 2;
    final box = Rect.fromCenter(
      center: Offset(pivot.dx, pivot.dy + boxHeight * 0.25),
      width: state._readingWidth,
      height: boxHeight,
    );
    final rounded = RRect.fromRectAndRadius(box, OaaRadius.sm);
    canvas.drawRRect(rounded, _readoutFill);
    canvas.drawRRect(rounded, _readoutBorder);

    final reading = state._reading.of(
      _readingText(vu),
      OaaType.readingSmall.copyWith(
        color: vu.isNaN
            ? colors.textMuted
            : vu > 0
            ? colors.over
            : colors.textPrimary,
      ),
    );
    canvas.drawParagraph(
      reading,
      Offset(
        box.center.dx - reading.longestLine / 2,
        box.center.dy - reading.height / 2,
      ),
    );

    // What 0 VU actually means, if there is room for it. The long form first,
    // then the level on its own, then nothing — a reference level printed half
    // way across the face is worse than an unlabelled one. Bottom-right, and
    // it yields to the readout box when the tile is too small to hold both
    // apart.
    final top = availH - state._rowHeight;
    final clearOfBox = top >= box.bottom + Space.xxs;
    final noteRoom = clearOfBox ? availW : availW - box.right - Space.sm;
    final long = state._reference!;
    final short = state._referenceShort!;
    final note = noteRoom >= long.longestLine
        ? long
        : noteRoom >= short.longestLine
        ? short
        : null;
    if (note == null) return;
    canvas.drawParagraph(
      note,
      Offset(
        availW - note.longestLine,
        top + state._rowBaseline - note.alphabeticBaseline,
      ),
    );
  }

  /// The reading, as the bottom row prints it.
  ///
  /// Below the face's floor it says so rather than printing −20.0, which would
  /// be a reading the needle is resting against and not one the programme made,
  /// and rather than printing the true −126 VU of digital silence, which is a
  /// number no VU meter has ever had an opinion about. Above the top it prints
  /// the real figure: how far over you are is the reason to look.
  String _readingText(double vu) {
    if (vu.isNaN) return '—';
    if (vu < _minVu) return '<${_minVu.toInt()}';
    var text = vu.toStringAsFixed(1);
    if (text == '-0.0') text = '0.0';
    return vu > 0 ? '+$text' : text;
  }

  /// Where a VU reading sits on the face, as an angle either side of vertical.
  ///
  /// Linear in voltage, not in decibels: a VU movement is a rectifier driving a
  /// meter whose deflection is proportional to current, so the *amplitude* is
  /// what maps evenly onto the arc. Spacing the marks evenly in dB instead is
  /// the usual mistake and produces a face that looks right and reads wrong
  /// everywhere except at its two ends.
  double _angleOf(double vu, double halfSweep) {
    final clamped = vu.isNaN ? _minVu : vu.clamp(_minVu, _maxVu);
    final fraction = (_voltage(clamped) - _lowVoltage) / _voltageSpan;
    return (fraction * 2 - 1) * halfSweep;
  }

  static double _voltage(double vu) => math.pow(10, vu / 20).toDouble();

  /// Hoisted off the frame path: the two ends of the scale never move, and
  /// recomputing them cost twenty-four `pow` calls a frame.
  static final double _lowVoltage = _voltage(_minVu);
  static final double _voltageSpan = _voltage(_maxVu) - _voltage(_minVu);

  @override
  bool shouldRepaint(_VuPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
