// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// One measurement, watched, with the worst it has been **latched**.
///
/// The latch is the entire module. Every other meter here answers "what is it
/// doing now", and nobody watches fourteen of those continuously — you play a
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
    // A link that has gone quiet reports NaN seconds, and a quiet link is not a
    // reset — the latch stays. What matters is that the NaN is not *stored*:
    // NaN compares false against everything, so a `_lastElapsed` holding one
    // makes the test below false forever and the latch can never be cleared
    // again, on this source or on any source selected after it.
    if (!elapsed.isNaN) {
      if (elapsed < _lastElapsed) {
        worst = ReadingState.unavailable;
        worstValue = double.nan;
      }
      _lastElapsed = elapsed;
    }

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
    final colors = OaaTheme.of(context);

    if (_labelColor != colors.textFaint) {
      _labelColor = colors.textFaint;
      final style = OaaType.label.copyWith(color: colors.textFaint);
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
         ..strokeWidth = OaaStroke.emphasis
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Metric metric;
  final Calibration calibration;
  final OaaColors colors;
  final _AlertMeterModuleState state;

  final Paint _lamp;
  final Paint _rule;

  @override
  void paint(Canvas canvas, Size size) {
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

    final name = state._name!;
    // **Sized off both axes, and not capped at a size a large module dwarfs.**
    // Height alone overflowed a wide, short module, and the old ceiling of 44
    // meant an Alert Meter given a quarter of a 27" display drew the same
    // digits as one in a corner — the module this one exists to be read from
    // across a room, at the size where that matters least. The width term is
    // what keeps a long reading inside the box; the ceiling is now high enough
    // that the box is what limits it.
    final fontSize = math
        .min(size.height * 0.42, size.width * 0.30)
        .clamp(14.0, 96.0)
        .toDouble();
    final live = state._value.of(
      metric.format(value),
      OaaType.reading(fontSize).copyWith(color: color),
      maxWidth: size.width - _textLeft,
    );

    // **The block is centred in the module, not hung from its top edge.**
    // Drawn from the origin it sat in the top-left corner of a module more
    // than twice its height, leaving two thirds of the tile empty below it —
    // and since the latched line is conditional, the amount of emptiness
    // changed depending on whether there was room for it.
    // The latched value tracks the live one at roughly a third of its size, so
    // the two keep the same relationship at every module size. Its label does
    // not: `WORST` is a label, and labels are the same everywhere on the
    // canvas — scaling those is how fourteen modules end up with fourteen type
    // scales.
    final worstSize = (fontSize * 0.32).clamp(12.0, 26.0).toDouble();
    final worstHeight = worstSize + Space.xxs;
    final hasWorst =
        name.height + Space.xxs + live.height + worstHeight < size.height;

    final blockHeight =
        name.height + Space.xxs + live.height + (hasWorst ? worstHeight : 0);
    var top = (size.height - blockHeight) / 2;
    if (top < 0) top = 0;

    canvas.drawParagraph(name, Offset(_textLeft, top));

    final liveTop = top + name.height + Space.xxs;
    canvas.drawParagraph(live, Offset(_textLeft, liveTop));

    // The latched value, small, under the live one. Small on purpose: it is
    // history, and history that shouts is history that gets ignored.
    if (hasWorst) {
      final worstTop = liveTop + live.height + Space.xxs;
      canvas.drawParagraph(state._worstLabel!, Offset(_textLeft, worstTop));
      canvas.drawParagraph(
        state._worstValue.of(
          metric.format(state.worstValue),
          OaaType.reading(worstSize).copyWith(color: latched),
        ),
        Offset(
          _textLeft + state._worstLabel!.longestLine + Space.xs,
          worstTop - 1,
        ),
      );
    }
  }

  /// Clear of the latched-state rule down the left edge, which is 2 px wide
  /// and centred on x = 1.
  static const double _textLeft = Space.sm;

  @override
  bool shouldRepaint(_AlertPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.metric != metric ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
