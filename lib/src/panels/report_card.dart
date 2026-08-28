// The report as a picture.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A PNG of the analysis, for pasting into the message where somebody asks
// whether the master is ready. The text and JSON exports are what a pipeline
// reads; this is what a human sends to another human, and the two audiences
// want different things — nobody pastes a CSV into a chat window and nobody
// greps a PNG.
//
// ---------------------------------------------------------------------------
// Why this is not a screenshot of the panel
//
// Capturing the panel through a RepaintBoundary would have been fewer lines and
// would have produced a worse artefact: the image would inherit the panel's
// scroll position, its width, and whatever the window happened to be sized to,
// so two people exporting the same report would get different pictures and one
// of them would be cropped. Drawing it here means the card is a fixed,
// deliberate layout that says the same thing every time.
//
// It also has to live in `lib/` rather than beside the other exports in
// `oaa_core`, because rendering needs `dart:ui` and `oaa_core` is the package
// three engine-less consumers depend on. A `Canvas` in there would drag Flutter
// into all of them.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/painting.dart';

/// Fixed so that every card is the same size regardless of the window that
/// produced it. 2x for a display that will show it at half this.
const double _cardWidth = 900;
const double _scale = 2;

/// Renders [report] as PNG bytes.
///
/// [colors] is the palette in force, so a card exported from a light skin is
/// light. Returns null only if the encoder does, which it does not in practice.
Future<Uint8List?> renderReportCard(
  AnalysisReport report,
  OaaColors colors,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(_scale);

  final height = _paint(canvas, report, colors);

  // The background goes on last, with `dstOver`, which paints it *behind*
  // everything already drawn. Drawing it first would have meant guessing a
  // height before the layout had run and cropping the excess — which works
  // until a report is one row taller than the guess and the bottom of the card
  // comes out transparent.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, _cardWidth, height),
    Paint()
      ..color = colors.background
      ..blendMode = BlendMode.dstOver,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (_cardWidth * _scale).round(),
    (height * _scale).round(),
  );

  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    // Both hold GPU-side resources. The persistence layers taught this project
    // the cost of not disposing one.
    image.dispose();
    picture.dispose();
  }
}

