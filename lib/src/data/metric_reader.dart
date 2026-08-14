// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';

/// Reads a [Metric] out of a [BelEngine].
///
/// This function is the only place the domain vocabulary meets the engine, and
/// it lives in the app rather than in either package on purpose: `bel_core`
/// must not depend on `bel_engine` (the tablet remote display has no engine at
/// all — it reads measurements off a socket), and `bel_engine` must not know
/// what a `Metric` is (the CLI and the plugin never draw one).
///
/// Phase 6 adds a second implementation of exactly this signature backed by the
/// wire protocol, and every module keeps working unchanged.
double readMetric(BelEngine engine, Metric metric) => switch (metric) {
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
  Metric.dynamicRangeShort => engine.dynamicRangeShort,
  Metric.dynamicRangeIntegrated => engine.dynamicRangeIntegrated,
  Metric.peakToLoudnessRatio => engine.peakToLoudnessRatio,
  Metric.peakToShortTermRatio => engine.peakToShortTermRatio,
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
  var loudest = kBelDbFloor;
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
    Metric.lufsIntegrated =>
      calibration.meetsLoudnessTarget(value)
          ? ReadingState.inSpec
          : ReadingState.neutral,

    Metric.truePeak || Metric.truePeakMax => _peakKind(value, calibration),

    // Sample peak has no true-peak headroom allowance, so anything at or above
    // full scale is already clipped by the time it is measured.
    Metric.samplePeakMax ||
    Metric.peak => value >= 0.0 ? ReadingState.over : ReadingState.neutral,

    Metric.loudnessRange =>
      calibration.exceedsLoudnessRange(value)
          ? ReadingState.over
          : ReadingState.neutral,

    // Anti-phase content is the thing a correlation meter exists to catch.
    Metric.correlation => value < 0 ? ReadingState.warn : ReadingState.neutral,

    _ => ReadingState.neutral,
  };
}

ReadingState _peakKind(double value, Calibration calibration) {
  if (calibration.exceedsTruePeak(value)) return ReadingState.over;
  // Within 1 dB of the ceiling is where a limiter starts mattering.
  if (value > calibration.truePeakMax - 1.0) return ReadingState.warn;
  return ReadingState.inSpec;
}
