// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Sample peak and RMS, per channel, up to 7.1 — as bars and as numbers.
///
/// Two quantities per channel on one bar rather than two bars: the RMS is the
/// filled column and the peak is a floating tick above it, so the gap between
/// them *is* the crest factor and you read it without doing arithmetic. Two
/// separate bars show the same numbers and hide the relationship between them,
/// which is the only reason to show both at once.
///
/// The same two quantities are printed above the bars, one column per channel,
/// because a bar answers "roughly where" and a delivery conversation needs
/// "exactly what" — and walking a cursor over a meter to find out what it says
/// is the tell of a display that only half-committed to being read.
///
/// The peak mark carries the warning that used to be a painted region: its
/// colour runs from the fill's own colour at low level to [OaaColors.over] as
/// the peak closes on full scale, so a hot channel announces itself by the one
/// mark that is actually hot rather than by a stripe of scale that is hot on
/// every channel all the time.
///
/// The bars are drawn as segments — lit rows with the panel showing through
/// between them — because a segmented column reads as *level* while a solid
/// one reads as *area*. **A row is lit or it is not.** The fill stops at the
/// top of the last row it covers completely, and the peak is one whole row
/// rather than a hairline laid across whichever row the reading falls in.
/// The segmentation was cosmetic through 0.14 — the fill's top edge was the
/// measurement — and a segmented meter whose top row is a sliver is a meter
/// with two segment heights in it: the tip of the bar carries less light than
/// every row under it, which reads as the ink dimming rather than as a level,
/// and the peak's hairline sat across a gap as often as on a row. The column's
/// resolution is now one row, and the numbers printed above it are the
/// measurement itself, rounded by nothing.
///
/// The fill is [OaaColors.meterAccent] under [MeterFill]'s gradient, as on
/// the LUFS meter and the Super Meter's arcs — the reading's colour, over a
/// grey track. It was the grey [OaaColors.meterFill] through 0.14, and a bar
/// the colour of its own track read as a level you had to look for.
class DigitalMeterModule extends StatefulWidget {
  const DigitalMeterModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<DigitalMeterModule> createState() => _DigitalMeterModuleState();
}

class _DigitalMeterModuleState extends State<DigitalMeterModule> {
  /// Full scale down to −60 labelled, and −∞ at the floor. The ticks crowd the
  /// top because that is where a digital meter is read; the taper is
  /// [MeterScale.tapered]'s and shared with every other level scale.
  static const _scale = MeterScale.tapered(
    max: 0,
    ticks: [0, -3, -6, -12, -18, -24, -30, -40, -60],
  );

  ScaleGraticule? _graticule;
  List<ui.Paragraph> _channelLabels = const [];
  int _labelledChannels = 0;

  @override
  void dispose() {
    _graticule?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final channels = widget.engine.channels.clamp(1, MeterShape.maxChannels);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.both, colors.textFaint) ||
        _labelledChannels != channels) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.both,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = OaaType.label.copyWith(color: colors.textFaint);
      _channelLabels = [
        for (var c = 0; c < channels; c++)
          layoutParagraph(_channelName(c, channels), style),
      ];
      _labelledChannels = channels;
    }

    return MeterBody(
      painter: _DigitalMeterPainter(
        engine: widget.engine,
        colors: colors,
        graticule: _graticule!,
        labels: _channelLabels,
        repaint: widget.clock,
      ),
    );
  }
}

/// Named only where the name is unambiguous.
///
/// Stereo is L/R and mono is M; anything wider is numbered, because the engine
/// infers a layout from the channel count and calling channel 3 "C" when the
/// interface was actually wired as quad would be a label that lies. Real layout
/// metadata arrives with the file and device work.
String _channelName(int channel, int channels) {
  if (channels == 1) return 'M';
  if (channels == 2) return channel == 0 ? 'L' : 'R';
  return '${channel + 1}';
}

