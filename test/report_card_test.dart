// SPDX-License-Identifier: GPL-3.0-or-later
//
// The card is the one export nobody can diff, so it is the one most likely to
// break silently. These tests assert the things that would make it useless
// without making it throw: that it is a real PNG, that it is opaque, and that
// it grows when the report has more to say.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:oaa/src/panels/report_card.dart';

AnalysisReport _report({
  Calibration? calibration,
  List<ReportTimelinePoint> timeline = const [],
  double lufsIntegrated = -14.2,
}) => AnalysisReport(
  fileName: 'Rush (Live).wav',
  filePath: '/music/Rush (Live).wav',
  formatLabel: 'WAV',
  sampleRate: 48000,
  channels: 2,
  bitsPerSample: 24,
  durationSeconds: 222.5,
  generatedAt: DateTime.utc(2026, 8, 15, 0, 38, 21),
  lufsIntegrated: lufsIntegrated,
  loudnessRange: 7.4,
  loudnessRangeLow: -18.9,
  loudnessRangeHigh: -11.5,
  truePeakMax: -1.4,
  samplePeakMax: -1.8,
  momentaryMax: -9.1,
  shortTermMax: -11.0,
  shortTermMin: -22.5,
  correlationMin: -0.2,
  correlationMax: 0.98,
  correlationMean: 0.61,
  channelPeakMax: const [-1.8, -1.9],
  calibration: calibration,
  timeline: timeline,
  toolVersion: 'Open Audio Analyzer 0.1.0',
);

List<ReportTimelinePoint> _timeline(int count) => [
  for (var i = 0; i < count; i++)
    ReportTimelinePoint(
      seconds: i * 0.1,
      momentary: -14.0 + (i % 7),
      shortTerm: -15.0 + (i % 5),
      truePeak: -2.0,
    ),
];

/// Decodes the PNG so the assertions are about the picture, not the bytes.
Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  const colors = OaaColors.precisionInstrument;

  test('renders a decodable PNG', () async {
    final bytes = await renderReportCard(_report(), colors);
    expect(bytes, isNotNull);

    // The eight-byte PNG signature. A file that is not this is not a PNG,
    // whatever extension it was saved under.
    expect(bytes!.sublist(0, 8), [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);

    final image = await _decode(bytes);
    expect(image.width, 1800, reason: '900 logical pixels at 2x');
    expect(image.height, greaterThan(200));
    image.dispose();
  });

  test('the background is opaque', () async {
    // A transparent card looks correct in the app that made it and unreadable
    // in a dark chat window, which is the only place it is ever going.
    final bytes = await renderReportCard(_report(), colors);
    final image = await _decode(bytes!);

    final data = await image.toByteData();
    // Top-left corner: past the margin, so it is background and nothing else.
    final alpha = data!.getUint8(3);
    expect(alpha, 255);
    image.dispose();
  });

  test('a report with a timeline is taller than one without', () async {
    final without = await renderReportCard(_report(), colors);
    final with_ = await renderReportCard(
      _report(timeline: _timeline(200)),
      colors,
    );

    final a = await _decode(without!);
    final b = await _decode(with_!);

    expect(
      b.height,
      greaterThan(a.height),
      reason: 'the graph has to be somewhere',
    );

    a.dispose();
    b.dispose();
  });

  test('a report with a target is taller than one without', () async {
    final without = await renderReportCard(_report(), colors);
    final with_ = await renderReportCard(
      _report(calibration: BuiltInCalibrations.streaming),
      colors,
    );

    final a = await _decode(without!);
    final b = await _decode(with_!);

    expect(b.height, greaterThan(a.height));

    a.dispose();
    b.dispose();
  });

  test('an unmeasured value renders without throwing', () async {
    // NaN reaches the card as an em dash. The failure this guards against is
    // not an ugly card but a layout that divides by a NaN and produces an
    // image of nothing at all.
    final bytes = await renderReportCard(
      _report(
        lufsIntegrated: double.nan,
        calibration: BuiltInCalibrations.streaming,
      ),
      colors,
    );

    expect(bytes, isNotNull);
    final image = await _decode(bytes!);
    expect(image.height, greaterThan(200));
    image.dispose();
  });
}
