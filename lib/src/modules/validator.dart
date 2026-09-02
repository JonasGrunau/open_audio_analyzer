// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// The delivery decision, as a table.
///
/// Every other module here shows a measurement. This one shows a **conclusion**,
/// and that is a different job: the question at the end of a session is not
/// "what is my integrated loudness" but "can I send this", and answering it
/// means checking three numbers against the target — plus one for each
/// dynamics floor the target sets — and knowing which way each comparison
/// runs.
///
/// Each row also states its Δ — the signed distance from the number that
/// judges it — because "how far off am I" is the question the row exists to
/// answer, and a table that makes the reader do the subtraction answers it
/// slower than the fix takes. The Δ is derived beside the verdict from the
/// same calibration numbers, so the two cannot disagree.
///
/// **Which criteria it checks is the module's own setting**, and switching one
/// off takes it out of the verdict as well as out of the table. That is the
/// point rather than a side effect: a NOT READY that is really "the LRA of a
/// podcast is 4 LU" is a red light somebody learns to ignore. Two Validators
/// side by side can therefore say different things about the same programme and
/// both be right — which is why every row names what judged it, and why the
/// verdict of a module with nothing left to check is neither READY nor NOT
/// READY but a statement that it checked nothing. See [ValidatorCheck].
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
    required this.naming,
    required this.checks,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  /// How the two dynamics readings are named, which is the one thing about a
  /// row's name a user chooses. See `ModuleHost`.
  final DynamicsNaming naming;

  /// The criteria this module was asked to judge, in the order it prints them.
  ///
  /// A `List` rather than a `Set` so that two of them compare equal when they
  /// hold the same checks — the paragraphs below are rebuilt on a change, and
  /// a set that is never `==` its equal is a table that relays out its labels
  /// on every canvas rebuild.
  final List<ValidatorCheck> checks;

  @override
  State<ValidatorModule> createState() => _ValidatorModuleState();
}

/// The rows this Validator actually draws: the ones it was asked for, less the
/// ones this target says nothing about.
///
/// The dynamics floors are the rows that come and go with the target. A
/// target without one makes no statement about dynamics, and a row that read
/// "ODR-I 9.8 — PASS" under it would be read as a statement — see
/// [Calibration.odrIntegratedFloor]. The same rule builds [AnalysisReport.checks].
List<ValidatorCheck> _rowsFor(
  Calibration calibration,
  List<ValidatorCheck> chosen,
) => [
  for (final check in chosen)
    if (check.judgedBy(calibration)) check,
];

/// The most rows [_rowsFor] can return, which is how many paragraphs to hold.
final int _mostChecks = ValidatorCheck.values.length;

/// What the target says, formatted for the "against" column.
///
/// The three shapes a limit has — a target with a tolerance, a ceiling, a floor
/// — which is the same distinction [ComplianceCheck.limitLabel] makes for the
/// report. Only ever asked about a row [_rowsFor] kept, which is what makes the
/// two floors safe to read.
String _limitFor(ValidatorCheck check, Calibration c) => switch (check) {
  ValidatorCheck.lufsIntegrated =>
    '${c.lufsTarget.toStringAsFixed(1)} ±${c.lufsTolerance.toStringAsFixed(1)}',
  ValidatorCheck.truePeak => '≤ ${c.truePeakMax.toStringAsFixed(1)}',
  ValidatorCheck.loudnessRange => '≤ ${c.loudnessRangeMax.toStringAsFixed(1)}',
  ValidatorCheck.odrIntegrated =>
    '≥ ${c.odrIntegratedFloor!.toStringAsFixed(1)}',
  ValidatorCheck.odrShort => '≥ ${c.odrShortFloor!.toStringAsFixed(1)}',
};

class _ValidatorModuleState extends State<ValidatorModule> {
  // Allocated for the longest table once, rather than per target: the frame
  // path may not allocate, and a target change is not a frame.
  final _values = [for (var i = 0; i < _mostChecks; i++) ValueParagraph()];
  final _deltas = [for (var i = 0; i < _mostChecks; i++) ValueParagraph()];
  final _verdict = ValueParagraph();