class _DigitalMeterPainter extends MeterPainter {
  _DigitalMeterPainter({
    required this.engine,
    required this.colors,
    required this.graticule,
    required this.labels,
    required Listenable repaint,
  }) : _track = (Paint()..color = colors.meterTrack),
       // Taken once: `meterAccent` is derived, and `paint` allocates nothing.
       _ink = colors.meterAccent,
       _peakMark = (Paint()..color = colors.meterFill),
       _segmentGap = (Paint()
         ..color = colors.panel
         ..strokeWidth = _gapHeight
         ..isAntiAlias = false),
       // A scale row is a *lighter* gap: the graticule's own line colour, in
       // the row the graticule's line was snapped to.
       _scaleRule = (Paint()
         ..color = colors.hairline
         ..strokeWidth = _gapHeight
         ..isAntiAlias = false),
       _clip = (Paint()..color = colors.over),
       _clipIdle = (Paint()..color = colors.hairline),
       // The readings, in the signal hue every module prints a number in.
       // See `colorForState`: a value is the accent, and what is wrong with
       // one is amber, red or a muted dash.
       //
       // Both faces, built once per palette rather than per reading: this
       // module prints two numbers per channel and the styles are otherwise
       // fixed, so a `copyWith` per value would be sixteen allocations a frame
       // on a surround source. See [inkForReading] for why the dash needs a
       // face of its own at all.
       _rowStyle = OaaType.readingSmall.copyWith(color: colors.accent),
       _rowDash = OaaType.readingSmall.copyWith(
         color: colorForState(ReadingState.unavailable, colors),
       ),
       _peakLabel = layoutParagraph(
         'PEAK',
         OaaType.label.copyWith(color: colors.textMuted),
       ),
       _rmsLabel = layoutParagraph(
         'RMS',
         OaaType.label.copyWith(color: colors.textMuted),
       ),
       _unitLabel = layoutParagraph(
         'dB',
         OaaType.tick.copyWith(color: colors.textFaint),
       ),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final List<ui.Paragraph> labels;

  final Paint _track;
  final Color _ink;
  final Paint _peakMark;
  final Paint _segmentGap;
  final Paint _scaleRule;
  final Paint _clip;
  final Paint _clipIdle;
  final MeterFill _fill = MeterFill();

  final TextStyle _rowStyle;
  final TextStyle _rowDash;
  final ui.Paragraph _peakLabel;
  final ui.Paragraph _rmsLabel;
  final ui.Paragraph _unitLabel;

  /// Per channel: [0] peak, [1] RMS. Grown on demand — the channel count is
  /// fixed for the life of an engine, so this settles on the first frame.
  final List<ValueParagraph> _numbers = [];

  /// The segment gap lines, and the scale's own rows among them. Both rebuilt
  /// only when the geometry moves.
  Float32List _gaps = Float32List(0);
  Float32List _rules = Float32List(0);
  Rect _gapsFor = Rect.zero;
  int _gapsChannels = 0;
  double _gapsBarWidth = 0;

  /// Where the peak mark starts trading the fill colour for [OaaColors.over].
  /// −18 dBFS is conservative on purpose: the blend is a *slope*, and a mark
  /// that only changed colour at the ceiling would change after the moment it
  /// existed to warn about.
  static const double _tintFrom = -18.0;

  static const double _clipHeight = 6;

  /// Segment pitch: lit rows of 3 with the panel showing through 1.
  static const double _segmentPitch = 4;
  static const double _gapHeight = 1;
  static const double _litHeight = _segmentPitch - _gapHeight;

