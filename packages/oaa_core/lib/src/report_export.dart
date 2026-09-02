// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'metric.dart';
import 'report.dart';

/// The formats a report can be written as.
///
/// Decibel exports one, a `.txt` summary. Three is close to free once the
/// report is a plain object — and the other two are what make Open Audio
/// Analyzer usable from a release pipeline, which is the point at which a
/// metering tool stops being something you look at and starts being something
/// you can gate a build on.
enum ReportFormat {
  /// The human summary: what Decibel writes, laid out to be read.
  text('txt', 'Text report', 'text/plain'),

  /// Every measurement, the target verdict and the full timeline.
  /// Stable field names, so a script can depend on it.
  json('json', 'JSON', 'application/json'),

  /// The timeline, one row per sample point, for a spreadsheet or a plot.
  csv('csv', 'CSV timeline', 'text/csv');

  const ReportFormat(this.extension, this.label, this.mimeType);

  /// File extension, without the dot.
  final String extension;

  /// What a menu shows.
  final String label;

  final String mimeType;

  /// A filename for [report] in this format: `Rush (Live) — Open Audio Analyzer
  /// report.txt`.
  String suggestedFileName(AnalysisReport report) {
    final stem = report.fileName.contains('.')
        ? report.fileName.substring(0, report.fileName.lastIndexOf('.'))
        : report.fileName;
    return '$stem — Open Audio Analyzer report.$extension';
  }
}

/// Renders [report] in [format].
///
/// [naming] is how the text report labels the two dynamics readings; the
/// other two formats carry ids and do not have a spelling to choose.
String exportReport(
  AnalysisReport report,
  ReportFormat format, {
  DynamicsNaming naming = DynamicsNaming.defaultNaming,
}) => switch (format) {
  ReportFormat.text => exportReportText(report, naming: naming),
  ReportFormat.json => exportReportJson(report),
  ReportFormat.csv => exportReportCsv(report),
};

/// The human-readable report.
///
/// Values are right-aligned in a fixed column so that a row of numbers can be
/// scanned down rather than read across — the same reason every readout in the
/// app is monospaced with tabular figures. This is the artefact somebody
/// attaches to a delivery email, so it states what measured it and when.
/// The band a finite ODR-I falls in, per ODR Annex A.2.
///
/// Editorial by design, which is why it appears in the text report — the
/// artefact a person reads — and never in the JSON, which a script gates on
/// numbers. The names and their edges are the annex's, informative, and they
/// move with it rather than with the specification's version.
String _odrBand(double odrIntegrated) {
  if (odrIntegrated < 5) return 'flat';
  if (odrIntegrated < 8) return 'crushed';
  if (odrIntegrated < 10) return 'loud';
  if (odrIntegrated < 13) return 'balanced';
  if (odrIntegrated < 16) return 'dynamic';
  return 'wide';
}

