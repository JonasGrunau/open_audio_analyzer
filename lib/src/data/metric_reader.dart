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
    Metric.correlation => value < 0 ? ReadingState.warn : ReadingState.neutral,

    _ => ReadingState.neutral,
  };
}

ReadingState _floorKind(double value, double? floor) {
  if (floor == null) return ReadingState.neutral;
  if (value < floor) return ReadingState.over;
  // Within 1 LU of the floor is where the next pass of the limiter takes it
  // under — the same margin the peak ceiling warns at.
  if (value < floor + 1.0) return ReadingState.warn;
  return ReadingState.inSpec;
}

ReadingState _peakKind(double value, Calibration calibration) {
  if (calibration.exceedsTruePeak(value)) return ReadingState.over;
  // Within 1 dB of the ceiling is where a limiter starts mattering.
  if (value > calibration.truePeakMax - 1.0) return ReadingState.warn;
  return ReadingState.inSpec;
}
