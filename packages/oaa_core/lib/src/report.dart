// SPDX-License-Identifier: MIT

import 'calibration.dart';
import 'metric.dart';

/// What a delivery check concluded.
enum ComplianceVerdict {
  /// Inside the target's limit.
  pass,

  /// Outside it. The report says by how much.
  fail,

  /// The engine did not measure this quantity, so there is nothing to judge.
  ///
  /// Deliberately not a pass. A check that silently passes because nothing
  /// measured it is how a file gets delivered on the strength of a test that
  /// never ran.
  notMeasured;

  bool get isPass => this == ComplianceVerdict.pass;
  bool get isFail => this == ComplianceVerdict.fail;
}

/// One line of the delivery verdict: what was measured, what was required, and
/// whether it met it.
///
/// [limitLabel] is a sentence rather than a number because the three checks
/// have three shapes — a target with a tolerance, a ceiling, and a maximum —
/// and rendering them from a bare double would mean the UI reimplementing the
/// distinction that this class already knows.
class ComplianceCheck {
  const ComplianceCheck({
    required this.metric,
    required this.value,
    required this.limitLabel,
    required this.verdict,
    this.deviation = double.nan,
  });

  final Metric metric;

  /// What was measured.
  final double value;

  /// What was required, as it should be printed: `−14.0 ±0.5 LUFS`.
  final String limitLabel;

  final ComplianceVerdict verdict;

  /// How far outside the limit, in the metric's own unit, or NaN when the
  /// check passed or could not run. Always positive when it means anything.
  final double deviation;

  /// The verdict as it appears in a text report.
  String get verdictLabel => switch (verdict) {
    ComplianceVerdict.pass => 'PASS',
    ComplianceVerdict.fail => 'FAIL',
    ComplianceVerdict.notMeasured => 'NOT MEASURED',
  };

  Map<String, Object?> toJson() => {
    'metric': metric.id,
    'value': value.isFinite ? value : null,
    'limit': limitLabel,
    'verdict': verdict.name,
    if (deviation.isFinite) 'deviation': deviation,
  };
}

/// A single point on the loudness graph a report draws.
class ReportTimelinePoint {
  const ReportTimelinePoint({
    required this.seconds,
    required this.momentary,
    required this.shortTerm,
    required this.truePeak,
  });

  final double seconds;
  final double momentary;
  final double shortTerm;
  final double truePeak;

  Map<String, Object?> toJson() => {
    'seconds': seconds,
    'lufs_m': momentary.isFinite ? momentary : null,
    'lufs_s': shortTerm.isFinite ? shortTerm : null,
    'tp': truePeak.isFinite ? truePeak : null,
  };

  factory ReportTimelinePoint.fromJson(Map<String, Object?> json) =>
      ReportTimelinePoint(
        seconds: (json['seconds']! as num).toDouble(),
        momentary: (json['lufs_m'] as num?)?.toDouble() ?? double.nan,
        shortTerm: (json['lufs_s'] as num?)?.toDouble() ?? double.nan,
        truePeak: (json['tp'] as num?)?.toDouble() ?? double.nan,
      );
}

/// The measured result of analysing one file, and what it means for a target.
///
/// This is the object every export writes and the report panel draws. It holds
/// no engine handle and no platform type, so it serialises to JSON, rides the
/// wire to a tablet, and is constructed in a test from literals. There is
/// deliberately no `fromJson`: nothing reads a report back, and a parser
/// written for symmetry is a parser nobody exercises. [ReportTimelinePoint] has
/// one because the graph needs it.
///
/// **A quantity the engine did not measure is NaN here**, exactly as it is in
/// the snapshot, and every export renders NaN as an em dash or a null rather
/// than as a zero. A report is the artefact somebody makes a delivery decision
/// from, so a fabricated zero in one is worse than a fabricated zero anywhere
/// else in the product.
class AnalysisReport {
  const AnalysisReport({
    required this.fileName,
    required this.filePath,
    required this.formatLabel,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.durationSeconds,
    required this.generatedAt,
    required this.lufsIntegrated,
    required this.loudnessRange,
    required this.loudnessRangeLow,
    required this.loudnessRangeHigh,
    required this.truePeakMax,
    required this.samplePeakMax,
    required this.momentaryMax,
    required this.shortTermMax,
    required this.shortTermMin,
    required this.correlationMin,
    required this.correlationMax,
    required this.correlationMean,
    required this.channelPeakMax,
    this.calibration,
    this.timeline = const [],
    this.toolVersion = '',
  });

  final String fileName;
  final String filePath;

  /// `WAV`, `FLAC`, `MP3`…
  final String formatLabel;

