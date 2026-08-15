// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Sample peak and RMS, per channel, up to 7.1.
///
/// Two quantities per channel on one bar rather than two bars: the RMS is the
/// filled column and the peak is a floating tick above it, so the gap between
/// them *is* the crest factor and you read it without doing arithmetic. Two
/// separate bars show the same numbers and hide the relationship between them,
/// which is the only reason to show both at once.
///
/// The top 6 dB is drawn in the warning colour on every channel. That is not
/// an alert — it is a permanent region of the scale, so the eye learns where it
/// is and a channel entering it is visible from across a room.
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
  /// 60 dB of range at 12 dB a tick. Wider than the LUFS meter because a
  /// digital meter has to show a quiet channel is *present* rather than where
  /// it sits against a target.
  static const _scale = MeterScale(min: -60, max: 0, step: 12);

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
    final colors = BelTheme.of(context);
    final channels = widget.engine.channels.clamp(1, kBelMaxChannels);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.left, colors.textFaint) ||
        _labelledChannels != channels) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = BelType.label.copyWith(color: colors.textFaint);
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
       _fill = (Paint()..color = colors.meterFill),
       _hot = (Paint()..color = colors.warn),
       _peakTick = (Paint()..color = colors.textPrimary),
       _clip = (Paint()..color = colors.over),
       _clipIdle = (Paint()..color = colors.hairline),
       super(repaint: repaint);

  final MeterSource engine;
  final BelColors colors;
  final ScaleGraticule graticule;
  final List<ui.Paragraph> labels;

  final Paint _track;
  final Paint _fill;
  final Paint _hot;
  final Paint _peakTick;
  final Paint _clip;
  final Paint _clipIdle;

  /// Where the bar changes colour. Not a limit — a region.
  static const double _hotFrom = -6.0;

  static const double _clipHeight = 6;
  static const double _peakTickHeight = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final channels = labels.length;
    if (channels == 0 || size.width < 60 || size.height < 60) return;

    final labelHeight = BelType.label.fontSize! + Space.xs;
    final track = Rect.fromLTRB(
      graticule.gutter,
      _clipHeight + Space.xxs,
      size.width,
      size.height - labelHeight,
    );
    if (track.height < 24 || track.width < channels * 4) return;

    canvas.drawRect(track, _track);
    graticule.paint(canvas, track);

    final gap = channels > 4 ? Space.xxs : Space.xs;
    final barWidth = (track.width - gap * (channels - 1)) / channels;
    final hotY = _y(track, _hotFrom);

    for (var c = 0; c < channels; c++) {
      final left = track.left + c * (barWidth + gap);
      final right = left + barWidth;

      // --- RMS, in two segments so the hot region keeps its colour ---------
      final rms = engine.rms[c];
      if (!rms.isNaN) {
        final top = _y(track, rms);
        if (top < track.bottom) {
          canvas.drawRect(
            Rect.fromLTRB(left, top < hotY ? hotY : top, right, track.bottom),
            _fill,
          );
          if (top < hotY) {
            canvas.drawRect(Rect.fromLTRB(left, top, right, hotY), _hot);
          }
        }
      }

      // --- Peak, as a floating tick ----------------------------------------
      final peak = engine.peak[c];
      if (!peak.isNaN && peak > graticule.scale.min) {
        final y = _y(track, peak);
        canvas.drawRect(
          Rect.fromLTRB(left, y - _peakTickHeight, right, y),
          peak >= _hotFrom ? _hot : _peakTick,
        );
      }

      // --- Clip -------------------------------------------------------------
      // Latched by the engine's run counter, which only resets when the signal
      // drops below full scale. A clip light you can miss by looking away is a
      // clip light that does not do its job.
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, _clipHeight),
        engine.clip[c] > 0 ? _clip : _clipIdle,
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
  }

  double _y(Rect track, double value) =>
      track.bottom - graticule.scale.fractionOf(value) * track.height;

  @override
  bool shouldRepaint(_DigitalMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule) ||
      !identical(oldDelegate.labels, labels);
}
