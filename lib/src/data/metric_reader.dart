// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// Reads a [Metric] out of a [MeterSource].
///
/// This function is the only place the domain vocabulary meets the engine, and
/// it lives in the app rather than in either package on purpose: `oaa_core`
/// must not depend on `oaa_engine` (the tablet remote display has no engine at
/// all — it reads measurements off a socket), and `oaa_engine` must not know
/// what a `Metric` is (the CLI and the plugin never draw one).
///
/// Phase 6 adds a second implementation of exactly this signature backed by the
/// wire protocol, and every module keeps working unchanged.
double readMetric(MeterSource engine, Metric metric) => switch (metric) {
  Metric.lufsMomentary => engine.lufsMomentary,
  Metric.lufsShort => engine.lufsShort,
  Metric.lufsIntegrated => engine.lufsIntegrated,
  Metric.loudnessRange => engine.loudnessRange,
  Metric.truePeak => engine.truePeak,
  Metric.truePeakMax => engine.truePeakMax,
  Metric.samplePeakMax => engine.samplePeakMax,
  Metric.peak => _loudestChannel(engine.peak, engine.channels),
  Metric.rms => _loudestChannel(engine.rms, engine.channels),
  Metric.crestFactor => engine.crestFactor,
  Metric.odrIntegrated => engine.odrIntegrated,
  Metric.odrShort => engine.odrShort,
  Metric.correlation => engine.correlation,
  Metric.balance => engine.balance,
};

/// The loudest of the active channels.
///
/// A Number Box has room for one number, and for a per-channel quantity the
/// only defensible single number is the worst case — that is what a ceiling is
/// checked against. Averaging channels would hide a single hot one, which is
/// precisely the thing somebody looking at a peak reading wants to catch.
double _loudestChannel(List<double> values, int channels) {
  var loudest = MeterShape.dbFloor;
  final count = channels.clamp(1, values.length);
  for (var i = 0; i < count; i++) {
    if (values[i] > loudest) loudest = values[i];
  }
  return loudest;
}

/// How a reading sits against the active target.
///
/// Returns [ReadingState.unavailable] for NaN, which is how the engine says "not
/// measured in this build" — distinct from a measured zero, and rendered as a
/// dash rather than a number nobody took.
ReadingState classify(Metric metric, double value, Calibration calibration) {
  if (value.isNaN) return ReadingState.unavailable;

  return switch (metric) {
    // Over the target is [ReadingState.over], under it is neutral. Being
    // *louder* than the number you set is the one thing every meter in the
    // application marks in red — the LUFS meter's bars, the super meter's
    // arcs, the histogram and the loudness distribution all cut at this exact
    // line — and a Number Box or an Alert Meter watching LUFS-I has to agree
    // with the bar beside it. It read as plain text for eight phases, so the
    // same over-target mix was red on one module and uncoloured on another.
    // Quiet is not over: under the target stays neutral, which is also what
    // keeps the colour from meaning two opposite things at once.
    Metric.lufsIntegrated =>
      calibration.meetsLoudnessTarget(value)
          ? ReadingState.inSpec
          : (value > calibration.lufsTarget + calibration.lufsTolerance
                ? ReadingState.over
                : ReadingState.neutral),

    Metric.truePeak || Metric.truePeakMax => _peakKind(value, calibration),

    // Sample peak has no true-peak headroom allowance, so anything at or above
    // full scale is already clipped by the time it is measured.
    Metric.samplePeakMax ||
    Metric.peak => value >= 0.0 ? ReadingState.over : ReadingState.neutral,

    Metric.loudnessRange =>
      calibration.exceedsLoudnessRange(value)
          ? ReadingState.over
          : ReadingState.neutral,

    // The two limits that are floors. Under one is [ReadingState.over] all the
    // same: the state names the colour, and the colour means "on the wrong
    // side of the number you set", whichever side that is. A target with no
    // floor makes no statement, and the reading stays neutral — never green,
    // because green would say it had been checked against something.
    Metric.odrIntegrated => _floorKind(value, calibration.odrIntegratedFloor),
    Metric.odrShort => _floorKind(value, calibration.odrShortFloor),

    // Anti-phase content is the thing a correlation meter exists to catch.
    Metric.correlation =>
      isAntiPhase(value) ? ReadingState.warn : ReadingState.neutral,

    _ => ReadingState.neutral,
  };
}

