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

  BelSource _source = BelSource.testTone;
  String? _deviceId;
  String _sourceLabel = 'TEST TONE';

  @override
  void initState() {
    super.initState();
    _open(BelSource.testTone, label: 'TEST TONE');
  }

  /// Tears the engine down and builds a new one around a different source.
  ///
  /// There is no way to retarget a running engine and there should not be: the
  /// sample rate, the channel count and every filter coefficient derived from
  /// them belong to the source. Swapping the audio underneath a half-integrated
  /// loudness measurement would produce a number that averaged two different
  /// programmes at two different rates.
  void _open(BelSource source, {String? deviceId, required String label}) {
    _clock?.dispose();
    _engine?.dispose();
    _clock = null;
    _engine = null;

    try {
      final engine = BelEngine.start(source: source, deviceId: deviceId);
      setState(() {
        _engine = engine;
        _clock = MeterClock(engine: engine, vsync: this);
        _source = source;
        _deviceId = deviceId;
        _sourceLabel = label;
        _failure = null;
      });
    } on BelEngineException catch (error) {
      // Showing the reason beats a blank window. For a device this is usually
      // a microphone permission that was declined or an interface that has
      // been unplugged; for the built-in sources it is a stale native library.
      setState(() {
        _failure = error.message;
        _source = source;
        _deviceId = deviceId;
        _sourceLabel = label;
      });
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
                  _StatusBar(
                    engine: engine,
                    clock: clock,
                    sourceLabel: _sourceLabel,
                    source: _source,
                    deviceId: _deviceId,
                    onSelect: _open,
                  ),
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
typedef SourceSelector =
    void Function(BelSource source, {String? deviceId, required String label});

class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.engine,
    required this.clock,
    required this.sourceLabel,
    required this.source,
    required this.deviceId,
    required this.onSelect,
  });

  final BelEngine engine;
  final MeterClock clock;
  final String sourceLabel;
  final BelSource source;
  final String? deviceId;
  final SourceSelector onSelect;

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
                  _SourcePicker(
                    label: sourceLabel,
                    source: source,
                    deviceId: deviceId,
                    onSelect: onSelect,
                  ),
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

/// What Bel is listening to, and how to change it.
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.label,
    required this.source,
    required this.deviceId,
    required this.onSelect,
  });

  final String label;
  final BelSource source;
  final String? deviceId;
  final SourceSelector onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return PopupMenuButton<void>(
      tooltip: 'Signal source',
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      itemBuilder: (context) {
        // Enumerated when the menu opens, not cached at launch. Interfaces are
        // plugged and unplugged constantly in a studio, and a list built once
        // would be wrong by the time anybody looked at it.
        final devices = BelEngine.devices();

        return <PopupMenuEntry<void>>[
          _item(
            context,
            'Test tone',
            selected: source == BelSource.testTone,
            onTap: () => onSelect(BelSource.testTone, label: 'TEST TONE'),
          ),
          _item(
            context,
            'Silence',
            selected: source == BelSource.silence,
            onTap: () => onSelect(BelSource.silence, label: 'SILENCE'),
          ),
          const PopupMenuDivider(),
          if (devices.isEmpty)
            PopupMenuItem<void>(
              enabled: false,
              height: Space.xl,
              child: Text(
                'No capture devices',
                style: BelType.caption.copyWith(color: colors.textFaint),
              ),
            )
          else
            for (final device in devices)
              _item(
                context,
                device.isDefault ? '${device.name}  (default)' : device.name,
                selected: source == BelSource.device && deviceId == device.id,
                onTap: () => onSelect(
                  BelSource.device,
                  deviceId: device.id,
                  label: device.name.toUpperCase(),
                ),
              ),
        ];
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: Space.xs + Space.xxs,
            height: Space.xs + Space.xxs,
            decoration: BoxDecoration(
              color: source == BelSource.silence
                  ? colors.textFaint
                  : colors.accent,
              borderRadius: BelRadius.allXs,
            ),
          ),
          const SizedBox(width: Space.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: BelType.label.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<void> _item(
    BuildContext context,
    String text, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = BelTheme.of(context);
    return PopupMenuItem<void>(
      onTap: onTap,
      height: Space.xl,
      child: Text(
        text,
        style: BelType.body.copyWith(
          color: selected ? colors.accent : colors.textPrimary,
        ),
      ),
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
          // Rebuilds on the transition only, never on the sixty frames a
          // second where nothing changed — see MeterClock.overrun.
          ValueListenableBuilder<bool>(
            valueListenable: clock.overrun,
            builder: (context, hasOverrun, _) {
              if (!hasOverrun) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: Space.lg),
                child: _Notice(
                  severity: colors.over,
                  text:
                      'Audio was lost — ${engine.droppedFrames} frames were '
                      'discarded because analysis could not keep up. '
                      'Integrated loudness and LRA average every block since '
                      'the reset, so they are now averages of less than what '
                      'played and cannot be trusted. Press RESET to start a '
                      'clean measurement.',
                ),
              );
            },
          ),
          if (!engine.hasSpectrum) ...[
            _Notice(
              text:
                  'The spectrum is not measured in this build. Those bands sit '
                  'at the floor rather than showing an array of zeroes, which '
                  'would draw as a flat line at full scale. The FFT lands with '
                  'the analyser module that displays it.',
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
  const _Notice({required this.text, this.severity});

  final String text;

  /// The accent stripe. Defaults to warn; pass `colors.over` for something the
  /// user has to act on rather than merely know about.
  final Color? severity;

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
                  color: severity ?? colors.warn,
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