  List<ValidatorCheck> _checks = const [];
  List<ui.Paragraph> _names = const [];
  List<ui.Paragraph> _limits = const [];
  List<ui.Paragraph> _passLabels = const [];
  ui.Paragraph? _deltaGlyph;

  /// What a module with nothing left to check says instead of a table.
  ///
  /// The one label here that is laid out in `paint` rather than beside the
  /// others: it is a sentence rather than a word, so it has to be wrapped to
  /// the module it is in — a Validator may be four columns wide, and a notice
  /// laid out at its natural width would be cut off mid-word by the body's
  /// clip. Re-laid only when the width or the skin changes; see
  /// [ValueParagraph].
  final _notice = ValueParagraph();

  Calibration? _builtFor;
  List<ValidatorCheck> _builtChecks = const [];
  Color? _builtColor;
  DynamicsNaming? _builtNaming;

  /// The lowest ODR-S since the engine's last reset — what an ODR-S floor is
  /// checked against, because "never more squeezed than this" is a statement
  /// about the worst three seconds and not about the current ones. Kept here
  /// because the engine publishes no minimum: a file report takes the same
  /// minimum over every 10 ms sub-block, and this one is taken over what the
  /// clock showed the module, which is every published block while the window
  /// is on screen.
  ///
  /// Folded on a change of generation, never on a paint, and cleared by the
  /// elapsed clock running backwards, which is what a reset is — the same
  /// two rules the Alert Meter's latch follows, for the same reasons.
  ///
  /// Kept whether or not the ODR-S row is switched on: it is a minimum over
  /// the programme, so a row switched on halfway through one would otherwise
  /// judge the delivery against the three seconds since it was switched on and
  /// print a pass for a programme that had already failed.
  double _psrMin = double.nan;
  int _seenGeneration = -1;
  double _lastElapsed = 0;

  void _observe(MeterSource engine) {
    if (engine.generation == _seenGeneration) return;
    _seenGeneration = engine.generation;

    final elapsed = engine.elapsedSeconds;
    // A quiet link reports NaN seconds and is not a reset; see the Alert
    // Meter for why the NaN must not be stored either.
    if (!elapsed.isNaN) {
      if (elapsed < _lastElapsed) _psrMin = double.nan;
      _lastElapsed = elapsed;
    }

    final psr = engine.odrShort;
    if (psr.isNaN) return;
    _psrMin = _psrMin.isNaN ? psr : math.min(_psrMin, psr);
  }