/// Whether a correlation reading is far enough below zero to call anti-phase.
///
/// The rule was `value < 0`, which is the textbook line and one digit too
/// sharp for a display. `Metric.correlation` prints two decimals, so a reading
/// of −0.001 formats as `-0.00` and was coloured like one of −0.9; and a
/// signal whose channels are genuinely unrelated sits at zero with the sign
/// falling whichever way the last block did, so a marker parked dead centre
/// changed colour on its own. Half of the last printed digit is the threshold:
/// **if the digits say zero, the colour says zero.** Keep the constant in step
/// with `Metric.correlation`'s decimals.
///
/// Used by [classify] and by the Phase Scope's correlation marker, which are
/// the two places a correlation is coloured.
bool isAntiPhase(double correlation) => correlation <= -0.005;

ReadingState _floorKind(double value, double? floor) {
  if (floor == null) return ReadingState.neutral;
  if (value < floor) return ReadingState.over;
  // Within 1 LU of the floor is where the next pass of the limiter takes it
  // under — the same margin the peak ceiling warns at.
  if (value < floor + 1.0) return ReadingState.warn;
  return ReadingState.inSpec;
}

ReadingState _peakKind(double value, Calibration calibration) {
  // A peak at the floor is silence, and silence answers no delivery question
  // — the same judgement the Validator's true-peak row makes, kept here so
  // the two cannot disagree about one number. Neutral rather than
  // [ReadingState.inSpec]: a ceiling nothing was held against has not been
  // met, it has not been tested. The two share a colour today, so this is
  // invisible until a skin or a state tells them apart; it is the meaning
  // that is being fixed.
  if (value <= MeterShape.dbFloor) return ReadingState.neutral;
  if (calibration.exceedsTruePeak(value)) return ReadingState.over;
  // Within 1 dB of the ceiling is where a limiter starts mattering.
  if (value > calibration.truePeakMax - 1.0) return ReadingState.warn;
  return ReadingState.inSpec;
}

/// The signed distance from the number this metric is judged against — the
/// target itself for loudness, the ceiling for true peak, the maximum for LRA,
/// the floor for the two dynamics ratios.
///
/// Positive is always "above the line", whichever way the comparison runs. It
/// is [classify] that says which direction is the failing one, and the two are
/// read together: `+1.4` in red is over a ceiling, `+1.4` in green is a
/// programme sitting comfortably above a floor.
///
/// **NaN where there is no line**, and that is the whole of the contract. A
/// metric nothing is measured against has no delta, and neither does a target
/// that sets no ODR floor — a difference from a floor nobody stated would be a
/// number this application did not measure, printed with the same authority as
/// one it did. Callers render it as an em dash, the way they do every other
/// unavailable reading.
double targetDelta(Metric metric, double value, Calibration calibration) {
  if (value.isNaN) return double.nan;
  // A level at the floor is a clamp rather than a reading — see
  // [Metric.isAbsoluteLevel] — so its distance from anything is arithmetic on
  // a sentinel. It reads convincingly: a true peak max of `-∞` against a −1
  // dBTP ceiling gives `Δ−143.0`, which is a precise statement of headroom
  // over a programme that has not played. The verdict beside it is already
  // withheld; a delta that answered where the verdict would not is the same
  // number wearing two different confidences.
  if (metric.isAbsoluteLevel && value <= MeterShape.dbFloor) {
    return double.nan;
  }
  return switch (metric) {
    Metric.lufsIntegrated => value - calibration.lufsTarget,
    Metric.truePeakMax => value - calibration.truePeakMax,
    Metric.loudnessRange => value - calibration.loudnessRangeMax,
    Metric.odrIntegrated =>
      value - (calibration.odrIntegratedFloor ?? double.nan),
    Metric.odrShort => value - (calibration.odrShortFloor ?? double.nan),
    _ => double.nan,
  };
}