/// Draws the card and returns the height it used.
///
/// Laid out top-down with a running cursor rather than by a widget tree,
/// because there is no tree here — this runs offscreen, against a raw Canvas.
double _paint(Canvas canvas, AnalysisReport report, OaaColors colors) {
  const left = Space.xl;
  const right = _cardWidth - Space.xl;

  var y = Space.xl;

  void rule() {
    canvas.drawLine(
      Offset(left, y),
      Offset(right, y),
      Paint()
        ..color = colors.hairline
        ..strokeWidth = OaaStroke.hairline,
    );
    y += Space.md;
  }

  double draw(
    String text,
    TextStyle style, {
    double x = left,
    TextAlign align = TextAlign.left,
    double? width,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width ?? (right - x));

    final dx = align == TextAlign.right ? x - painter.width : x;
    painter.paint(canvas, Offset(dx, y));
    final used = painter.height;
    painter.dispose();
    return used;
  }

  // --- Header -------------------------------------------------------------
  y += draw(
    report.fileName,
    OaaType.reading(26).copyWith(color: colors.textPrimary),
  );
  y += Space.xs;
  y += draw(
    '${report.describeSource()}  ·  ${report.describeDuration()}',
    OaaType.body.copyWith(color: colors.textMuted),
  );
  y += Space.lg;
  rule();

  // --- The headline numbers -----------------------------------------------
  const headline = [
    Metric.lufsIntegrated,
    Metric.loudnessRange,
    Metric.truePeakMax,
    Metric.odrIntegrated,
  ];
  final values = [
    report.lufsIntegrated,
    report.loudnessRange,
    report.truePeakMax,
    report.odrIntegrated,
  ];

  const columnWidth = (right - left) / 4;
  final headlineTop = y;
  var headlineHeight = 0.0;

  for (var i = 0; i < headline.length; i++) {
    final x = left + columnWidth * i;
    y = headlineTop;

    y += draw(
      headline[i].label,
      OaaType.caption.copyWith(color: colors.textFaint),
      x: x,
      width: columnWidth,
    );
    y += Space.xxs;

    final value = values[i];
    y += draw(
      '${headline[i].format(value)}${headline[i].unit.isEmpty ? '' : ' ${headline[i].unit}'}',
      OaaType.reading(
        22,
      ).copyWith(color: value.isNaN ? colors.textFaint : colors.textPrimary),
      x: x,
      width: columnWidth,
    );

    headlineHeight = y - headlineTop;
  }

  y = headlineTop + headlineHeight + Space.lg;
  rule();

  // --- Loudness over time -------------------------------------------------
  if (report.timeline.length > 1) {
    y += draw(
      'SHORT-TERM LOUDNESS',
      OaaType.caption.copyWith(color: colors.textFaint),
    );
    y += Space.sm;
    // Inset from the left by a gutter, because the graph draws its LUFS scale
    // outside its own rect. Without it the axis labels are laid out at a
    // negative x and clipped away at the edge of the card.
    const gutter = Space.xl;
    _paintGraph(
      canvas,
      report,
      colors,
      Rect.fromLTWH(left + gutter, y, right - left - gutter, 150),
    );
    y += 150 + Space.lg;
    rule();
  }

  // --- Every other measurement --------------------------------------------
  for (final (metric, value) in report.summary) {
    if (headline.contains(metric)) continue;

    final rowTop = y;
    final used = draw(
      metric.label,
      OaaType.body.copyWith(color: colors.textMuted),
    );
    y = rowTop;
    draw(
      '${metric.format(value)}${metric.unit.isEmpty ? '' : ' ${metric.unit}'}',
      OaaType.readingSmall.copyWith(
        color: value.isNaN ? colors.textFaint : colors.textPrimary,
      ),
      x: right,
      align: TextAlign.right,
      width: 200,
    );
    y = rowTop + used + Space.xs;
  }

  // --- The verdict --------------------------------------------------------
  final target = report.calibration;
  if (target != null) {
    y += Space.sm;
    rule();

    y += draw(
      'TARGET — ${target.name.toUpperCase()}',
      OaaType.caption.copyWith(color: colors.textFaint),
    );
    y += Space.sm;

    for (final check in report.checks) {
      final rowTop = y;
      final used = draw(
        check.metric.label,
        OaaType.body.copyWith(color: colors.textMuted),
      );

      y = rowTop;
      draw(
        '${check.metric.format(check.value)}   required ${check.limitLabel}',
        OaaType.readingSmall.copyWith(color: colors.textPrimary),
        x: right - 90,
        align: TextAlign.right,
        width: 420,
      );

      y = rowTop;
      draw(
        check.verdictLabel,
        OaaType.caption.copyWith(
          color: switch (check.verdict) {
            ComplianceVerdict.pass => colors.accent,
            ComplianceVerdict.fail => colors.over,
            ComplianceVerdict.notMeasured => colors.textFaint,
          },
        ),
        x: right,
        align: TextAlign.right,
        width: 120,
      );

      y = rowTop + used + Space.xs;
    }
  }

  // --- Provenance ---------------------------------------------------------
  // A card that cannot say what measured it, or when, cannot be told apart
  // from a stale copy of itself.
  y += Space.lg;
  rule();
  y += draw(
    '${report.toolVersion.isEmpty ? 'Open Audio Analyzer' : report.toolVersion}  ·  '
    'ITU-R BS.1770-4 / EBU R 128  ·  '
    '${report.generatedAt.toUtc().toIso8601String().split('.').first}Z',
    OaaType.caption.copyWith(color: colors.textFaint),
  );

  return y + Space.xl;
}

/// The short-term loudness curve, with the integrated level marked.
///
/// The same fixed 0 to −40 LUFS window the panel's graph uses, so a card and
/// the screen it came from are the same picture.
void _paintGraph(
  Canvas canvas,
  AnalysisReport report,
  OaaColors colors,
  Rect area,
) {
  const top = 0.0;
  const bottom = -40.0;

  double toY(double lufs) =>
      area.top + area.height * (top - lufs.clamp(bottom, top)) / (top - bottom);

  final grid = Paint()
    ..color = colors.hairline
    ..strokeWidth = OaaStroke.hairline;

  for (var lufs = top; lufs >= bottom; lufs -= 10) {
    final y = toY(lufs);
    canvas.drawLine(Offset(area.left, y), Offset(area.right, y), grid);

    final label = TextPainter(
      text: TextSpan(
        text: lufs.toStringAsFixed(0),
        style: OaaType.tick.copyWith(color: colors.textFaint),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(area.left - label.width - Space.xs, y - 5));
    label.dispose();
  }

  final duration = report.timeline.last.seconds;
  if (duration <= 0) return;

  final path = Path();
  var started = false;
  for (final point in report.timeline) {
    if (point.shortTerm.isNaN) continue;
    final x = area.left + area.width * (point.seconds / duration);
    final y = toY(point.shortTerm);
    started ? path.lineTo(x, y) : path.moveTo(x, y);
    started = true;
  }

  if (started) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.mark
        ..color = colors.meterFill,
    );
  }

  if (report.lufsIntegrated.isFinite) {
    final y = toY(report.lufsIntegrated);
    canvas.drawLine(
      Offset(area.left, y),
      Offset(area.right, y),
      Paint()
        ..color = colors.accent
        ..strokeWidth = OaaStroke.hairline,
    );
  }
}