  @override
  void dispose() {
    for (final value in _values) {
      value.dispose();
    }
    for (final delta in _deltas) {
      delta.dispose();
    }
    _verdict.dispose();
    _notice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != widget.calibration ||
        _builtColor != colors.textFaint ||
        _builtNaming != widget.naming ||
        !listEquals(_builtChecks, widget.checks)) {
      _builtFor = widget.calibration;
      _builtChecks = widget.checks;
      _builtColor = colors.textFaint;
      _builtNaming = widget.naming;

      final label = OaaType.label.copyWith(color: colors.textFaint);
      final tick = OaaType.tick.copyWith(color: colors.textFaint);

      _checks = _rowsFor(widget.calibration, widget.checks);
      _names = [
        for (final check in _checks)
          layoutParagraph(check.labelIn(widget.naming).toUpperCase(), label),
      ];
      _limits = [
        for (final check in _checks)
          layoutParagraph(_limitFor(check, widget.calibration), tick),
      ];
      // At the size of the number it marks rather than of a graticule tick.
      // It heads a reading — the row's distance from what judges it — and a
      // mark smaller than the thing it annotates reads as a superscript on
      // the number to its left rather than as the label of the one to its
      // right.
      _deltaGlyph = layoutParagraph(
        'Δ',
        OaaType.readingSmall.copyWith(color: colors.textFaint),
      );
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
        checks: _checks,
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
    required this.checks,
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

  /// The rows, which the state laid its labels out for in the same build. Held
  /// here as well so that switching a check off repaints the table on the spot
  /// rather than on the next tick of the clock.
  final List<ValidatorCheck> checks;

  final OaaColors colors;
  final _ValidatorModuleState state;

  final Paint _rule;

  static const double _verdictHeight = 26;

  /// Below this width the Δ column is dropped — four columns and a verdict in
  /// less reads as a collision, not a table.
  static const double _deltaFrom = 300;

  @override
  void paint(Canvas canvas, Size size) {
    // **The rows fill the module, and what is left over is split above and
    // below them rather than all dropped at the bottom.** At the old ceiling
    // of 34 px a default-size Validator drew three tight rows under its
    // verdict and left a third of the tile blank beneath — a table that had
    // visibly run out before the box did. The ceiling still exists, because a
    // twelve-row-tall Validator with three checks should not have rows the
    // height of a fist; past it the block is simply centred in the space.
    state._observe(engine);

    final available = size.height - _verdictHeight;

    // **A table with no rows is not a table that passes.** Every check was
    // switched off, or this target defines none of the ones that were left on
    // — either way nothing was compared, and READY TO DELIVER under an empty
    // table is the exact sentence this module exists not to say.
    if (checks.isEmpty) {
      _drawVerdict(canvas, size, 'NOTHING CHECKED', colors.textFaint);
      // A label rather than a tick: it is a sentence, and the tick style is
      // the monospaced one every *number* in this table is set in.
      final notice = state._notice.of(
        'CHOOSE CHECKS IN THE MODULE MENU',
        OaaType.label.copyWith(color: colors.textFaint),
        align: TextAlign.center,
        maxWidth: size.width,
      );
      canvas.drawParagraph(
        notice,
        Offset(0, _verdictHeight + (available - notice.height) / 2),
      );
      return;
    }

    final rowHeight = (available / checks.length).clamp(14.0, 44.0);

    // The Δ column is the first thing a narrow module gives up: the value and
    // the limit imply it, so it is the one column that is a convenience rather
    // than a fact the table would be lying without.
    final showDelta = size.width >= _deltaFrom;
    final valueRight = size.width * (showDelta ? 0.44 : 0.62);
    final limitLeft = showDelta ? size.width * 0.68 : valueRight + Space.sm;

    // The measured column scales with the row; the name, the limit and the
    // PASS/FAIL do not. Those three are labels — the same size in every module
    // on the canvas — and the middle column is a reading, which is the thing
    // you are actually looking at and the thing that should grow with the box.
    final readingSize = (rowHeight * 0.42).clamp(13.0, 28.0).toDouble();

    var worst = _Outcome.pass;
    var top = _verdictHeight + (available - rowHeight * checks.length) / 2;

    for (var i = 0; i < checks.length; i++) {
      if (top + rowHeight > size.height + 1) break;

      final check = checks[i];
      // The ODR-S row is the one reading that is not the live one.
      final value = check == ValidatorCheck.odrShort
          ? state._psrMin
          : readMetric(engine, check.metric);
      final outcome = _judge(check, value);
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
      // Coloured by the row's own verdict, so the table scans without being
      // read: the accent — the ink every module prints a measurement in — is
      // "this is fine", `over` is "this is not", and a row still waiting for a
      // measurement is the muted dash. The column used to be white apart from
      // its failures, which said nothing until something was wrong.
      final reading = state._values[i].of(
        check.metric.format(value),
        OaaType.reading(readingSize).copyWith(color: _readingColor(outcome)),
      );
      canvas.drawParagraph(
        reading,
        Offset(
          valueRight - reading.longestLine,
          top + (rowHeight - reading.height) / 2,
        ),
      );

      // --- Δ, the signed distance to the limit that judges this row --------
      // Derived beside the verdict from the same calibration numbers, so the
      // three columns cannot disagree about where the reading stands. It saves
      // the reader the subtraction Decibel's validator saves them: "how far
      // off am I" is the question the row exists to answer.
      if (showDelta) {
        final delta = targetDelta(check.metric, value, calibration);
        final glyph = state._deltaGlyph!;
        final deltaLeft = valueRight + Space.sm;
        canvas.drawParagraph(
          glyph,
          Offset(deltaLeft, top + (rowHeight - glyph.height) / 2),
        );
        final number = state._deltas[i].of(
          formatDelta(delta),
          OaaType.readingSmall.copyWith(
            color: delta.isNaN ? colors.textMuted : _readingColor(outcome),
          ),
        );
        canvas.drawParagraph(
          number,
          Offset(
            deltaLeft + glyph.longestLine + Space.xxs,
            top + (rowHeight - number.height) / 2,
          ),
        );
      }

      final limit = state._limits[i];
      canvas.drawParagraph(
        limit,
        Offset(limitLeft, top + (rowHeight - limit.height) / 2),
      );

      final verdict = state._passLabels[outcome.index];
      canvas.drawParagraph(
        verdict,
        Offset(
          size.width - verdict.longestLine,
          top + (rowHeight - verdict.height) / 2,
        ),
      );

      if (i < checks.length - 1) {
        canvas.drawLine(
          Offset(0, top + rowHeight),
          Offset(size.width, top + rowHeight),
          _rule,
        );
      }
      top += rowHeight;
    }

    final (text, color) = switch (worst) {
      _Outcome.pass => ('READY TO DELIVER', colors.accent),
      _Outcome.fail => ('NOT READY', colors.over),
      _Outcome.undecided => ('MEASURING', colors.textFaint),
    };
    _drawVerdict(canvas, size, text, color);
  }

  /// The conclusion, and the rule under it. One place, because the empty table
  /// above has a conclusion of its own and a second copy of this is a second
  /// rule to move.
  void _drawVerdict(Canvas canvas, Size size, String text, Color color) {
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

  /// The colour a row's numbers are printed in. Not a colour per column: the
  /// reading and the Δ beside it are two views of the same comparison, and two
  /// colours would say they disagreed about it.
  ///
  /// `colorForState` is deliberately not reused here. It judges a metric
  /// against the calibration on its own terms, and this table's verdict is the
  /// one thing in the module the reader is looking at — an ODR-S row is judged
  /// against the floor the *target* sets, and a row that is undecided is the
  /// same em dash in the same [OaaColors.textMuted] every unmeasured quantity
  /// in the application is printed in.
  Color _readingColor(_Outcome outcome) => switch (outcome) {
    _Outcome.pass => colors.accent,
    _Outcome.fail => colors.over,
    _Outcome.undecided => colors.textMuted,
  };

  /// Each comparison runs its own way, which is the whole reason this is a
  /// module and not three number boxes side by side.
  _Outcome _judge(ValidatorCheck check, double value) {
    if (value.isNaN) return _Outcome.undecided;
    return switch (check) {
      ValidatorCheck.lufsIntegrated =>
        calibration.meetsLoudnessTarget(value) ? _Outcome.pass : _Outcome.fail,
      // **A peak at the floor decides nothing.** The other four rows read NaN
      // until a gated block exists, so they wait on their own; true peak max
      // is a running maximum and has a number from the first block — the
      // clamp, for as long as nothing has played. Held against a −1 dBTP
      // ceiling that clamp passes, so a Validator watching an idle input
      // printed `-144.0 … PASS` and, with every other row still undecided,
      // the one green line on a table that had measured nothing. A verdict on
      // silence is the same vacuous arithmetic that ODR-S was gated for.
      ValidatorCheck.truePeak =>
        value <= MeterShape.dbFloor
            ? _Outcome.undecided
            : (calibration.exceedsTruePeak(value)
                  ? _Outcome.fail
                  : _Outcome.pass),
      ValidatorCheck.loudnessRange =>
        calibration.exceedsLoudnessRange(value) ? _Outcome.fail : _Outcome.pass,
      ValidatorCheck.odrIntegrated =>
        calibration.undercutsOdrIntegrated(value)
            ? _Outcome.fail
            : _Outcome.pass,
      ValidatorCheck.odrShort =>
        calibration.undercutsOdrShort(value) ? _Outcome.fail : _Outcome.pass,
    };
  }

  @override
  bool shouldRepaint(_ValidatorPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !listEquals(oldDelegate.checks, checks) ||
      !identical(oldDelegate.engine, engine);
}
