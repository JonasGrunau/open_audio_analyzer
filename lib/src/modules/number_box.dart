// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Displays any single measurement as a number.
///
/// The simplest of the fourteen modules, and therefore the one that establishes
/// the pattern all the others follow:
///
///   - The widget is the **body only**. Its title bar, border, menu affordance
///     and selection state belong to the `ModuleFrame` the canvas wraps it in,
///     so that fourteen modules cannot drift into fourteen slightly different
///     frames.
///   - The widget builds **once**. It rebuilds only when the palette or the
///     target changes, never because a measurement did.
///   - The painter is handed [MeterClock] as its `repaint` listenable, so a new
///     reading re-rasters it without touching the element tree.
///   - Laid-out text is cached in [ReadoutPainter], which lives in the State so
///     it survives the painter being recreated on a theme change.
///
/// The result is that a screen of forty of these costs forty `paint` calls per
/// frame and zero rebuilds.
class NumberBoxModule extends StatefulWidget {
  const NumberBoxModule({
    required this.engine,
    required this.clock,
    required this.metric,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Metric metric;
  final Calibration calibration;

  @override
  State<NumberBoxModule> createState() => _NumberBoxModuleState();
}

class _NumberBoxModuleState extends State<NumberBoxModule> {
  /// Held here rather than in the painter: painters are recreated whenever
  /// `build` runs, and throwing away laid-out paragraphs on every theme change
  /// would defeat the point of caching them.
  late final ReadoutPainter _readout = ReadoutPainter(
    valueStyle: OaaType.reading(32),
    unitStyle: OaaType.unit,
    labelStyle: OaaType.label,
  );

  @override
  void dispose() {
    _readout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return CustomPaint(
      painter: _NumberBoxPainter(
        engine: widget.engine,
        metric: widget.metric,
        calibration: widget.calibration,
        colors: colors,
        readout: _readout,
        repaint: widget.clock,
      ),
      // Without this the CustomPaint has no intrinsic size and collapses.
      child: const SizedBox.expand(),
    );
  }
}

class _NumberBoxPainter extends MeterPainter {
  _NumberBoxPainter({
    required this.engine,
    required this.metric,
    required this.calibration,
    required this.colors,
    required this.readout,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final MeterSource engine;
  final Metric metric;
  final Calibration calibration;
  final OaaColors colors;
  final ReadoutPainter readout;

  @override
  void paint(Canvas canvas, Size size) {
    // No size guard here. Below `ModuleKind.numberBox.minBodyHeight` the frame
    // has already substituted the "too small" placeholder — the guard used to
    // live here and silently drew nothing, which is how six empty Number Boxes
    // shipped on a 1024x640 window.
    final value = readMetric(engine, metric);
    final state = classify(metric, value, calibration);
    final color = colorForState(state, colors);

    // Scale the number to the box rather than fixing it, so a Number Box works
    // both as a two-cell chip and as the one big readout on a tab.
    final fontSize = (size.height * 0.62).clamp(14.0, 72.0);

    final valueParagraph = readout.value(
      metric.format(value),
      color,
      fontSize,
      size.width,
    );

    final unitText = metric.unit;
    final hasUnit = unitText.isNotEmpty && state != ReadingState.unavailable;

    final top = (size.height - valueParagraph.height) / 2;

    final unitParagraph = hasUnit
        ? readout.unit(unitText, colors.textMuted, size.width)
        : null;

    // **The value and its unit are one object, and it is centred as one.**
    // Drawn from x = 0 the number hugged the left edge of a box it rarely
    // fills — most obviously on an unavailable reading, where a single em dash
    // sat alone in the corner of a four-cell tile and read as a rendering
    // fault rather than as "not measured yet". The unit rides along, so the
    // group stays centred whether or not there is one.
    final unitWidth = unitParagraph == null
        ? 0.0
        : Space.xs + unitParagraph.longestLine;
    final groupWidth = valueParagraph.longestLine + unitWidth;
    final left = groupWidth <= size.width ? (size.width - groupWidth) / 2 : 0.0;

    canvas.drawParagraph(valueParagraph, Offset(left, top));

    if (unitParagraph != null) {
      // Sit the unit on the value's baseline. Centring it against the value's
      // box instead is the usual shortcut and it always looks slightly wrong,
      // because a unit's x-height and a digit's cap-height do not agree.
      final unitLeft = left + valueParagraph.longestLine + Space.xs;
      final baseline =
          top +
          valueParagraph.alphabeticBaseline -
          unitParagraph.alphabeticBaseline;

      if (unitLeft + unitParagraph.longestLine <= size.width) {
        canvas.drawParagraph(unitParagraph, Offset(unitLeft, baseline));
      }
    }
  }

  /// Only consulted when the widget rebuilds and hands over a *new* painter —
  /// a theme or target change. New measurements arrive through `repaint`
  /// instead and never reach this method.
  @override
  bool shouldRepaint(_NumberBoxPainter oldDelegate) =>
      oldDelegate.metric != metric ||
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}

/// The elapsed measurement clock, painted rather than built.
///
/// It would be entirely reasonable to write this as a `Text` inside a
/// `ListenableBuilder`, and it would also rebuild a widget every single frame
/// forever. One is not many, but the status bar is exactly where that habit
/// starts.
class ElapsedReadout extends StatefulWidget {
  const ElapsedReadout({required this.engine, required this.clock, super.key});

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<ElapsedReadout> createState() => _ElapsedReadoutState();
}

class _ElapsedReadoutState extends State<ElapsedReadout> {
  ui.Paragraph? _paragraph;
  String? _text;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    return SizedBox(
      width: 72,
      height: 16,
      child: CustomPaint(
        painter: _ElapsedPainter(
          engine: widget.engine,
          colors: colors,
          state: this,
          repaint: widget.clock,
        ),
      ),
    );
  }

  ui.Paragraph paragraphFor(String text, Color color) {
    if (_paragraph == null || _text != text) {
      _text = text;
      final builder =
          ui.ParagraphBuilder(
              OaaType.readingSmall.getParagraphStyle(
                textAlign: TextAlign.right,
                maxLines: 1,
              ),
            )
            ..pushStyle(
              OaaType.readingSmall.copyWith(color: color).getTextStyle(),
            )
            ..addText(text);
      _paragraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 72));
    }
    return _paragraph!;
  }
}

class _ElapsedPainter extends MeterPainter {
  _ElapsedPainter({
    required this.engine,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _ElapsedReadoutState state;

  @override
  void paint(Canvas canvas, Size size) {
    final paragraph = state.paragraphFor(
      _format(engine.elapsedSeconds),
      colors.textMuted,
    );
    // **Centred in the box, not drawn from its top-left.** The box is taller
    // than the line it holds, and drawn at the origin every one of those spare
    // pixels lands *under* the digits: the clock rode two pixels above the
    // optical centre of every label beside it in the bar — including the
    // sample-rate readout three items to its left, which is the same
    // `readingSmall` style and lands where it should because it is a `Text`.
    //
    // A `Text` centres its own line box in whatever the Row gives it. Anything
    // painted has to do that itself, and a painted readout that skips it is
    // misaligned by however much slack the box happens to have.
    canvas.drawParagraph(
      paragraph,
      Offset(0, (size.height - paragraph.height) / 2),
    );
  }

  static String _format(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '--:--:--';
    final total = seconds.floor();
    final h = (total ~/ 3600).toString().padLeft(2, '0');
    final m = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  bool shouldRepaint(_ElapsedPainter oldDelegate) =>
      oldDelegate.colors != colors;
}
