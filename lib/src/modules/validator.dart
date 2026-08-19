// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// The delivery decision, as a table.
///
/// Every other module here shows a measurement. This one shows a **conclusion**,
/// and that is a different job: the question at the end of a session is not
/// "what is my integrated loudness" but "can I send this", and answering it
/// means checking three numbers against the target and knowing which way each
/// comparison runs.
///
/// The verdict is deliberately conservative. A row whose measurement is not yet
/// defined does not pass and does not fail — it reads as a dash, and the
/// overall verdict stays "measuring". A validator that said READY forty
/// milliseconds into a programme, before integrated loudness existed, would be
/// worse than no validator, because somebody would believe it.
class ValidatorModule extends StatefulWidget {
  const ValidatorModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<ValidatorModule> createState() => _ValidatorModuleState();
}

/// One line of the table: what it measures, and what it is measured against.
class _Check {
  const _Check(this.metric, this.limit);

  final Metric metric;

  /// What the target says, formatted for the "against" column.
  final String Function(Calibration calibration) limit;
}

const _checks = [
  _Check(Metric.lufsIntegrated, _loudnessLimit),
  _Check(Metric.truePeakMax, _truePeakLimit),
  _Check(Metric.loudnessRange, _rangeLimit),
];

String _loudnessLimit(Calibration c) =>
    '${c.lufsTarget.toStringAsFixed(1)} ±${c.lufsTolerance.toStringAsFixed(1)}';
String _truePeakLimit(Calibration c) => '≤ ${c.truePeakMax.toStringAsFixed(1)}';
String _rangeLimit(Calibration c) =>
    '≤ ${c.loudnessRangeMax.toStringAsFixed(1)}';

class _ValidatorModuleState extends State<ValidatorModule> {
  final _values = [for (final _ in _checks) ValueParagraph()];
  final _verdict = ValueParagraph();

  List<ui.Paragraph> _names = const [];
  List<ui.Paragraph> _limits = const [];
  List<ui.Paragraph> _passLabels = const [];
  Calibration? _builtFor;
  Color? _builtColor;

  @override
  void dispose() {
    for (final value in _values) {
      value.dispose();
    }
    _verdict.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != widget.calibration || _builtColor != colors.textFaint) {
      _builtFor = widget.calibration;
      _builtColor = colors.textFaint;

      final label = OaaType.label.copyWith(color: colors.textFaint);
      final tick = OaaType.tick.copyWith(color: colors.textFaint);

      _names = [
        for (final check in _checks)
          layoutParagraph(check.metric.label.toUpperCase(), label),
      ];
      _limits = [
        for (final check in _checks)
          layoutParagraph(check.limit(widget.calibration), tick),
      ];
      _passLabels = [
        layoutParagraph('PASS', OaaType.label.copyWith(color: colors.accent)),
        layoutParagraph('FAIL', OaaType.label.copyWith(color: colors.over)),
        // Muted, not faint: this dash sits in the same column as PASS and FAIL
        // and carries the same weight of statement — the check could not be
        // made. See `colorForState` for the full reasoning.
        layoutParagraph('—', OaaType.label.copyWith(color: colors.textMuted)),
      ];
    }