/// Whether [targetDelta] can answer here — which is a question about the
/// metric **and** about the target in front of it.
///
/// What a menu asks before offering to show one, and it is the exact
/// complement of [targetDelta]'s NaN: true where a distance exists, false
/// where the answer would be an em dash.
///
/// **The two dynamics ratios answered on the metric alone until 0.14.1, and
/// that was the trap the whole rule exists to prevent.** The argument was that
/// whether *this* target states a floor is a different question, one the
/// reading itself answers — but the reading answers it with a dash, which is
/// what a module nobody measured anything for looks like, and a disabled row
/// was the only way out. It is not a hypothetical: no built-in target states
/// an ODR-I floor and only `dynamic-master` states an ODR-S one, so Delta on
/// either dynamics ratio printed an em dash for ever under the target the
/// application ships switched on. The Validator settled the same question the
/// same way one module over — [ValidatorCheck.judgedBy] drops the checks the
/// target says nothing about, and its menu counts the rows it actually draws.
bool hasTarget(Metric metric, Calibration calibration) => switch (metric) {
  Metric.lufsIntegrated || Metric.truePeakMax || Metric.loudnessRange => true,
  Metric.odrIntegrated => calibration.odrIntegratedFloor != null,
  Metric.odrShort => calibration.odrShortFloor != null,
  _ => false,
};

/// Whether an Alert Meter built from [spec] prints the distance from the
/// target rather than the reading itself.
///
/// The stored choice — see [ModuleSpec.alertDelta] — and whether there is a
/// line to measure from. The second half is not redundant: what the module
/// shows is two settings and a target, and any of the three can move out from
/// under the other two. A module switched to Delta on true peak and then moved
/// to correlation carries a `delta` nothing can satisfy; so does one on ODR-S
/// under a target that states no floor. Neither prints a dash — both print the
/// reading itself, and the Δ goes with the distance it no longer shows.
///
/// **The stored choice is kept rather than corrected**, so the setting is
/// still there when a target that draws the line comes back. It is the
/// *effective* answer that this function gives, and every consumer goes
/// through it.
///
/// One function, because the canvas menu and [ModuleHost] both have to reach
/// the same answer and a second copy of this rule is a menu that disagrees
/// with the module it opened over.
bool alertDeltaOf(ModuleSpec spec, Calibration calibration) =>
    hasTarget(spec.metric, calibration) && spec.alertDelta;

/// The unit [targetDelta] answers in, which is **not** the metric's own.
///
/// The reference cancels in a subtraction: the difference of two LUFS readings
/// is LU, and the difference of two dBTP readings is dB. A module that printed
/// `+0.6 dBTP` after a delta would be stating a true-peak level of +0.6 dBTP,
/// which is a clipped master rather than six tenths of headroom under the
/// ceiling — the one place where carrying the metric's own unit across would
/// turn a helpful reading into a false one.
///
/// Empty where [hasTarget] is false, because there is no delta to give a unit
/// to.
String deltaUnit(Metric metric) => switch (metric) {
  Metric.lufsIntegrated ||
  Metric.loudnessRange ||
  Metric.odrIntegrated ||
  Metric.odrShort => 'LU',
  Metric.truePeakMax => 'dB',
  _ => '',
};

/// One decimal with its sign spelled out, because a Δ without one is a number
/// with half its meaning missing. Negative zero is normalised — a reading
/// exactly on the line is not below it.
String formatDelta(double delta) {
  if (delta.isNaN) return '—';
  var text = delta.toStringAsFixed(1);
  if (text == '-0.0') text = '0.0';
  return delta.isNegative && text != '0.0' ? text : '+$text';
}