  final int sampleRate;
  final int channels;

  /// Source bit depth, or 0 for a lossy format where the question has no
  /// answer.
  final int bitsPerSample;

  final double durationSeconds;

  /// When the analysis was run. Recorded because a report is a document that
  /// outlives the session, and one that cannot say when it was produced cannot
  /// be told apart from a stale copy.
  final DateTime generatedAt;

  final double lufsIntegrated;
  final double loudnessRange;
  final double loudnessRangeLow;
  final double loudnessRangeHigh;
  final double truePeakMax;
  final double samplePeakMax;
  final double momentaryMax;
  final double shortTermMax;
  final double shortTermMin;
  final double correlationMin;
  final double correlationMax;
  final double correlationMean;

  /// Highest peak on each channel, dBFS. Length is [channels].
  final List<double> channelPeakMax;

  /// The target this was judged against, or null when it was measured without
  /// one. A report with no target still states every measurement; it just has
  /// no verdict to give.
  final Calibration? calibration;

  final List<ReportTimelinePoint> timeline;

  /// What produced this report, as `Open Audio Analyzer 0.5.0`.
  final String toolVersion;

  /// Peak to loudness ratio, LU. Derived, so it cannot disagree with its parts.
  double get peakToLoudnessRatio => truePeakMax - lufsIntegrated;

  /// `DR-I` as docs/METRICS.md defines it: true peak max minus integrated
  /// loudness. Not Decibel's proprietary TrueDyn and not claimed to match it.
  double get dynamicRangeIntegrated => truePeakMax - lufsIntegrated;

  /// The file's own description: `WAV 24-bit 48000 Hz, stereo`.
  String describeSource() {
    final depth = bitsPerSample > 0 ? ' $bitsPerSample-bit' : '';
    final layout = switch (channels) {
      1 => 'mono',
      2 => 'stereo',
      final n => '$n channels',
    };
    return '$formatLabel$depth $sampleRate Hz, $layout';
  }

  /// [durationSeconds] as `h:mm:ss.s`, or `m:ss.s` under an hour.
  String describeDuration() => formatDuration(durationSeconds);

  /// Every delivery check, in the order a report prints them.
  ///
  /// Empty when there is no [calibration] — a measurement without a target is
  /// still a measurement, and inventing a default target so the report has
  /// something to say would be asserting a delivery spec nobody chose.
  List<ComplianceCheck> get checks {
    final target = calibration;
    if (target == null) return const [];

    return [
      _loudnessCheck(target),
      _truePeakCheck(target),
      _loudnessRangeCheck(target),
    ];
  }

  /// Whether every check that could run passed.
  ///
  /// False when any check failed **or** when any could not run: a report that
  /// says "pass" while a check was skipped is the failure mode this whole file
  /// is written to avoid. Ask [checks] which it was.
  bool get isCompliant {
    final all = checks;
    if (all.isEmpty) return false;
    return all.every((check) => check.verdict.isPass);
  }

  ComplianceCheck _loudnessCheck(Calibration target) {
    final limit =
        '${target.lufsTarget.toStringAsFixed(1)} '
        '±${target.lufsTolerance.toStringAsFixed(1)} LUFS';

    if (lufsIntegrated.isNaN) {
      return ComplianceCheck(
        metric: Metric.lufsIntegrated,
        value: lufsIntegrated,
        limitLabel: limit,
        verdict: ComplianceVerdict.notMeasured,
      );
    }

    final offset = lufsIntegrated - target.lufsTarget;
    final passed = offset.abs() <= target.lufsTolerance;
    return ComplianceCheck(
      metric: Metric.lufsIntegrated,
      value: lufsIntegrated,
      limitLabel: limit,
      verdict: passed ? ComplianceVerdict.pass : ComplianceVerdict.fail,
      deviation: passed ? double.nan : offset.abs() - target.lufsTolerance,
    );
  }

  ComplianceCheck _truePeakCheck(Calibration target) {
    final limit = '≤ ${target.truePeakMax.toStringAsFixed(1)} dBTP';

    if (truePeakMax.isNaN) {
      return ComplianceCheck(
        metric: Metric.truePeakMax,
        value: truePeakMax,
        limitLabel: limit,
        verdict: ComplianceVerdict.notMeasured,
      );
    }

    final over = truePeakMax > target.truePeakMax;
    return ComplianceCheck(
      metric: Metric.truePeakMax,
      value: truePeakMax,
      limitLabel: limit,
      verdict: over ? ComplianceVerdict.fail : ComplianceVerdict.pass,
      deviation: over ? truePeakMax - target.truePeakMax : double.nan,
    );
  }

