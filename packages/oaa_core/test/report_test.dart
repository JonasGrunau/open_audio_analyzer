// SPDX-License-Identifier: GPL-3.0-or-later
//
// The report is the artefact somebody makes a delivery decision from, so the
// tests here are mostly about what it does with a number nobody measured. A
// report that renders NaN as 0.0, or passes a check it could not run, is worse
// than one that refuses to be written at all — it is wrong in a way that looks
// right.

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

AnalysisReport buildReport({
  double lufsIntegrated = -14.2,
  double loudnessRange = 7.4,
  double truePeakMax = -1.4,
  double samplePeakMax = -1.8,
  double momentaryMax = -9.1,
  double shortTermMax = -11.0,
  double shortTermMin = -22.5,
  double odrShortMin = 6.3,
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
  odrShortMin: odrShortMin,
  correlationMin: correlationMin,
  correlationMax: correlationMax,
  correlationMean: correlationMean,
  channelPeakMax: List<double>.filled(channels, -1.8),
  calibration: calibration,
  timeline: timeline,
  toolVersion: 'Open Audio Analyzer 0.1.0',
);

void main() {
  group('derived values', () {
    test('ODR-I is true peak max minus integrated loudness', () {
      final report = buildReport(truePeakMax: -1.0, lufsIntegrated: -14.0);
      expect(report.odrIntegrated, closeTo(13.0, 1e-9));
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

    // --- The dynamics floor ------------------------------------------------

    const dynamic = Calibration(
      id: 'house-dynamic',
      name: 'House, dynamic',
      lufsTarget: -14,
      lufsTolerance: 0.5,
      truePeakMax: -1,
      loudnessRangeMax: 20,
      odrIntegratedFloor: 8,
    );

    test('a target without a floor makes three checks, with one four', () {
      expect(
        buildReport(calibration: BuiltInCalibrations.streaming).checks,
        hasLength(3),
        reason: 'a row that always passed would read as a statement',
      );
      final checks = buildReport(calibration: dynamic).checks;
      expect(checks, hasLength(4));
      expect(checks.last.metric, Metric.odrIntegrated);
      expect(checks.last.limitLabel, '≥ 8.0 LU');
    });

    test('under the floor fails by the shortfall, over it passes', () {
      // −1.4 dBTP over −14.2 LUFS is an ODR-I of 12.8: comfortably dynamic.
      final open = buildReport(calibration: dynamic);
      expect(open.checks.last.verdict, ComplianceVerdict.pass);
      expect(open.checks.last.deviation.isNaN, isTrue);
      expect(open.isCompliant, isTrue);

      // −1.4 dBTP over −7.0 LUFS is an ODR-I of 5.6: squashed 2.4 LU past the
      // line. The deviation is positive, like every other check's — how far
      // onto the wrong side, whichever side that is.
      final squashed = buildReport(lufsIntegrated: -7.0, calibration: dynamic);
      final check = squashed.checks.last;
      expect(check.verdict, ComplianceVerdict.fail);
      expect(check.deviation, closeTo(2.4, 1e-9));
      expect(squashed.isCompliant, isFalse);
    });

    test('a floor with no integrated loudness is NOT MEASURED', () {
      final report = buildReport(
        lufsIntegrated: double.nan,
        calibration: dynamic,
      );
      expect(report.checks.last.verdict, ComplianceVerdict.notMeasured);
      expect(report.isCompliant, isFalse);
    });

    test(
      'an ODR-S floor is checked against the lowest ODR-S, and is a fifth line',
      () {
        // ODR-I of 12.8 and an ODR-S minimum of 6.3: the programme as a whole has
        // plenty of room, and its most squeezed three seconds have not. That is
        // the case the second floor exists for — one quiet intro rescues the
        // first number and nothing rescues the second.
        const strict = Calibration(
          id: 'house-strict',
          name: 'House, strict',
          lufsTarget: -14,
          lufsTolerance: 0.5,
          truePeakMax: -1,
          loudnessRangeMax: 20,
          odrIntegratedFloor: 8,
          odrShortFloor: 8,
        );
        final report = buildReport(calibration: strict);
        expect(report.checks, hasLength(5));

        final plr = report.checks[3];
        expect(plr.metric, Metric.odrIntegrated);
        expect(plr.verdict, ComplianceVerdict.pass);

        final psr = report.checks[4];
        expect(psr.metric, Metric.odrShort);
        expect(psr.value, 6.3);
        expect(psr.verdict, ComplianceVerdict.fail);
        expect(psr.deviation, closeTo(1.7, 1e-9));
        expect(report.isCompliant, isFalse);

        expect(
          buildReport(
            odrShortMin: double.nan,
            calibration: strict,
          ).checks.last.verdict,
          ComplianceVerdict.notMeasured,
        );
      },
    );

    test('the summary carries the lowest ODR-S under the ODR-S label', () {
      final summary = buildReport(odrShortMin: 5.5).summary;
      final row = summary.firstWhere((entry) => entry.$1 == Metric.odrShort);
      expect(row.$2, 5.5);
      expect(
        exportReportJson(buildReport(odrShortMin: 5.5)),
        contains('"odr_s_min": 5.5'),
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

      expect(text, contains('Open Audio Analyzer 0.1.0 — analysis report'));
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

    test('gives ODR-I its Annex A band word, in the text alone', () {
      // The default report reads 12.8 LU. The bands are half-open at the top,
      // so exactly 13.0 is dynamic's, not balanced's.
      expect(exportReportText(buildReport()), contains('(balanced)'));
      expect(
        exportReportText(buildReport(truePeakMax: -1.0, lufsIntegrated: -14.0)),
        contains('(dynamic)'),
      );
      expect(exportReportJson(buildReport()), isNot(contains('balanced')));
    });

    test('an undefined PLR gets no band word', () {
      final text = exportReportText(buildReport(lufsIntegrated: double.nan));
      final line = text
          .split('\n')
          .firstWhere((l) => l.trimLeft().startsWith('PLR'));
      expect(line, contains('—'));
      expect(line, isNot(contains('(')));
    });

    test('the text report labels the dynamics readings as asked', () {
      // The default is the AES pair, which is what a person reading the report
      // is looking for; the specification's own names are one argument away
      // and change nothing but the label — the JSON carries ids and has no
      // spelling to choose.
      final report = buildReport(truePeakMax: -1.0, lufsIntegrated: -14.0);
      final aes = exportReportText(report);
      expect(aes, contains('PLR'));
      expect(aes, contains('PSR'));
      expect(aes, isNot(contains('ODR-')));

      final odr = exportReportText(report, naming: DynamicsNaming.odr);
      expect(odr, contains('ODR-I'));
      expect(odr, contains('ODR-S'));
      expect(odr, isNot(contains('PLR')));
      expect(odr, isNot(contains('PSR')));
      expect(
        exportReport(report, ReportFormat.text, naming: DynamicsNaming.odr),
        odr,
      );
      expect(
        exportReport(report, ReportFormat.json, naming: DynamicsNaming.odr),
        exportReportJson(report),
      );
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
        'Rush (Live) — Open Audio Analyzer report.txt',
      );
      expect(
        ReportFormat.json.suggestedFileName(report),
        'Rush (Live) — Open Audio Analyzer report.json',
      );
      expect(
        ReportFormat.csv.suggestedFileName(report),
        'Rush (Live) — Open Audio Analyzer report.csv',
      );
    });
  });
}