  @override
  void paint(Canvas canvas, Size size) {
    // The size floor is `ModuleKind.digitalMeter.minBody*`, enforced by the
    // frame. What is left here guards arithmetic, not legibility.
    final channels = labels.length;
    if (channels == 0) return;

    while (_numbers.length < channels * 2) {
      _numbers.add(ValueParagraph());
    }

    final rowHeight = _rowStyle.fontSize! * 1.2 + Space.xxs;
    final labelHeight = OaaType.label.fontSize! + Space.xs;
    final track = Rect.fromLTRB(
      graticule.gutter,
      rowHeight * 2 + _clipHeight + Space.xs,
      size.width - graticule.gutter,
      size.height - labelHeight,
    );
    if (track.height < 24 || track.width < channels * 4) return;

    final gap = channels > 4 ? Space.xxs : Space.xs;
    final barWidth = (track.width - gap * (channels - 1)) / channels;

    _fill.prepare(colors, color: _ink);

    // The numbers' baseline, taken off the first channel's reading, which the
    // row labels and the unit are set on — see below.
    var rowBaseline = 0.0;

    // **A trough per bar, not one rectangle behind all of them.** Painted as a
    // single background, the gaps between the channels are the same colour as
    // the empty part of every bar, so the only thing separating L from R is
    // where their fills happen to stop — two channels at different levels read
    // as one block with a step in it, and two channels at the same level read
    // as one bar. The gap has to show the module behind it to be a gap.
    for (var c = 0; c < channels; c++) {
      final left = track.left + c * (barWidth + gap);
      canvas.drawRect(
        Rect.fromLTRB(left, track.top, left + barWidth, track.bottom),
        _track,
      );
    }

    // Over the troughs and under the bars: the scale belongs to the meter as a
    // whole, so it crosses the gaps the same way the channel rules do. **On
    // the segment ruling**, which is the one the gap buffer at the foot of
    // this method is built on: `track.bottom + _gapHeight / 2` is where the
    // gap under the floor row would fall, and every gap above it is a pitch
    // further up. See `ScaleGraticule.paint` for why a scale off that grid is
    // worse than a scale a pixel off its value.
    graticule.paint(
      canvas,
      track,
      snapPitch: _segmentPitch,
      snapAt: _rulingAt(track),
    );

    for (var c = 0; c < channels; c++) {
      final left = track.left + c * (barWidth + gap);
      final right = left + barWidth;

      // --- RMS, as the filled column ----------------------------------------
      final rms = engine.rms[c];
      if (!rms.isNaN) {
        final rows = _litRows(track.bottom - _y(track, rms));
        if (rows > 0) {
          _fill.draw(
            canvas,
            Rect.fromLTRB(left, _rowTop(track, rows - 1), right, track.bottom),
          );
        }
      }

      // --- Peak, as a floating row tinted by its own level ------------------
      // The row the fill would have stopped on at this level, lit whole — so
      // the mark is the same object as a lit segment and the gap between it
      // and the column is a whole number of rows. Below one row of level it
      // holds the floor row rather than disappearing: the fill is a quantity
      // and may legitimately light nothing, but the peak is a mark, and a
      // channel whose peak mark is missing reads as a channel with no signal.
      final peak = engine.peak[c];
      if (!peak.isNaN && peak.isFinite) {
        final row = _litRows(track.bottom - _y(track, peak)) - 1;
        final top = _rowTop(track, row < 0 ? 0 : row);
        final heat = ((peak - _tintFrom) / -_tintFrom).clamp(0.0, 1.0);
        _peakMark.color = Color.lerp(_fill.bright, colors.over, heat)!;
        canvas.drawRect(
          Rect.fromLTRB(left, top, right, top + _litHeight),
          _peakMark,
        );
      }

      // --- Clip ---------------------------------------------------------------
      // Latched by the engine's run counter, which only resets when the signal
      // drops below full scale. A clip light you can miss by looking away is a
      // clip light that does not do its job.
      canvas.drawRect(
        Rect.fromLTRB(
          left,
          track.top - Space.xxs - _clipHeight,
          right,
          track.top - Space.xxs,
        ),
        engine.clip[c] > 0 ? _clip : _clipIdle,
      );

      // --- The numbers --------------------------------------------------------
      final peakText = _numbers[c * 2].of(
        Metric.peak.format(peak),
        _readingStyle(peak),
      );
      final rmsText = _numbers[c * 2 + 1].of(
        Metric.rms.format(rms),
        _readingStyle(rms),
      );
      if (c == 0) rowBaseline = peakText.alphabeticBaseline;
      final centre = left + barWidth / 2;
      canvas.drawParagraph(
        peakText,
        Offset(centre - peakText.longestLine / 2, 0),
      );
      canvas.drawParagraph(
        rmsText,
        Offset(centre - rmsText.longestLine / 2, rowHeight),
      );

      final label = labels[c];
      canvas.drawParagraph(
        label,
        Offset(
          left + (barWidth - label.longestLine) / 2,
          track.bottom + Space.xxs,
        ),
      );
    }

    // Row labels in the left gutter, the unit in the right one — the same
    // margins the scale writes in, so the header reads as part of the
    // instrument rather than as a caption stuck above it. **On the numbers'
    // baseline**, not their top edge: the three faces in a row have three
    // line heights, and top-aligned the unit floated a few pixels above the
    // reading it belongs to.
    final labelTop = rowBaseline - _peakLabel.alphabeticBaseline;
    final unitTop = rowBaseline - _unitLabel.alphabeticBaseline;
    canvas.drawParagraph(_peakLabel, Offset(0, labelTop));
    canvas.drawParagraph(_rmsLabel, Offset(0, rowHeight + labelTop));
    canvas.drawParagraph(
      _unitLabel,
      Offset(size.width - _unitLabel.longestLine, unitTop),
    );
    canvas.drawParagraph(
      _unitLabel,
      Offset(size.width - _unitLabel.longestLine, rowHeight + unitTop),
    );

    // --- Segmentation, over everything in the trough ------------------------
    // One buffer of horizontal lines across every bar, in the panel's own
    // colour so the gaps read as gaps. Drawn after the fills so a gap crosses
    // lit and unlit rows alike; rebuilt only when the geometry moves.
    if (_gapsFor != track ||
        _gapsChannels != channels ||
        _gapsBarWidth != barWidth) {
      final rows = (track.height / _segmentPitch).floor();
      _gaps = Float32List(rows * channels * 4);
      var i = 0;
      for (var row = 1; row <= rows; row++) {
        final y = track.bottom - row * _segmentPitch + _gapHeight / 2;
        if (y <= track.top) break;
        for (var c = 0; c < channels; c++) {
          final left = track.left + c * (barWidth + gap);
          _gaps[i++] = left;
          _gaps[i++] = y;
          _gaps[i++] = left + barWidth;
          _gaps[i++] = y;
        }
      }
      if (i < _gaps.length) _gaps = _gaps.sublist(0, i);

      // The scale's rows, in the gaps the graticule's lines were snapped to.
      // The graticule draws them under the bars, where the fill covers them
      // and the buffer above then paints the panel over what is left — so
      // without this pass the ruling would show only in the gutters between
      // the channels, and on a mono meter nowhere at all. Lit here instead,
      // a labelled value is one of the meter's own gaps in a lighter grey:
      // the division the scale marks, on the ruling the segments impose,
      // rather than a second set of lines beating against it.
      final ticks = graticule.scale.ticks;
      _rules = Float32List(ticks.length * channels * 4);
      var r = 0;
      for (final value in ticks) {
        final y = ScaleGraticule.snapped(
          _y(track, value),
          low: track.top,
          high: track.bottom,
          pitch: _segmentPitch,
          at: _rulingAt(track),
        );
        for (var c = 0; c < channels; c++) {
          final left = track.left + c * (barWidth + gap);
          _rules[r++] = left;
          _rules[r++] = y;
          _rules[r++] = left + barWidth;
          _rules[r++] = y;
        }
      }

      _gapsFor = track;
      _gapsChannels = channels;
      _gapsBarWidth = barWidth;
    }
    canvas.drawRawPoints(ui.PointMode.lines, _gaps, _segmentGap);
    canvas.drawRawPoints(ui.PointMode.lines, _rules, _scaleRule);
  }

