// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Momentary, short-term and integrated loudness as three bars on one scale.
///
/// Three bars rather than three numbers, because the only question anybody has
/// while mixing is how they relate: momentary swinging far above integrated is
/// a mix that will be turned down, and you can see that in one glance here and
/// in no arrangement of three separate figures. The figures are printed under
/// the bars anyway — a bar answers "roughly where", a delivery conversation
/// needs "exactly what".
///
/// Integrated is a bar like the other two, not a line across them: it is the
/// number that gets delivered, and it earns the same presence as the readings
/// that are chasing it. Which bar is which is written up the bar itself —
/// MOMENTARY, SHORT, INTEGRATED — because a bar tall enough to read is tall
/// enough to label, and single letters under the bars only survive as the
/// fallback for a module too small to carry the words.
///
/// The target band comes from the active calibration and is the reason the
/// meter is worth looking at rather than the numbers underneath it. The line
/// through it is dashed, in [OaaColors.over], with the target value printed on
/// the axis in the same colour — a line at −14 LUFS with a ±0.5 LU band around
/// it turns "what is my loudness" into "am I there yet", which is the question
/// that actually gets asked.
class LufsMeterModule extends StatefulWidget {
  const LufsMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<LufsMeterModule> createState() => _LufsMeterModuleState();
}

class _LufsMeterModuleState extends State<LufsMeterModule> {
  /// Ticks crowded at the top where broadcast at −23 and streaming at −14 are
  /// read, −∞ at the floor. The taper is [MeterScale.tapered]'s and shared
  /// with every other level scale.
  static const _scale = MeterScale.tapered(
    max: 0,
    ticks: [0, -3, -6, -9, -12, -18, -24, -30, -40],
  );

  ScaleGraticule? _graticule;
  final _momentary = ValueParagraph();
  final _short = ValueParagraph();
  final _integrated = ValueParagraph();
  final _target = ValueParagraph();
  List<ui.Paragraph> _names = const [];
  List<ui.Paragraph> _letters = const [];

  @override
  void dispose() {
    _graticule?.dispose();
    _momentary.dispose();
    _short.dispose();
    _integrated.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    // Rebuilt only when the palette or the target changes, never per frame:
    // these hold laid-out paragraphs, and throwing them away every rebuild
    // would defeat the point of caching them.
    if (_graticule == null ||
        !_graticule!.matches(
          _scale,
          ScaleSide.both,
          colors.textFaint,
          avoiding: widget.calibration.lufsTarget,
        )) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.both,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
        avoid: widget.calibration.lufsTarget,
      );

