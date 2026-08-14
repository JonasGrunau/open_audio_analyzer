// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clock/meter_clock.dart';
import '../data/providers.dart';
import '../modules/number_box.dart';

/// The application root.
class BelApp extends ConsumerWidget {
  const BelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const colors = BelColors.precisionInstrument;

    return MaterialApp(
      title: 'Bel',
      debugShowCheckedModeBanner: false,
      theme: belThemeData(colors),
      home: const BelTheme(colors: colors, child: _Workspace()),
    );
  }
}

/// Owns the engine and the clock.
///
/// They are created here rather than in a provider because both are tied to
/// this element's lifetime and to its [TickerProvider]: the engine owns a
/// native thread that must be stopped when the widget goes away, and the clock
/// needs a vsync. A provider would offer nothing except a second place for the
/// disposal to be forgotten.
class _Workspace extends StatefulWidget {
  const _Workspace();

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace>
    with SingleTickerProviderStateMixin {
  BelEngine? _engine;
  MeterClock? _clock;
  String? _failure;

  @override
  void initState() {
    super.initState();
    try {
      final engine = BelEngine.start(source: BelSource.testTone);
      _engine = engine;
      _clock = MeterClock(engine: engine, vsync: this);
    } on BelEngineException catch (error) {
      // Showing the reason beats a blank window. The most likely cause by far
      // is a stale native library after a change to bel.h, and the exception
      // says so.
      _failure = error.message;
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final engine = _engine;
    final clock = _clock;

    // Bel draws almost nothing with Material, but the few stock widgets it does
    // use — popup menus, tooltips — assert on having a Material ancestor and
    // throw at runtime without one. A bare `Material` costs nothing and is
    // cheaper than reimplementing menus to avoid it.
    return Material(
      color: colors.background,
      child: SafeArea(
        child: (engine == null || clock == null)
            ? _EngineFailure(message: _failure ?? 'unknown error')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusBar(engine: engine, clock: clock),
                  Expanded(
                    child: _MeterCanvas(engine: engine, clock: clock),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EngineFailure extends StatelessWidget {
  const _EngineFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ENGINE UNAVAILABLE',
              style: BelType.label.copyWith(color: colors.over),
            ),
            const SizedBox(height: Space.smd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: BelType.body.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar across the top: what is being measured, for how long, against what.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.engine, required this.clock});

  final BelEngine engine;
  final MeterClock clock;

  static const double height = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    final calibration = ref.watch(calibrationProvider);
    final fps = ref.watch(targetFpsProvider);

    // The clock is the single throttle point, so the setting is pushed into it
    // rather than read from it.
    clock.targetFps = fps;

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border(
            bottom: BorderSide(
              color: colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          // The bar carries seven things and a narrow window cannot hold all
          // of them. Rather than let a Row overflow, the least load-bearing
          // items drop out first: the format readout, then the frame rate.
          // What never drops is the source, the elapsed clock and RESET —
          // knowing what is being measured, for how long, and being able to
          // start again are the parts you cannot work without.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showFormat = constraints.maxWidth >= 860;
              final showFps = constraints.maxWidth >= 700;

              return Row(
                children: [
                  Text(
                    'BEL',
                    style: BelType.label.copyWith(
                      color: colors.textPrimary,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(width: Space.lg),
                  _SourceIndicator(engine: engine),
                  if (showFormat) ...[
                    const SizedBox(width: Space.lg),
                    Text(
                      '${(engine.sampleRate / 1000).toStringAsFixed(1)} kHz'
                      ' · ${engine.channels} ch',
                      style: BelType.readingSmall.copyWith(
                        color: colors.textFaint,
                      ),
                    ),
                  ],
                  const Spacer(),
                  ElapsedReadout(engine: engine, clock: clock),
                  const SizedBox(width: Space.md),
                  Flexible(child: _CalibrationPicker(calibration: calibration)),
                  const SizedBox(width: Space.sm),
                  if (showFps) ...[
                    _FpsPicker(fps: fps),
                    const SizedBox(width: Space.sm),
                  ],
                  _BarButton(label: 'RESET', onPressed: engine.reset),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SourceIndicator extends StatelessWidget {
  const _SourceIndicator({required this.engine});

  final BelEngine engine;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: Space.xs + Space.xxs,
          height: Space.xs + Space.xxs,
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BelRadius.allXs,
          ),
        ),
        const SizedBox(width: Space.sm),
        Text(
          'TEST TONE',
          style: BelType.label.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _CalibrationPicker extends ConsumerWidget {
  const _CalibrationPicker({required this.calibration});

  final Calibration calibration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    return PopupMenuButton<String>(
      tooltip: calibration.note,
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      onSelected: (id) => ref.read(calibrationProvider.notifier).selectById(id),
      itemBuilder: (context) => [
        for (final option in BuiltInCalibrations.all)
          PopupMenuItem(
            value: option.id,
            height: Space.xl,
            child: Text(
              option.name,
              style: BelType.body.copyWith(
                color: option.id == calibration.id
                    ? colors.accent
                    : colors.textPrimary,
              ),
            ),
          ),
      ],
      child: _BarChip(text: calibration.name),
    );
  }
}

class _FpsPicker extends ConsumerWidget {
  const _FpsPicker({required this.fps});

  final int fps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    return PopupMenuButton<int>(
      tooltip: 'Meter refresh rate',
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      onSelected: (value) => ref.read(targetFpsProvider.notifier).select(value),
      itemBuilder: (context) => [
        for (final option in TargetFpsController.options)
          PopupMenuItem(
            value: option,
            height: Space.xl,
            child: Text(
              '$option fps',
              style: BelType.body.copyWith(
                color: option == fps ? colors.accent : colors.textPrimary,
              ),
            ),
          ),
      ],
      child: _BarChip(text: '$fps fps'),
    );
  }
}

class _BarChip extends StatelessWidget {
  const _BarChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BelRadius.allXs,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
      ),
      // Calibration names run long ("Streaming (−14 LUFS)"), and this chip sits
      // in a Row that has no slack. Ellipsis rather than overflow.
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: BelType.caption.copyWith(color: colors.textMuted),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.smd,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          borderRadius: BelRadius.allXs,
          border: Border.all(
            color: colors.hairlineStrong,
            width: BelStroke.hairline,
          ),
        ),
        child: Text(
          label,
          style: BelType.label.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

/// Phase 0's stand-in for the grid canvas.
///
/// Every metric the engine knows about, as a Number Box, so that the ones which
/// are not measured yet are visible as em dashes rather than quietly absent.
/// The real 24-column canvas with drag, resize and snapping is Phase 2; this
/// exists to exercise the render path and to make the honesty about
/// unimplemented measurements impossible to miss.
class _MeterCanvas extends ConsumerWidget {
  const _MeterCanvas({required this.engine, required this.clock});

  final BelEngine engine;
  final MeterClock clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    final calibration = ref.watch(calibrationProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!engine.hasLoudness) ...[
            _Notice(
              text:
                  'Loudness is not measured in this build. K-weighting, R128 '
                  'gating, LRA and true-peak oversampling land in Phase 1 '
                  'together with the EBU conformance suite that proves them — '
                  'not before. Those readings show a dash rather than a '
                  'plausible guess.',
            ),
            const SizedBox(height: Space.lg),
          ],
          Text(
            'MEASUREMENTS',
            style: BelType.label.copyWith(color: colors.textFaint),
          ),
          const SizedBox(height: Space.smd),
          Wrap(
            spacing: Space.md,
            runSpacing: Space.md,
            children: [
              for (final metric in Metric.values)
                SizedBox(
                  width: 200,
                  height: 84,
                  child: NumberBoxModule(
                    engine: engine,
                    clock: clock,
                    metric: metric,
                    calibration: calibration,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    // The accent edge is a sibling strip rather than a coloured `left`
    // BorderSide. A BoxDecoration may not combine a borderRadius with a
    // non-uniform Border: Flutter asserts, the decoration paint aborts, and it
    // takes the child with it — which shows up as a correctly sized box
    // containing nothing at all.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ClipRRect(
        borderRadius: BelRadius.allSm,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border.all(
              color: colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: colors.warn,
                  child: const SizedBox(width: BelStroke.emphasis),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.smd),
                    child: Text(
                      text,
                      style: BelType.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