  /// The face a reading is set in: the signal hue, or the muted one when there
  /// is no reading and [Metric.format] prints the em dash. [inkForReading] is
  /// the rule; this is it with the two faces built ahead of the frame.
  TextStyle _readingStyle(double value) => value.isNaN ? _rowDash : _rowStyle;

  double _y(Rect track, double value) =>
      track.bottom - graticule.scale.fractionOf(value) * track.height;

  /// Where the gap under the floor row would fall — the one line of the
  /// segment ruling every other gap is a whole pitch from, and what both the
  /// graticule and the buffer of scale rows snap against.
  static double _rulingAt(Rect track) => track.bottom + _gapHeight / 2;

  /// How many rows a column [height] pixels tall lights, counting only the
  /// rows it covers completely. Zero below one row of level.
  static int _litRows(double height) => height < _litHeight
      ? 0
      : ((height - _litHeight) / _segmentPitch).floor() + 1;

  /// The top edge of row [row], numbered from the floor of the track. Row
  /// zero's own top is [_litHeight] above the floor, and every row after it
  /// one pitch further up — the same arithmetic the gap buffer is built from,
  /// which is what keeps a lit row exactly between two gaps.
  static double _rowTop(Rect track, int row) =>
      track.bottom - row * _segmentPitch - _litHeight;

  @override
  bool shouldRepaint(_DigitalMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule) ||
      !identical(oldDelegate.labels, labels);
}
