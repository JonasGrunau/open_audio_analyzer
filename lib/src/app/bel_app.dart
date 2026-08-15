// SPDX-License-Identifier: GPL-3.0-or-later

// `AppExitResponse` is a `dart:ui` enum rather than a Flutter one, so neither
// material.dart nor widgets.dart brings it into scope.
import 'dart:ui' show AppExitResponse;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/grid_canvas.dart';
import '../canvas/tab_strip.dart';
import '../canvas/workspace.dart';
import '../clock/meter_clock.dart';
import '../data/providers.dart';
import '../modules/number_box.dart';
import '../panels/calibration_editor.dart';
import '../panels/preset_browser.dart';
import '../panels/report_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/shortcuts_sheet.dart';
import '../remote/display_screen.dart';
import '../remote/remote_control.dart';
import '../storage/config_paths.dart';
import '../storage/startup_config.dart';
import 'launch_options.dart';
import 'shortcuts.dart';

/// The application root.
class BelApp extends ConsumerWidget {
  const BelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The palette is no longer a compile-time constant: it comes from the
    // active skin. `paletteProvider` holds one instance per skin, which is what
    // keeps every module painter's `shouldRepaint` cheap — see its comment.
    final colors = ref.watch(paletteProvider);

    return MaterialApp(
      title: 'Bel',
      debugShowCheckedModeBanner: false,
      theme: belThemeData(colors),
      home: BelTheme(colors: colors, child: const _Workspace()),
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
///
/// Since Phase 4 the *choice* of source lives in the settings instead of here,
/// and this widget follows it. That inverts the old arrangement deliberately:
/// two controls can now change the source — the status bar and the settings
/// panel — and having each of them call into this state directly would be two
/// paths to keep in step. Now there is one, it is persisted on the way past,
/// and the next launch reopens what was last selected.
class _Workspace extends ConsumerStatefulWidget {
  const _Workspace();

  @override
  ConsumerState<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<_Workspace>
    with SingleTickerProviderStateMixin {
  BelEngine? _engine;
  MeterClock? _clock;
  String? _failure;
  String _sourceLabel = 'TEST TONE';

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();

    final settings = ref.read(settingsProvider);
    _openFor(settings);

    // The source is a function of the settings from here on. `select` narrows
    // it to the two fields that require a restart — changing the skin or the
    // frame rate must not interrupt a measurement.
    ref.listenManual(
      settingsProvider.select((s) => (s.sourceKind, s.deviceId)),
      (previous, next) {
        if (previous == next) return;
        _openFor(ref.read(settingsProvider));
      },
    );

    // The canvas commits a layout on every drag, resize and option change, so
    // this is debounced inside the store rather than here.
    ref.listenManual(workspaceProvider, (previous, next) {
      if (!ref.read(settingsProvider).restoreSession) return;
      // Selection is not part of the session — undo does not walk back through
      // clicks and neither does the autosave. Which tab is open is: reopening
      // on a different tab from the one you left is a small daily wrong.
      if (identical(previous?.preset, next.preset) &&
          previous?.activeTab == next.activeTab) {
        return;
      }
      ref
          .read(configStoreProvider)
          .scheduleWrite(
            ConfigFile.session,
            SessionSnapshot(
              preset: next.preset,
              activeTab: next.activeTab,
            ).toJson(),
          );
    });

    // A debounced write that has not landed yet has to land before the process
    // goes away, or the last edit before quitting is the one edit that is
    // always lost.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await ref.read(configStoreProvider).flush();
        return AppExitResponse.exit;
      },
    );

    // The command line, after the first frame. Both halves need a context below
    // `MaterialApp.home`: a panel is a route pushed above the application's
    // `Material` and `BelTheme`, so it cannot be opened from `main()`.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyLaunchOptions());
  }

  /// Acts on `--open-panel`, and says so when an argument was not understood.
  void _applyLaunchOptions() {
    if (!mounted) return;
    final options = ref.read(launchOptionsProvider);

    if (options.warnings.isNotEmpty) {
      // Joined onto whatever the storage layer already had to say rather than
      // replacing it. A misspelt flag is worth mentioning; a config directory
      // that cannot be written is worth more, and the second must not be lost
      // to the first.
      final notice = ref.read(storageNoticeProvider);
      ref
          .read(storageNoticeProvider.notifier)
          .report([?notice, ...options.warnings].join(' '));
    }

    switch (options.openPanel) {
      case null:
        return;
      case StartupPanel.settings:
        showSettingsPanel(context);
      case StartupPanel.presets:
        showPresetBrowser(context);
      case StartupPanel.calibration:
        showCalibrationEditor(context);
      case StartupPanel.report:
        showReportPanel(context);
      case StartupPanel.shortcuts:
        showShortcutsSheet(context);
    }
  }

