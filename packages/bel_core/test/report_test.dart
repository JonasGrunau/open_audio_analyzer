// SPDX-License-Identifier: MIT
//
// The report is the artefact somebody makes a delivery decision from, so the
// tests here are mostly about what it does with a number nobody measured. A
// report that renders NaN as 0.0, or passes a check it could not run, is worse
// than one that refuses to be written at all — it is wrong in a way that looks
// right.

import 'package:bel_core/bel_core.dart';
import 'package:test/test.dart';

AnalysisReport buildReport({
  double lufsIntegrated = -14.2,
  double loudnessRange = 7.4,
  double truePeakMax = -1.4,
  double samplePeakMax = -1.8,
  double momentaryMax = -9.1,
  double shortTermMax = -11.0,
  double shortTermMin = -22.5,
  double correlationMin = -0.2,
  double correlationMax = 0.98,
  double correlationMean = 0.61,
  Calibration? calibration,
  List<ReportTimelinePoint> timeline = const [],
  int channels = 2,
}) => AnalysisReport(
  fileName: 'Rush (Live).wav',
  filePath: '/music/Rush (Live).wav',
  formatLabel: 'WAV',
  sampleRate: 48000,
  channels: channels,
  bitsPerSample: 24,
  durationSeconds: 222.5,
  generatedAt: DateTime.utc(2026, 8, 15, 0, 38, 21),
  lufsIntegrated: lufsIntegrated,
  loudnessRange: loudnessRange,
  loudnessRangeLow: -18.9,
  loudnessRangeHigh: -11.5,
  truePeakMax: truePeakMax,
  samplePeakMax: samplePeakMax,
  momentaryMax: momentaryMax,
  shortTermMax: shortTermMax,
  shortTermMin: shortTermMin,
  correlationMin: correlationMin,
  correlationMax: correlationMax,
  correlationMean: correlationMean,
  channelPeakMax: List<double>.filled(channels, -1.8),
  calibration: calibration,
  timeline: timeline,
  toolVersion: 'Bel 0.1.0',
);