      // **Left-aligned, and centred by measuring.** These asked for
      // `TextAlign.center` once and were not drawn at all: an unconstrained
      // paragraph is laid out a megapixel wide, and centre alignment then puts
      // the glyph half a million pixels along a line whose origin is the offset
      // it is drawn at. See `layoutParagraph`.
      final nameStyle = OaaType.label.copyWith(color: colors.textPrimary);
      final letterStyle = OaaType.label.copyWith(color: colors.textFaint);
      _names = [
        layoutParagraph('MOMENTARY', nameStyle),
        layoutParagraph('SHORT', nameStyle),
        layoutParagraph('INTEGRATED', nameStyle),
      ];
      _letters = [
        layoutParagraph('M', letterStyle),
        layoutParagraph('S', letterStyle),
        layoutParagraph('I', letterStyle),
      ];
    }

    return MeterBody(
      painter: _LufsMeterPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        graticule: _graticule!,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _LufsMeterPainter extends MeterPainter {
  _LufsMeterPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _track = (Paint()..color = colors.meterTrack),
       // The part of a bar that stands above the target, in [OaaColors.over] —
       // the application's one mark for "past the number you set".
       _over = (Paint()..color = colors.over),
       _targetBand = (Paint()
         ..color = colors.textFaint.withValues(alpha: 0.18)),
       _targetDash = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark
         ..isAntiAlias = false),
       _targetStyle = OaaType.tick.copyWith(color: colors.over),
       _valueStyle = OaaType.readingSmall.copyWith(color: colors.textPrimary),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final _LufsMeterModuleState state;

  final Paint _track;
  final Paint _over;
  final Paint _targetBand;
  final Paint _targetDash;
  final MeterFill _fill = MeterFill();

  final TextStyle _targetStyle;
  final TextStyle _valueStyle;

  /// The dashed target line, rebuilt only when the geometry moves.
  Float32List _dashes = Float32List(0);
  Rect _dashesFor = Rect.zero;
  double _dashesY = double.nan;

  /// Below this there is no room for the readouts and the bars keep the space.
  static const double _minimumHeight = 60;

  /// The same judgement as [_minimumHeight], in the other axis: under this a
  /// reading is chrome rather than a number, and the bars keep the space.
  /// The graticule's own ticks are 10, so 10 is still a number that can be
  /// read — and the default five-cell module fits its three readings at
  /// fractionally under 11, which is why 11 was the wrong floor: it hid the
  /// numbers on exactly the size the module ships at.
  static const double _minimumValueSize = 10;

  /// Advance of one glyph of [OaaType.reading], in ems. Google Sans Code is 0.6
  /// and the style tightens it by half a pixel; the slack is what keeps this an
  /// upper bound rather than a measurement.
  static const double _advance = 0.62;

  /// The reading is fitted to at least this many glyphs — the width of
  /// `-17.6` — whatever it currently prints.
  ///
  /// Fitting the string that is actually on screen would resize the whole row
  /// the moment a reading crossed −10 and gained a digit. Tabular figures
  /// exist so a readout does not move while you watch it; a face that changes
  /// size at a threshold undoes that far more visibly than proportional digits
  /// ever did.
  static const int _minimumGlyphs = 5;

  static const double _dashOn = 4;
  static const double _dashOff = 4;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = Space.xs;

    final momentary = engine.lufsMomentary;
    final short = engine.lufsShort;
    final integrated = engine.lufsIntegrated;
    final momentaryText = Metric.lufsMomentary.format(momentary);
    final shortText = Metric.lufsShort.format(short);
    final integratedText = Metric.lufsIntegrated.format(integrated);

    // The target's own number is wider than the tick labels — "-14.0" against
    // "-40" — so the left gutter grows to hold it whole. Laid out inside the
    // graticule's gutter it was silently cropped to "-14", which is not a
    // shortened label but a different number.
    final targetLabel = state._target.of(
      calibration.lufsTarget.toStringAsFixed(1),
      _targetStyle,
    );
    final leftInset = math.max(
      graticule.gutter,
      targetLabel.longestLine + Space.xs,
    );

    final barWidth = (size.width - leftInset - graticule.gutter - gap * 2) / 3;

    // **The readouts scale with the module, like the bars above them.** Sized
    // off the height alone, a tall narrow meter asks for a reading in a column
    // that cannot hold it — and a paragraph laid out at `maxLines: 1` does not
    // complain, it simply stops drawing where it runs out of room. `-17.6` was
    // once rendered as `-17.`, which is not a clipped number but a *different*
    // one. Every glyph of a reading is a digit, a minus or a point and the
    // face is monospaced, so the width that fits is arithmetic — no trial
    // layout on the frame path.
    final glyphs = math.max(
      _minimumGlyphs,
      math.max(
        momentaryText.length,
        math.max(shortText.length, integratedText.length),
      ),
    );
    // Fitted to the bar's *pitch*, not its width: the numbers are centred on
    // their bars and the gaps between bars are theirs to borrow, which is what
    // keeps them legible on a narrow module. Fitted to the bar alone, a
    // five-cell meter put the readings under the 11 px floor and drew none.
    final valueSize = math
        .min(
          size.height * 0.09,
          (barWidth + gap - Space.xs) / (glyphs * _advance),
        )
        .clamp(0.0, 40.0)
        .toDouble();
    final readoutHeight = valueSize * 1.3 + Space.xs;
    final showReadouts =
        valueSize >= _minimumValueSize &&
        size.height > _minimumHeight + readoutHeight;

    // The bar names run up the bars; the single letters under them are the
    // fallback for a module too small to carry the words, and only that
    // fallback costs a band of height.
    final namesFit =
        barWidth >= state._names[0].height + Space.xs &&
        size.height * 0.6 >= state._names[2].longestLine + Space.sm * 2;
    final letterHeight = namesFit ? 0.0 : OaaType.label.fontSize! + Space.xs;

    final track = Rect.fromLTRB(
      leftInset,
      0,
      size.width - graticule.gutter,
      size.height - letterHeight - (showReadouts ? readoutHeight : 0),
    );
    if (track.height < 24 || track.width < 24) return;

    _fill.prepare(track.height, colors);

    // **A trough per bar, not one rectangle behind all three.** Painted as a
    // single background, the gap between two bars is the same colour as the
    // empty part of either, so the bars only separate where their fills stop —
    // and when they read alike, which is most of the time on steady programme,
    // they merge into one block. The gap has to show the module behind it to
    // be a gap.
    for (var bar = 0; bar < 3; bar++) {
      final left = track.left + bar * (barWidth + gap);
      canvas.drawRect(
        Rect.fromLTRB(left, track.top, left + barWidth, track.bottom),
        _track,
      );
    }

    // Over the troughs and under everything else: the scale belongs to the
    // meter as a whole, so it crosses the gaps the way the target rule does.
    graticule.paint(canvas, track);

    // --- Target band --------------------------------------------------------
    // A band rather than a line alone, because every delivery spec states a
    // tolerance and a target drawn as a hairline is a pass/fail on an
    // infinitely thin edge that no real programme lands on.
    final targetTop = _y(
      track,
      calibration.lufsTarget + calibration.lufsTolerance,
    );
    final targetBottom = _y(
      track,
      calibration.lufsTarget - calibration.lufsTolerance,
    );
    canvas.drawRect(
      Rect.fromLTRB(track.left, targetTop, track.right, targetBottom),
      _targetBand,
    );

    // --- Bars ---------------------------------------------------------------
    // **Split at the target line, not coloured by a verdict on the whole
    // bar.** A momentary reading standing over the target is not a delivery
    // failure and must not be painted as though something had classified it as
    // one — what carries the meaning is *how much* of the bar is above the
    // line, which is the same reading the Histogram and the Loudness
    // Distribution offer as an area.
    final targetY = _y(track, calibration.lufsTarget);
    final values = [momentary, short, integrated];
    for (var bar = 0; bar < 3; bar++) {
      final value = values[bar];
      if (value.isNaN) continue;
      final left = track.left + bar * (barWidth + gap);
      final top = _y(track, value);
      if (top >= track.bottom) continue;
      _fill.draw(
        canvas,
        Rect.fromLTRB(left, top, left + barWidth, track.bottom),
      );
      final split = targetY.clamp(track.top, track.bottom).toDouble();
      if (top < split) {
        canvas.drawRect(
          Rect.fromLTRB(left, top, left + barWidth, split),
          _over,
        );
      }
    }

    // --- The target line, over the bars, and its value on the axis ----------
    // Dashed where every other rule here is solid, so the one line that is a
    // decision rather than a measurement cannot be mistaken for a reading.
    if (_dashesFor != track || _dashesY != targetY) {
      final count = ((track.width) / (_dashOn + _dashOff)).ceil();
      _dashes = Float32List(count * 4);
      var i = 0;
      for (var d = 0; d < count; d++) {
        final x = track.left + d * (_dashOn + _dashOff);
        _dashes[i++] = x;
        _dashes[i++] = targetY;
        _dashes[i++] = math.min(x + _dashOn, track.right);
        _dashes[i++] = targetY;
      }
      _dashesFor = track;
      _dashesY = targetY;
    }
    canvas.drawRawPoints(ui.PointMode.lines, _dashes, _targetDash);

    canvas.drawParagraph(
      targetLabel,
      Offset(
        track.left - Space.xs - targetLabel.longestLine,
        targetY - targetLabel.height / 2,
      ),
    );

    // --- Names, up the bars — or letters under them --------------------------
    for (var bar = 0; bar < 3; bar++) {
      final left = track.left + bar * (barWidth + gap);
      if (namesFit) {
        final name = state._names[bar];
        canvas.save();
        canvas.translate(
          left + (barWidth - name.height) / 2,
          track.bottom - Space.sm,
        );
        canvas.rotate(-math.pi / 2);
        canvas.drawParagraph(name, Offset.zero);
        canvas.restore();
      } else {
        final letter = state._letters[bar];
        canvas.drawParagraph(
          letter,
          Offset(
            left + (barWidth - letter.longestLine) / 2,
            track.bottom + Space.xxs,
          ),
        );
      }
    }

    if (!showReadouts) return;

    // --- The numbers ---------------------------------------------------------
    // One under each bar, centred on it. Momentary and short-term are
    // readings; integrated is the number that gets delivered, and it alone is
    // coloured by where it stands against the target — the same convention as
    // every readout in the application.
    final readoutTop = size.height - readoutHeight + Space.xs;
    final readouts = [state._momentary, state._short, state._integrated];
    final texts = [momentaryText, shortText, integratedText];
    for (var bar = 0; bar < 3; bar++) {
      final style = bar == 2
          ? OaaType.reading(valueSize).copyWith(
              color: colorForState(
                classify(Metric.lufsIntegrated, integrated, calibration),
                colors,
              ),
            )
          : OaaType.reading(valueSize).copyWith(color: _valueStyle.color);
      final paragraph = readouts[bar].of(texts[bar], style);
      final left = track.left + bar * (barWidth + gap);
      canvas.drawParagraph(
        paragraph,
        Offset(left + (barWidth - paragraph.longestLine) / 2, readoutTop),
      );
    }
  }

  double _y(Rect track, double value) =>
      track.bottom - graticule.scale.fractionOf(value) * track.height;

  @override
  bool shouldRepaint(_LufsMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