  /// Tears the engine down and builds a new one around a different source.
  ///
  /// There is no way to retarget a running engine and there should not be: the
  /// sample rate, the channel count and every filter coefficient derived from
  /// them belong to the source. Swapping the audio underneath a half-integrated
  /// loudness measurement would produce a number that averaged two different
  /// programmes at two different rates.
  void _openFor(AppSettings settings) {
    final (source, deviceId, label) = _resolve(settings);
    final previousEngine = _engine;
    final previousClock = _clock;

    try {
      final engine = BelEngine.start(source: source, deviceId: deviceId);
      setState(() {
        _engine = engine;
        _clock = MeterClock(engine: engine, vsync: this);
        _sourceLabel = label;
        _failure = null;
      });
    } on BelEngineException catch (error) {
      // Showing the reason beats a blank window. For a device this is usually
      // a microphone permission that was declined or an interface that has
      // been unplugged; for the built-in sources it is a stale native library.
      setState(() {
        _engine = null;
        _clock = null;
        _sourceLabel = label;
        _failure = error.message;
      });
    }

    // **Disposed after the frame that replaces them, not before.** A
    // `CustomPainter` holds the clock as its `repaint` listenable, and
    // `ChangeNotifier.addListener` throws if it has already been disposed. Tear
    // the old clock down first and any painter still mounted for one more frame
    // — every meter on the canvas — reattaches to a dead notifier and the
    // module is replaced by a red error box. Deferring costs one frame of two
    // live engines and removes the failure mode entirely.
    if (previousEngine != null || previousClock != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousClock?.dispose();
        previousEngine?.dispose();
      });
    }
  }

  /// Turns a persisted selection into something the engine can open.
  ///
  /// The device is looked up by id and then, failing that, **by name**. Device
  /// ids are not stable across reboots on any of the three platforms, so an
  /// exact-id-only lookup means an interface that was plugged in yesterday is
  /// silently not reopened today — the user is shown the test tone and has to
  /// work out why.
  (BelSource, String?, String) _resolve(AppSettings settings) {
    switch (settings.sourceKind) {
      case AudioSourceKind.testTone:
        return (BelSource.testTone, null, 'TEST TONE');
      case AudioSourceKind.silence:
        return (BelSource.silence, null, 'SILENCE');
      case AudioSourceKind.device:
        break;
    }

    final wantedId = settings.deviceId;
    final wantedName = settings.deviceName;

    List<BelDevice> devices;
    try {
      devices = BelEngine.devices();
    } on BelEngineException {
      devices = const [];
    }

    for (final device in devices) {
      if (device.id == wantedId) {
        return (BelSource.device, device.id, device.name.toUpperCase());
      }
    }
    for (final device in devices) {
      if (wantedName != null && device.name == wantedName) {
        return (BelSource.device, device.id, device.name.toUpperCase());
      }
    }

    // Nothing matched. Open by the stored id anyway so that the engine's own
    // error message is what the user sees, rather than a guess of ours.
    return (BelSource.device, wantedId, (wantedName ?? 'DEVICE').toUpperCase());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _clock?.dispose();
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final engine = _engine;
    final clock = _clock;
    final notice = ref.watch(storageNoticeProvider);

    // Bel draws almost nothing with Material, but the few stock widgets it does
    // use — popup menus, tooltips — assert on having a Material ancestor and
    // throw at runtime without one. A bare `Material` costs nothing and is
    // cheaper than reimplementing menus to avoid it.
    return Material(
      color: colors.background,
      child: SafeArea(
        child: (engine == null || clock == null)
            ? _EngineFailure(message: _failure ?? 'unknown error')
            // Every keyboard binding in the application, installed once and
            // above everything it acts on. They used to live inside the canvas,
            // where they stopped working whenever focus did not — see
            // lib/src/app/shortcuts.dart.
            : BelShortcuts(
                onReset: engine.reset,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StatusBar(
                      engine: engine,
                      clock: clock,
                      sourceLabel: _sourceLabel,
                    ),
                    const TabStrip(),
                    // Rebuilds on the transition only, never on the sixty frames
                    // a second where nothing changed — see MeterClock.overrun.
                    ValueListenableBuilder<bool>(
                      valueListenable: clock.overrun,
                      builder: (context, hasOverrun, _) => hasOverrun
                          ? _NoticeSlot(
                              child: _Notice(
                                severity: colors.over,
                                text:
                                    'Audio was lost — ${engine.droppedFrames} '
                                    'frames were discarded because analysis '
                                    'could not keep up. Integrated loudness and '
                                    'LRA average every block since the reset, so '
                                    'they are now averages of less than what '
                                    'played and cannot be trusted. Press RESET '
                                    'to start a clean measurement.',
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    // Persistence failures are shown rather than logged. A meter
                    // that has quietly stopped saving is a meter that loses a
                    // day's work at the moment the user finds out.
                    if (notice != null)
                      _NoticeSlot(
                        child: _Notice(
                          text: notice,
                          onDismiss: ref
                              .read(storageNoticeProvider.notifier)
                              .clear,
                        ),
                      ),
                    Expanded(
                      child: GridCanvas(engine: engine, clock: clock),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _NoticeSlot extends StatelessWidget {
  const _NoticeSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, 0),
    child: child,
  );
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
            const SizedBox(height: Space.lg),
            // The way out of a bad device selection, from the one screen that
            // has no status bar to change it from.
            Consumer(
              builder: (context, ref, _) => BelButton(
                label: 'Use the test tone',
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .setSource(AudioSourceKind.testTone),
              ),
            ),
            const SizedBox(height: Space.sm),
            // And the way out for the machine this screen is most likely to be
            // on. A tablet has no capture device to select, so it arrives here
            // on launch and every other route to the remote display runs
            // through the status bar that this screen does not have — which
            // would leave the display feature unreachable on exactly the
            // hardware it was built for.
            BelButton(
              label: 'Use as a remote display',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RemoteDisplayScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar across the top: what is being measured, for how long, against what.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.engine,
    required this.clock,
    required this.sourceLabel,
  });

  final BelEngine engine;
  final MeterClock clock;
  final String sourceLabel;

  static const double height = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    final settings = ref.watch(settingsProvider);
    final calibration = ref.watch(calibrationProvider);

    // The clock is the single throttle point, so the setting is pushed into it
    // rather than read from it.
    clock.targetFps = settings.targetFps;

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
          // The bar carries eight things and a narrow window cannot hold all
          // of them. Rather than let a Row overflow, the least load-bearing
          // items drop out first: the format readout, then the frame rate.
          // What never drops is the source, the elapsed clock, settings and
          // RESET — knowing what is being measured, for how long, being able
          // to change it and being able to start again are the parts you
          // cannot work without.
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
                  _SourcePicker(label: sourceLabel, settings: settings),
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
                    _FpsPicker(fps: settings.targetFps),
                    const SizedBox(width: Space.sm),
                  ],
                  RemoteDisplayControl(
                    source: engine,
                    abiVersion: BelEngine.abiVersion,
                  ),
                  const SizedBox(width: Space.sm),
                  _BarButton(
                    label: 'ANALYSE FILE',
                    onPressed: () => showReportPanel(context),
                  ),
                  const SizedBox(width: Space.sm),
                  // Bel draws its own chrome and therefore has no menu bar, so
                  // the usual place a desktop user reads a shortcut off — the
                  // chord printed beside a menu item — does not exist. Without
                  // this button the sheet is only reachable by pressing the key
                  // that opens the list of keys.
                  _BarButton(
                    label: '?',
                    tooltip: 'Keyboard shortcuts',
                    onPressed: () => showShortcutsSheet(context),
                  ),
                  const SizedBox(width: Space.sm),
                  _BarButton(
                    label: 'SETTINGS',
                    onPressed: () => showSettingsPanel(context),
                  ),
                  const SizedBox(width: Space.sm),
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
class _SourcePicker extends ConsumerWidget {
  const _SourcePicker({required this.label, required this.settings});

  final String label;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = BelTheme.of(context);
    final controller = ref.read(settingsProvider.notifier);

    return PopupMenuButton<void>(
      tooltip: 'Signal source',
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      itemBuilder: (context) {
        // Enumerated when the menu opens, not cached at launch. Interfaces are
        // plugged and unplugged constantly in a studio, and a list built once
        // would be wrong by the time anybody looked at it.
        List<BelDevice> devices;
        try {
          devices = BelEngine.devices();
        } on BelEngineException {
          devices = const [];
        }

        return <PopupMenuEntry<void>>[
          _item(
            context,
            'Test tone',
            selected: settings.sourceKind == AudioSourceKind.testTone,
            onTap: () => controller.setSource(AudioSourceKind.testTone),
          ),
          _item(
            context,
            'Silence',
            selected: settings.sourceKind == AudioSourceKind.silence,
            onTap: () => controller.setSource(AudioSourceKind.silence),
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
                selected:
                    settings.sourceKind == AudioSourceKind.device &&
                    settings.deviceId == device.id,
                onTap: () => controller.setSource(
                  AudioSourceKind.device,
                  deviceId: device.id,
                  deviceName: device.name,
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
              color: settings.sourceKind == AudioSourceKind.silence
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
    // The user's own targets appear here beside the built-ins, which is the
    // whole point of the library being a directory.
    final library = ref.watch(calibrationLibraryProvider);

    return PopupMenuButton<String>(
      tooltip: calibration.note,
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      onSelected: ref.read(settingsProvider.notifier).setCalibrationId,
      itemBuilder: (context) => [
        for (final option in library)
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
      onSelected: ref.read(settingsProvider.notifier).setTargetFps,
      itemBuilder: (context) => [
        for (final option in kTargetFpsOptions)
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
  const _BarButton({
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final String label;
  final VoidCallback onPressed;

  /// For the buttons whose label is a glyph rather than a word.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final button = GestureDetector(
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

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.severity, this.onDismiss});

  final String text;

  /// The accent stripe. Defaults to warn; pass `colors.over` for something the
  /// user has to act on rather than merely know about.
  final Color? severity;

  final VoidCallback? onDismiss;

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
                if (onDismiss != null)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: Center(
                      child: BelButton(label: 'Dismiss', onPressed: onDismiss!),
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