    return MeterBody(
      painter: _ValidatorPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

/// Where a single check landed.
enum _Outcome { pass, fail, undecided }

class _ValidatorPainter extends MeterPainter {
  _ValidatorPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _rule = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final _ValidatorModuleState state;

  final Paint _rule;

  static const double _verdictHeight = 26;

  @override
  void paint(Canvas canvas, Size size) {
    // **The rows fill the module, and what is left over is split above and
    // below them rather than all dropped at the bottom.** At the old ceiling
    // of 34 px a default-size Validator drew three tight rows under its
    // verdict and left a third of the tile blank beneath — a table that had
    // visibly run out before the box did. The ceiling still exists, because a
    // twelve-row-tall Validator with three checks should not have rows the
    // height of a fist; past it the block is simply centred in the space.
    final available = size.height - _verdictHeight;
    final rowHeight = (available / _checks.length).clamp(14.0, 44.0);
    final valueRight = size.width * 0.62;

    // The measured column scales with the row; the name, the limit and the
    // PASS/FAIL do not. Those three are labels — the same size in every module
    // on the canvas — and the middle column is a reading, which is the thing
    // you are actually looking at and the thing that should grow with the box.
    final readingSize = (rowHeight * 0.42).clamp(13.0, 28.0).toDouble();

    var worst = _Outcome.pass;
    var top = _verdictHeight + (available - rowHeight * _checks.length) / 2;

    for (var i = 0; i < _checks.length; i++) {
      if (top + rowHeight > size.height + 1) break;

      final check = _checks[i];
      final value = readMetric(engine, check.metric);
      final outcome = _judge(check.metric, value);
      if (outcome == _Outcome.fail) {
        worst = _Outcome.fail;
      } else if (outcome == _Outcome.undecided && worst == _Outcome.pass) {
        worst = _Outcome.undecided;
      }

      final name = state._names[i];
      final baseline = top + (rowHeight - name.height) / 2;
      canvas.drawParagraph(name, Offset(0, baseline));

      // Laid out left-aligned and *positioned* right, rather than laid out with
      // TextAlign.right. A right-aligned paragraph already pushes its text to
      // the far edge of the width it was given, so offsetting it by its own
      // longestLine as well moves it right twice — which put every reading on
      // top of the limit beside it.
      final reading = state._values[i].of(
        check.metric.format(value),
        OaaType.reading(readingSize).copyWith(
          color: outcome == _Outcome.fail ? colors.over : colors.textPrimary,
        ),
      );
      canvas.drawParagraph(
        reading,
        Offset(
          valueRight - reading.longestLine,
          top + (rowHeight - reading.height) / 2,
        ),
      );

      final limit = state._limits[i];
      canvas.drawParagraph(
        limit,
        Offset(valueRight + Space.sm, top + (rowHeight - limit.height) / 2),
      );

      final verdict = state._passLabels[outcome.index];
      canvas.drawParagraph(
        verdict,
        Offset(
          size.width - verdict.longestLine,
          top + (rowHeight - verdict.height) / 2,
        ),
      );

      if (i < _checks.length - 1) {
        canvas.drawLine(
          Offset(0, top + rowHeight),
          Offset(size.width, top + rowHeight),
          _rule,
        );
      }
      top += rowHeight;
    }

    // --- The verdict --------------------------------------------------------
    final (text, color) = switch (worst) {
      _Outcome.pass => ('READY TO DELIVER', colors.accent),
      _Outcome.fail => ('NOT READY', colors.over),
      _Outcome.undecided => ('MEASURING', colors.textFaint),
    };
    canvas.drawParagraph(
      state._verdict.of(text, OaaType.label.copyWith(color: color)),
      const Offset(0, Space.xs),
    );
    canvas.drawLine(
      const Offset(0, _verdictHeight - 1),
      Offset(size.width, _verdictHeight - 1),
      _rule,
    );
  }

  /// Each comparison runs its own way, which is the whole reason this is a
  /// module and not three number boxes side by side.
  _Outcome _judge(Metric metric, double value) {
    if (value.isNaN) return _Outcome.undecided;
    return switch (metric) {
      Metric.lufsIntegrated =>
        calibration.meetsLoudnessTarget(value) ? _Outcome.pass : _Outcome.fail,
      Metric.truePeakMax =>
        calibration.exceedsTruePeak(value) ? _Outcome.fail : _Outcome.pass,
      Metric.loudnessRange =>
        calibration.exceedsLoudnessRange(value) ? _Outcome.fail : _Outcome.pass,
      _ => _Outcome.undecided,
    };
  }

  @override
  bool shouldRepaint(_ValidatorPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
