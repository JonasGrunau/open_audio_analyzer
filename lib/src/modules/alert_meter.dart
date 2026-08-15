// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// One measurement, watched, with the worst it has been **latched**.
///
/// The latch is the entire module. Every other meter here answers "what is it
/// doing now", and nobody watches twelve of those continuously — you play a
/// mix, you talk to someone, and the one moment true peak went over is three
/// minutes in the past and gone from every display. This one keeps it until it
/// is cleared, which is the only way a warning about a transient is any use.
///
/// Latched state is deliberately *not* in the engine. It is a property of this
/// module — two Alert Meters watching different metrics need different latches,
/// and one watching the same metric as another should be clearable on its own.
/// It is cleared by the engine's reset, which is also what clears the maxima it
/// is watching, so the two cannot disagree.
class AlertMeterModule extends StatefulWidget {
  const AlertMeterModule({
    required this.engine,
    required this.clock,
    required this.metric,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Metric metric;
  final Calibration calibration;

  @override
  State<AlertMeterModule> createState() => _AlertMeterModuleState();
}

class _AlertMeterModuleState extends State<AlertMeterModule> {
  final _value = ValueParagraph();
  final _worstValue = ValueParagraph();
  ui.Paragraph? _name;
  ui.Paragraph? _worstLabel;
  Color? _labelColor;

  /// The worst state seen, and the reading that caused it.
  ///
  /// Updated from `paint`, which is unusual and deliberate: it is a plain
  /// accumulator that changes no layout and triggers no rebuild. Routing it
  /// through `setState` would rebuild this subtree up to sixty times a second
  /// to change a number a painter is already reading for free.
  ReadingState worst = ReadingState.unavailable;
  double worstValue = double.nan;

  /// The engine's reset is the one event that clears a latch. Detected by the
  /// elapsed clock running backwards, because a reset is exactly the thing that
  /// restarts it.
  double _lastElapsed = 0;

  void observe(ReadingState state, double value) {
    final elapsed = widget.engine.elapsedSeconds;
    if (elapsed < _lastElapsed) {
      worst = ReadingState.unavailable;
      worstValue = double.nan;
    }
    _lastElapsed = elapsed;

    if (state == ReadingState.unavailable) return;

    final severity = _severity(state);
    final latched = _severity(worst);
    if (severity > latched ||
        (severity == latched && _isWorse(widget.metric, value, worstValue))) {
      worst = state;
      worstValue = value;
    }
  }

  /// How bad a state is, as a number that can be compared.
  ///
  /// Not `ReadingState.index`: `unavailable` is declared last and would
  /// therefore sort as the worst of all, when it actually means "nothing has
  /// been measured yet" and must lose to everything.
  static int _severity(ReadingState state) => switch (state) {
    ReadingState.unavailable => -1,
    ReadingState.neutral || ReadingState.inSpec => 0,
    ReadingState.warn => 1,
    ReadingState.over => 2,
  };

  /// Which direction is "worse" depends on the metric, and getting it backwards
  /// would latch the *best* moment of the session.
  static bool _isWorse(Metric metric, double value, double against) {
    if (against.isNaN) return true;
    return switch (metric) {
      Metric.correlation => value < against,
      _ => value > against,
    };
  }

  @override
  void dispose() {
    _value.dispose();
    _worstValue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_labelColor != colors.textFaint) {
      _labelColor = colors.textFaint;
      final style = BelType.label.copyWith(color: colors.textFaint);
      _name = layoutParagraph(widget.metric.label.toUpperCase(), style);
      _worstLabel = layoutParagraph('WORST', style);
    }

    return MeterBody(
      painter: _AlertPainter(
        engine: widget.engine,
        metric: widget.metric,
        calibration: widget.calibration,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _AlertPainter extends MeterPainter {
  _AlertPainter({
    required this.engine,
    required this.metric,
    required this.calibration,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _lamp = Paint(),
       _rule = (Paint()
         ..strokeWidth = BelStroke.emphasis
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Metric metric;
  final Calibration calibration;
  final BelColors colors;
  final _AlertMeterModuleState state;

  final Paint _lamp;
  final Paint _rule;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 48 || size.height < 28) return;

    final value = readMetric(engine, metric);
    final reading = classify(metric, value, calibration);
    state.observe(reading, value);

    final color = colorForState(reading, colors);
    final latched = colorForState(state.worst, colors);

    // A wash rather than a solid block: the reading has to stay readable, and a
    // module that turns entirely red is one whose number you then cannot read
    // at the exact moment you want it.
    _lamp.color = latched.withValues(
      alpha: state.worst == ReadingState.over
          ? 0.16
          : (state.worst == ReadingState.warn ? 0.10 : 0.0),
    );
    if (_lamp.color.a > 0) {
      canvas.drawRect(Offset.zero & size, _lamp);
    }

    // The left edge carries the latched state at full strength. It is the part
    // visible from across a room and out of the corner of an eye.
    _rule.color = latched;
    canvas.drawLine(const Offset(1, 0), Offset(1, size.height), _rule);

    canvas.drawParagraph(state._name!, const Offset(Space.sm, 0));

    final fontSize = (size.height * 0.42).clamp(14.0, 44.0);
    final live = state._value.of(
      metric.format(value),
      BelType.reading(fontSize).copyWith(color: color),
      maxWidth: size.width - Space.sm,
    );
    canvas.drawParagraph(
      live,
      Offset(Space.sm, state._name!.height + Space.xxs),
    );

    // The latched value, small, under the live one. Small on purpose: it is
    // history, and history that shouts is history that gets ignored.
    final worstTop = state._name!.height + Space.xxs + live.height + Space.xxs;
    if (worstTop + BelType.readingSmall.fontSize! < size.height) {
      canvas.drawParagraph(state._worstLabel!, Offset(Space.sm, worstTop));
      canvas.drawParagraph(
        state._worstValue.of(
          metric.format(state.worstValue),
          BelType.readingSmall.copyWith(color: latched),
        ),
        Offset(
          Space.sm + state._worstLabel!.longestLine + Space.xs,
          worstTop - 1,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_AlertPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.metric != metric ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