  ComplianceCheck _loudnessRangeCheck(Calibration target) {
    final limit = '≤ ${target.loudnessRangeMax.toStringAsFixed(1)} LU';

    if (loudnessRange.isNaN) {
      return ComplianceCheck(
        metric: Metric.loudnessRange,
        value: loudnessRange,
        limitLabel: limit,
        verdict: ComplianceVerdict.notMeasured,
      );
    }

    final over = loudnessRange > target.loudnessRangeMax;
    return ComplianceCheck(
      metric: Metric.loudnessRange,
      value: loudnessRange,
      limitLabel: limit,
      verdict: over ? ComplianceVerdict.fail : ComplianceVerdict.pass,
      deviation: over ? loudnessRange - target.loudnessRangeMax : double.nan,
    );
  }

  /// The programme-wide measurements, in report order, as metric/value pairs.
  ///
  /// Exists so the three exports and the panel iterate one list rather than
  /// each naming the same fields in the same order and drifting apart the first
  /// time one is added.
  ///
  /// **Each value appears once.** `PLR` and `DR-I` are the same subtraction —
  /// true peak max minus integrated loudness — and this list used to carry
  /// both, so a report printed one number twice under two names with nothing
  /// saying they were the same measurement. `PLR` is the spelling in wider use
  /// outside this project, so it is the one that stays; `docs/METRICS.md`
  /// documents the identity for anybody looking for the other.
  List<(Metric, double)> get summary => [
    (Metric.lufsIntegrated, lufsIntegrated),
    (Metric.loudnessRange, loudnessRange),
    (Metric.truePeakMax, truePeakMax),
    (Metric.samplePeakMax, samplePeakMax),
    (Metric.lufsMomentary, momentaryMax),
    (Metric.lufsShort, shortTermMax),
    (Metric.peakToLoudnessRatio, peakToLoudnessRatio),
    (Metric.correlation, correlationMean),
  ];

  Map<String, Object?> toJson() => {
    'tool': toolVersion,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'source': {
      'file': fileName,
      'path': filePath,
      'format': formatLabel,
      'sample_rate': sampleRate,
      'channels': channels,
      if (bitsPerSample > 0) 'bits_per_sample': bitsPerSample,
      'duration_seconds': durationSeconds,
    },
    'measurements': {
      'lufs_i': _json(lufsIntegrated),
      'lra': _json(loudnessRange),
      'lra_low': _json(loudnessRangeLow),
      'lra_high': _json(loudnessRangeHigh),
      'true_peak_max': _json(truePeakMax),
      'sample_peak_max': _json(samplePeakMax),
      'lufs_m_max': _json(momentaryMax),
      'lufs_s_max': _json(shortTermMax),
      'lufs_s_min': _json(shortTermMin),
      'plr': _json(peakToLoudnessRatio),
      'dr_i': _json(dynamicRangeIntegrated),
      'correlation_min': _json(correlationMin),
      'correlation_max': _json(correlationMax),
      'correlation_mean': _json(correlationMean),
      'channel_peak_max': channelPeakMax.map(_json).toList(),
    },
    if (calibration != null) ...{
      'target': calibration!.toJson(),
      'compliance': {
        'pass': isCompliant,
        'checks': checks.map((check) => check.toJson()).toList(),
      },
    },
    if (timeline.isNotEmpty)
      'timeline': timeline.map((point) => point.toJson()).toList(),
  };

  /// NaN and infinities become `null`.
  ///
  /// JSON has no NaN — `jsonEncode` throws on it — and the alternatives are
  /// worse than null: the string "NaN" makes every consumer parse doubles by
  /// hand, and 0 is a legitimate reading for correlation and several dB
  /// quantities, so it cannot double as "no data". A consumer reading null
  /// gets the same message the UI's em dash gives a human.
  static Object? _json(double value) => value.isFinite ? value : null;
}

/// [seconds] as `h:mm:ss.s`, or `m:ss.s` under an hour.
///
/// Shared by the report exports and the panel so a duration is not formatted
/// two ways in one product.
String formatDuration(double seconds) {
  if (!seconds.isFinite || seconds < 0) return '—';

  final totalTenths = (seconds * 10).round();
  final tenths = totalTenths % 10;
  final totalSeconds = totalTenths ~/ 10;
  final secs = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;

  final secsText = secs.toString().padLeft(2, '0');
  if (hours > 0) {
    final minutesText = minutes.toString().padLeft(2, '0');
    return '$hours:$minutesText:$secsText.$tenths';
  }
  return '$minutes:$secsText.$tenths';
}