String exportReportText(
  AnalysisReport report, {
  DynamicsNaming naming = DynamicsNaming.defaultNaming,
}) {
  final out = StringBuffer();

  void heading(String title) {
    out.writeln();
    out.writeln(title);
    out.writeln('─' * title.length);
    out.writeln();
  }

  void field(String name, String value) {
    out.writeln('  ${name.padRight(12)}$value');
  }

  final title = report.toolVersion.isEmpty
      ? 'Open Audio Analyzer — analysis report'
      : '${report.toolVersion} — analysis report';
  out.writeln(title);
  out.writeln('═' * title.length);
  out.writeln();

  field('File', report.fileName);
  if (report.filePath.isNotEmpty) field('Path', report.filePath);
  field('Format', report.describeSource());
  field('Duration', report.describeDuration());
  field('Analysed', _timestamp(report.generatedAt));

  heading('Measurements');

  for (final (metric, value) in report.summary) {
    final unit = metric.unit.isEmpty ? '' : ' ${metric.unit}';
    final band = metric == Metric.odrIntegrated && value.isFinite
        ? '  (${_odrBand(value)})'
        : '';
    out.writeln(
      '  ${metric.labelIn(naming).padRight(14)}'
      '${metric.format(value).padLeft(9)}$unit$band',
    );
  }

  // The percentiles LRA is the difference of. A range without the bounds it
  // was drawn between is a number you cannot check.
  if (report.loudnessRange.isFinite) {
    out.writeln();
    out.writeln(
      '  ${'LRA range'.padRight(14)}'
      '${report.loudnessRangeLow.toStringAsFixed(1)} … '
      '${report.loudnessRangeHigh.toStringAsFixed(1)} LUFS '
      '(10th–95th percentile)',
    );
  }

  if (report.channelPeakMax.isNotEmpty) {
    heading('Peak per channel');
    for (var c = 0; c < report.channelPeakMax.length; c++) {
      out.writeln(
        '  ${_channelName(c, report.channels).padRight(14)}'
        '${Metric.peak.format(report.channelPeakMax[c]).padLeft(9)} dBFS',
      );
    }
  }

  if (report.correlationMin.isFinite || report.correlationMax.isFinite) {
    heading('Stereo field');
    field(
      'Correlation',
      '${Metric.correlation.format(report.correlationMin)} … '
          '${Metric.correlation.format(report.correlationMax)}  '
          '(mean ${Metric.correlation.format(report.correlationMean)})',
    );
  }

  final target = report.calibration;
  if (target != null) {
    heading('Target — ${target.name}');

    for (final check in report.checks) {
      final unit = check.metric.unit.isEmpty ? '' : ' ${check.metric.unit}';

      // Value and unit are padded together, not separately. Padding only the
      // number leaves the columns after it stepping in and out by the
      // difference between "LUFS" and "LU", which is exactly the ragged edge
      // the tabular figures everywhere else in this product exist to avoid.
      final reading = '${check.metric.format(check.value).padLeft(9)}$unit';

      final line = StringBuffer()
        ..write('  ${check.metric.labelIn(naming).padRight(14)}')
        ..write(reading.padRight(15))
        ..write('required ${check.limitLabel.padRight(22)}')
        ..write(check.verdictLabel);

      if (check.deviation.isFinite) {
        line.write(' by ${check.deviation.toStringAsFixed(1)}');
      }
      out.writeln(line);
    }

    out.writeln();
    out.writeln('  VERDICT: ${report.isCompliant ? 'PASS' : 'FAIL'}');

    if (target.note.isNotEmpty) {
      out.writeln();
      out.writeln('  ${target.note}');
    }
  }

  return out.toString();
}

/// The full report as JSON, indented so a human can read a diff of it.
String exportReportJson(AnalysisReport report) =>
    const JsonEncoder.withIndent('  ').convert(report.toJson());

/// The timeline as CSV, one row per sample point.
///
/// The timeline rather than the summary, deliberately. A spreadsheet of
/// fourteen summary numbers is a worse JSON file, whereas the time series is
/// the thing CSV is actually good at — open it and you have a loudness plot.
/// The summary belongs in the text and JSON exports, which is where a reader
/// looking for one will go.
///
/// An unmeasured value is an empty cell rather than a zero or the string
/// "NaN". Empty is what every spreadsheet reads as "no data" and what every
/// plotting library skips; a zero would be drawn as a −0 LUFS spike.
String exportReportCsv(AnalysisReport report) {
  final out = StringBuffer()..writeln('seconds,lufs_m,lufs_s,true_peak_dbtp');

  for (final point in report.timeline) {
    out.writeln(
      '${point.seconds.toStringAsFixed(3)},'
      '${_cell(point.momentary)},'
      '${_cell(point.shortTerm)},'
      '${_cell(point.truePeak)}',
    );
  }

  return out.toString();
}

String _cell(double value) => value.isFinite ? value.toStringAsFixed(2) : '';

/// `2026-08-15 00:38:21 UTC`, which sorts and does not depend on a locale.
String _timestamp(DateTime when) {
  final utc = when.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}

/// The conventional name of channel [index] in a [channels]-wide layout.
///
/// Inferred from the channel count, exactly as the engine's loudness weighting
/// is, and with the same caveat: an interleaved buffer does not say which
/// channel is which. Four channels are read as quad rather than L R C LFE,
/// because labelling a surround channel "LFE" in a report is a claim about the
/// file that nothing verified.
String _channelName(int index, int channels) {
  const names = <int, List<String>>{
    1: ['Mono'],
    2: ['Left', 'Right'],
    4: ['Left', 'Right', 'Ls', 'Rs'],
    6: ['Left', 'Right', 'Centre', 'LFE', 'Ls', 'Rs'],
    8: ['Left', 'Right', 'Centre', 'LFE', 'Ls', 'Rs', 'Lb', 'Rb'],
  };

  final layout = names[channels];
  if (layout != null && index < layout.length) return layout[index];
  return 'Ch ${index + 1}';
}