void main() {
  group('derived values', () {
    test('PLR is true peak max minus integrated loudness', () {
      final report = buildReport(truePeakMax: -1.0, lufsIntegrated: -14.0);
      expect(report.peakToLoudnessRatio, closeTo(13.0, 1e-9));
      expect(report.dynamicRangeIntegrated, closeTo(13.0, 1e-9));
    });

    test('source description names container, depth, rate and layout', () {
      expect(buildReport().describeSource(), 'WAV 24-bit 48000 Hz, stereo');
    });

    test('duration is m:ss.s under an hour and h:mm:ss.s over', () {
      expect(formatDuration(222.5), '3:42.5');
      expect(formatDuration(3821.4), '1:03:41.4');
      expect(formatDuration(9.06), '0:09.1');
      expect(formatDuration(double.nan), '—');
    });
  });

  group('compliance', () {
    test('a reading inside the tolerance passes', () {
      final report = buildReport(
        lufsIntegrated: -14.3,
        truePeakMax: -1.4,
        loudnessRange: 7.4,
        calibration: BuiltInCalibrations.streaming,
      );

      expect(report.isCompliant, isTrue);
      expect(report.checks.every((c) => c.verdict.isPass), isTrue);
    });

    test('a reading outside the tolerance fails and says by how much', () {
      final report = buildReport(
        lufsIntegrated: -12.0, // target -14.0 +-0.5
        calibration: BuiltInCalibrations.streaming,
      );

      final check = report.checks.firstWhere(
        (c) => c.metric == Metric.lufsIntegrated,
      );
      expect(check.verdict, ComplianceVerdict.fail);
      expect(check.deviation, closeTo(1.5, 1e-9), reason: '2.0 over, 0.5 free');
      expect(report.isCompliant, isFalse);
    });

    test('true peak over the ceiling fails by the overshoot', () {
      final report = buildReport(
        truePeakMax: -0.4,
        calibration: BuiltInCalibrations.streaming, // -1.0 dBTP
      );

      final check = report.checks.firstWhere(
        (c) => c.metric == Metric.truePeakMax,
      );
      expect(check.verdict, ComplianceVerdict.fail);
      expect(check.deviation, closeTo(0.6, 1e-9));
    });

    test('exactly on the ceiling passes — the limit is inclusive', () {
      final report = buildReport(
        truePeakMax: -1.0,
        calibration: BuiltInCalibrations.streaming,
      );
      expect(
        report.checks.firstWhere((c) => c.metric == Metric.truePeakMax).verdict,
        ComplianceVerdict.pass,
      );
    });

    test('an unmeasured value is NOT MEASURED, never a pass', () {
      final report = buildReport(
        lufsIntegrated: double.nan,
        calibration: BuiltInCalibrations.streaming,
      );

      final check = report.checks.firstWhere(
        (c) => c.metric == Metric.lufsIntegrated,
      );
      expect(check.verdict, ComplianceVerdict.notMeasured);
      expect(
        report.isCompliant,
        isFalse,
        reason: 'a check that never ran must not read as a pass',
      );
    });

    test('no target means no checks and no verdict', () {
      final report = buildReport();
      expect(report.checks, isEmpty);
      expect(
        report.isCompliant,
        isFalse,
        reason: 'nothing was checked, so nothing passed',
      );
    });
  });

  group('JSON export', () {
    test('round-trips through a decoder without throwing on NaN', () {
      final report = buildReport(
        lufsIntegrated: double.nan,
        calibration: BuiltInCalibrations.ebuR128,
      );

      final text = exportReportJson(report);
      expect(text, contains('"lufs_i": null'));
      expect(text, isNot(contains('NaN')));
    });

    test('carries the target and the verdict', () {
      final report = buildReport(calibration: BuiltInCalibrations.podcast);
      final text = exportReportJson(report);

      expect(text, contains('"id": "podcast-16"'));
      expect(text, contains('"compliance"'));
      expect(text, contains('"verdict"'));
    });

    test('omits the timeline when there is none', () {
      expect(exportReportJson(buildReport()), isNot(contains('"timeline"')));
    });
  });

  group('text export', () {
    test('states what measured it, when, and what it measured', () {
      final report = buildReport(calibration: BuiltInCalibrations.streaming);
      final text = exportReportText(report);

      expect(text, contains('Bel 0.1.0 — analysis report'));
      expect(text, contains('Rush (Live).wav'));
      expect(text, contains('WAV 24-bit 48000 Hz, stereo'));
      expect(text, contains('3:42.5'));
      expect(text, contains('2026-08-15 00:38:21 UTC'));
      expect(text, contains('VERDICT:'));
    });

    test('renders an unmeasured value as an em dash, never as zero', () {
      final text = exportReportText(buildReport(loudnessRange: double.nan));
      expect(text, contains('—'));
      expect(text, isNot(contains('LRA              0.0')));
    });

    test('names stereo channels rather than numbering them', () {
      final text = exportReportText(buildReport());
      expect(text, contains('Left'));
      expect(text, contains('Right'));
    });

    test('falls back to numbered channels for an unusual layout', () {
      final text = exportReportText(buildReport(channels: 3));
      expect(text, contains('Ch 3'));
    });

    test('shows the percentiles LRA was drawn between', () {
      final text = exportReportText(buildReport());
      expect(text, contains('10th–95th percentile'));
    });
  });

  group('CSV export', () {
    test('writes a header and one row per timeline point', () {
      final report = buildReport(
        timeline: const [
          ReportTimelinePoint(
            seconds: 0.0,
            momentary: double.nan,
            shortTerm: double.nan,
            truePeak: -18.0,
          ),
          ReportTimelinePoint(
            seconds: 0.5,
            momentary: -12.25,
            shortTerm: -14.5,
            truePeak: -1.25,
          ),
        ],
      );

      final lines = exportReportCsv(report).trim().split('\n');
      expect(lines.first, 'seconds,lufs_m,lufs_s,true_peak_dbtp');
      expect(lines[1], '0.000,,,-18.00');
      expect(lines[2], '0.500,-12.25,-14.50,-1.25');
    });

    test('an unmeasured value is an empty cell, not a zero', () {
      final report = buildReport(
        timeline: const [
          ReportTimelinePoint(
            seconds: 1.0,
            momentary: double.nan,
            shortTerm: double.nan,
            truePeak: double.nan,
          ),
        ],
      );
      expect(exportReportCsv(report), contains('1.000,,,'));
    });
  });

  group('filenames', () {
    test('suggested names keep the stem and swap the extension', () {
      final report = buildReport();
      expect(
        ReportFormat.text.suggestedFileName(report),
        'Rush (Live) — Bel report.txt',
      );
      expect(
        ReportFormat.json.suggestedFileName(report),
        'Rush (Live) — Bel report.json',
      );
      expect(
        ReportFormat.csv.suggestedFileName(report),
        'Rush (Live) — Bel report.csv',
      );
    });
  });
}
