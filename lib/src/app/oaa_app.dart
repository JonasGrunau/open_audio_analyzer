// SPDX-License-Identifier: GPL-3.0-or-later

// `AppExitResponse` is a `dart:ui` enum rather than a Flutter one, so neither
// material.dart nor widgets.dart brings it into scope.
import 'dart:async' show unawaited;
import 'dart:ui' show AppExitResponse;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_notice.dart';
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
import '../plugin/plugin_link.dart';
import '../remote/display_screen.dart';
import '../remote/remote_control.dart';
import '../remote/remote_display_service.dart';
import '../storage/startup_config.dart';
import 'bar_controls.dart';
import 'launch_options.dart';
import 'shortcuts.dart';
import 'transport_readout.dart';
import 'window_chrome.dart';

/// The application root.
class OaaApp extends ConsumerWidget {
  const OaaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The palette is no longer a compile-time constant: it comes from the
    // active skin. `paletteProvider` holds one instance per skin, which is what
    // keeps every module painter's `shouldRepaint` cheap — see its comment.
    final colors = ref.watch(paletteProvider);

    // The window's own chrome follows the skin too. On macOS there is no title
    // bar left to disagree with the palette, but the window buttons are still
    // AppKit's and the window's background is what shows during a live resize;
    // both have to be told which skin is in force. Deduplicated inside, so the
    // rebuilds that did not change the palette cost nothing.
    WindowChrome.applyPalette(colors);

    return MaterialApp(
      title: 'Open Audio Analyzer',
      debugShowCheckedModeBanner: false,
      theme: oaaThemeData(colors),
      // **The palette goes where the Material theme already is: above the
      // `Navigator`, which is what `builder` wraps.** Under `home` it is
      // invisible to a route, so every panel could only be handed a copy of it
      // taken when it opened — and a skin chosen in the settings panel, which
      // is where skins are chosen, repainted the canvas behind that panel and
      // left the panel itself in the old colours. Material's half of the theme
      // did follow, because `MaterialApp` puts it here, so the panel came apart
      // into two skins at once. See `showOaaPanel`.
      builder: (context, child) => OaaTheme(colors: colors, child: child!),
      home: const _Workspace(),
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

/// **`TickerProviderStateMixin`, not `SingleTickerProviderStateMixin`.** There
/// is only ever one clock alive, so the single-ticker mixin looks like the
/// right one and is not: it permits one `createTicker` call *per State*, for
/// the life of the State, and never clears the field — disposing the ticker
/// does not buy another. This State creates one clock per source, so the first
/// source works and every change after it throws.
///
/// That failure is invisible in exactly the wrong way. `_openFor` catches
/// `OaaEngineException`, and this is a `FlutterError`, so it escapes the
/// `setState` callback: the engine has already been created and started, but
/// `_engine` and `_clock` are never assigned. The window keeps painting the
/// previous source — same label, same elapsed clock, still running — while the
/// new engine holds the capture device open with nothing reading it. Selecting
/// a microphone appears to do nothing at all, and the only visible trace is the
/// system's recording indicator.
class _WorkspaceState extends ConsumerState<_Workspace>
    with TickerProviderStateMixin {
  OaaEngine? _engine;
  MeterClock? _clock;
  String? _failure;
  String _sourceLabel = 'TEST TONE';

  /// Publishing to a tablet, owned here rather than by the status-bar button
  /// that switches it on.
  ///
  /// Two reasons, and both were bugs. It holds a socket and a publish timer
  /// pointed at the engine, so it has to be told when the engine is replaced —
  /// otherwise it keeps acquiring through a destroyed one and sends freed memory
  /// to the tablet as a measurement. And the button that used to own it is
  /// dropped from the status bar below 620 px of window width, so narrowing the
  /// window tore down an active session with nothing anywhere saying why.
  late final RemoteDisplayService _remote = RemoteDisplayService(
    null, // no engine yet; `_openFor` attaches one
    abiVersion: OaaEngine.abiVersion,
  );

  /// Plugin inserts, accepted on loopback.
  ///
  /// The plugin is the transient end of the link and the app is the one that
  /// stays open, so the app listens and the plugin dials — see
  /// `lib/src/plugin/plugin_link.dart`. This is the whole of the app's side of
  /// it: own a link, and read the session it says is active.
  ///
  /// It was written, tested and never constructed, so the port was never bound
  /// and a plugin retried forever against nothing while the README said the app
  /// meters what the DAW is playing.
  late final PluginLink _plugins = PluginLink(
    port: ref.read(pluginLinkPortProvider),
  );

  AppLifecycleListener? _lifecycle;

  /// What the meters are reading: the active plugin session if one is
  /// connected, and this machine's own engine otherwise.
  ///
  /// Inserting a plugin *is* the act of choosing it, so a connection takes the
  /// canvas without anybody having to find a menu — which is what the README
  /// describes and what `PluginLink.active` already decides. Removing it hands
  /// the canvas back.
  MeterSource? get _activeSource => _plugins.active?.snapshot ?? _engine;

  /// Whether the canvas is showing a plugin rather than the local engine.
  bool get _onPlugin => _plugins.active != null;

  @override
  void initState() {
    super.initState();

    final settings = ref.read(settingsProvider);
    _openFor(settings);

    // Membership only — a session's *measurements* are read off its
    // `WireSnapshot` by painters, never through a notifier. This rebuilds when
    // a plugin arrives or leaves, which is a few times an hour.
    _plugins.addListener(_onPluginsChanged);

    // Transport is the one thing a listener cannot carry: it arrives per audio
    // block, and the remote display has to see *every* frame rather than sample
    // them — `Transport.flagDiscontinuity` is an edge delivered once, so a
    // relay that only looked thirty times a second would lose two relocates in
    // three. Nothing on the paint path is behind this; the canvas reads the
    // active session's transport when it paints.
    _plugins.onTransport = (session, transport) {
      if (identical(session, _plugins.active)) _remote.transport = transport;
    };

    unawaited(_plugins.start());

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
    // `MaterialApp` — a panel is a route, so it needs the `Navigator` this
    // widget is built under, and it cannot be opened from `main()`.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyLaunchOptions());
  }

  /// Clears the integrating measurements, where that is possible.
  ///
  /// It is not possible for a plugin. The protocol runs one way in version 2 —
  /// a display cannot reset a producer's integration, and `docs/WIRE.md`
  /// reserves the control frames that would change that but does not define
  /// them. So rather than resetting the local engine nobody is looking at,
  /// which is what a button wired straight to it would do, this says so.
  void _reset() {
    final session = _plugins.active;
    if (session != null) {
      ref
          .read(canvasNoticeProvider.notifier)
          .say(
            'RESET cannot reach ${session.displayName}: the plugin link runs '
            'one way. Restart the integration in your DAW, or switch back to a '
            'local source.',
          );
      return;
    }
    _engine?.reset();
  }

  /// A plugin connected, disconnected, or became the active one.
  void _onPluginsChanged() {
    if (!mounted) return;
    final source = _activeSource;
    if (source != null) {
      // The clock is retargeted rather than rebuilt: every painter holds it as
      // its `repaint` listenable, and a painter that outlives its notifier by
      // one frame is replaced by an error box.
      _clock?.engine = source;
      _remote.source = source;
    }
    // The playhead belongs to the session, so it goes when the session does. A
    // display told nothing would hold the removed plugin's position until the
    // link itself went stale, and a tablet showing bar 57 of a DAW that has
    // been closed is a tablet showing a measurement of nothing.
    _remote.transport = _plugins.active?.transport ?? Transport.none;
    setState(() {});
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
      final engine = OaaEngine.start(source: source, deviceId: deviceId);
      setState(() {
        _engine = engine;
        _clock = MeterClock(
          engine: _plugins.active?.snapshot ?? engine,
          vsync: this,
        );
        _sourceLabel = label;
        _failure = null;
      });
      // Before the old engine is destroyed below, so the publish timer never
      // gets a turn holding the freed one.
      _remote.source = _plugins.active?.snapshot ?? engine;
    } on OaaEngineException catch (error) {
      // Showing the reason beats a blank window. For a device this is usually
      // a microphone permission that was declined or an interface that has
      // been unplugged; for the built-in sources it is a stale native library.
      setState(() {
        _engine = null;
        _clock = null;
        _sourceLabel = label;
        _failure = error.message;
      });
      // Nothing is being measured, so there is nothing honest to publish. A
      // display left attached shows em dashes rather than the last frame of a
      // source that no longer exists.
      _remote.source = null;
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
  (OaaSource, String?, String) _resolve(AppSettings settings) {
    switch (settings.sourceKind) {
      case AudioSourceKind.testTone:
        return (OaaSource.testTone, null, 'TEST TONE');
      case AudioSourceKind.silence:
        return (OaaSource.silence, null, 'SILENCE');
      case AudioSourceKind.device:
        break;
    }

    final wantedId = settings.deviceId;
    final wantedName = settings.deviceName;

    List<OaaDevice> devices;
    try {
      devices = OaaEngine.devices();
    } on OaaEngineException {
      devices = const [];
    }

    for (final device in devices) {
      if (device.id == wantedId) {
        return (OaaSource.device, device.id, device.name.toUpperCase());
      }
    }
    for (final device in devices) {
      if (wantedName != null && device.name == wantedName) {
        return (OaaSource.device, device.id, device.name.toUpperCase());
      }
    }

    // Nothing matched. Open by the stored id anyway so that the engine's own
    // error message is what the user sees, rather than a guess of ours.
    return (OaaSource.device, wantedId, (wantedName ?? 'DEVICE').toUpperCase());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    // The sockets and the publish timer before the engine they read, or the
    // timer gets one more turn against a freed handle.
    _plugins.removeListener(_onPluginsChanged);
    _plugins.dispose();
    _remote.dispose();
    _clock?.dispose();
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final engine = _engine;
    final clock = _clock;

    // What the meters draw: the plugin somebody just inserted, or nothing yet.
    // Resolved against `engine` at each use below, where it has been promoted
    // non-null by the failure branch.
    final plugin = _plugins.active?.snapshot;

    final notice = ref.watch(storageNoticeProvider);

    // Open Audio Analyzer draws almost nothing with Material, but the few stock
    // widgets it does use — popup menus, tooltips — assert on having a Material
    // ancestor and throw at runtime without one. A bare `Material` costs
    // nothing and is cheaper than reimplementing menus to avoid it.
    return Material(
      color: colors.background,
      child: SafeArea(
        child: (engine == null || clock == null)
            ? _EngineFailure(message: _failure ?? 'unknown error')
            // Every keyboard binding in the application, installed once and
            // above everything it acts on. They used to live inside the canvas,
            // where they stopped working whenever focus did not — see
            // lib/src/app/shortcuts.dart.
            : OaaShortcuts(
                onReset: _reset,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The status bar is the window's title bar as well on
                    // macOS — there is no system one left to drag. See
                    // window_chrome.dart.
                    WindowDragArea(
                      child: _StatusBar(
                        engine: engine,
                        source: plugin ?? engine,
                        clock: clock,
                        remote: _remote,
                        onReset: _reset,
                        sourceLabel: _onPlugin
                            ? _plugins.active!.displayName.toUpperCase()
                            : _sourceLabel,
                        // Null unless a DAW could be on the other end. The
                        // readout itself draws nothing when a host has said
                        // nothing, so this is about the *row*: an item that is
                        // permanently blank on every machine metering a sound
                        // card would still be taking 108 px off a bar that
                        // measures its width in tens.
                        transportOf: _onPlugin
                            ? () => _plugins.active?.transport ?? Transport.none
                            : null,
                      ),
                    ),
                    const TabStrip(),
                    // Rebuilds on the transition only, never on the sixty frames
                    // a second where nothing changed — see MeterClock.overrun.
                    //
                    // **The count comes from whatever is being metered, not from
                    // the local engine.** The flag behind this notice does: the
                    // clock watches `plugin ?? engine`, so a plugin that
                    // overran raised it — and the sentence then read the
                    // desktop's own engine, which is idle while a plugin is on
                    // the canvas and had discarded nothing. "Audio was lost — 0
                    // frames were discarded" is a self-contradicting warning
                    // about a real loss of audio, and the number a user would
                    // quote in a bug report.
                    ValueListenableBuilder<bool>(
                      valueListenable: clock.overrun,
                      builder: (context, hasOverrun, _) => hasOverrun
                          ? _NoticeSlot(
                              child: _Notice(
                                severity: colors.over,
                                text:
                                    'Audio was lost — '
                                    '${(plugin ?? engine).droppedFrames} '
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
                    // A port that could not be bound is shown for the same
                    // reason: the plugin retries forever and says nothing, so
                    // an app that cannot accept it looks exactly like a plugin
                    // that is not sending. The usual cause is a second copy of
                    // Open Audio Analyzer already running.
                    ValueListenableBuilder<String?>(
                      valueListenable: _plugins.failure,
                      builder: (context, failure, _) => failure == null
                          ? const SizedBox.shrink()
                          : _NoticeSlot(
                              child: _Notice(
                                severity: colors.warn,
                                text:
                                    'Plugins cannot connect: $failure '
                                    'Inserting the VST3 or AU in a DAW will '
                                    'have no effect until this is resolved.',
                              ),
                            ),
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
                      child: GridCanvas(engine: plugin ?? engine, clock: clock),
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
    final colors = OaaTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ENGINE UNAVAILABLE',
              style: OaaType.label.copyWith(color: colors.over),
            ),
            const SizedBox(height: Space.smd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: OaaType.body.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: Space.lg),
            // The way out of a bad device selection, from the one screen that
            // has no status bar to change it from.
            Consumer(
              builder: (context, ref, _) => OaaButton(
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
            OaaButton(
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
    required this.source,
    required this.clock,
    required this.remote,
    required this.onReset,
    required this.sourceLabel,
    required this.transportOf,
  });

  /// This machine's engine. Only what the *source picker* acts on — the
  /// readings come from [source], which may be a plugin instead.
  final OaaEngine engine;

  /// What is being measured: the engine, or a connected plugin's frames.
  final MeterSource source;

  final MeterClock clock;

  /// Passed through rather than created here: the row this widget builds is
  /// dropped on a narrow window, and the socket must not be.
  final RemoteDisplayService remote;

  /// Not `engine.reset`: a plugin cannot be reset from here, and a button that
  /// silently resets a source nobody is looking at is worse than one that says
  /// it cannot. See `_WorkspaceState._reset`.
  final VoidCallback onReset;

  final String sourceLabel;

  /// The DAW's playhead, read at paint time, or null when nothing being metered
  /// could have one.
  ///
  /// A getter rather than a `Transport`, because this widget rebuilds a few
  /// times an hour and the position moves ninety times a second. See
  /// [TransportReadout].
  final Transport Function()? transportOf;

  static const double height = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = OaaTheme.of(context);
    final settings = ref.watch(settingsProvider);
    final calibration = ref.watch(calibrationProvider);

    // The clock is the single throttle point, so both the setting and the
    // platform's accessibility preference are pushed into it rather than read
    // from it. `disableAnimations` is the OS-level "reduce motion" switch; on
    // a metering tool it becomes a ceiling on the redraw rate, because the
    // motion here is the measurement and cannot be removed. See MeterClock.
    clock.targetFps = settings.targetFps;
    clock.reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border(
            bottom: BorderSide(
              color: colors.hairline,
              width: OaaStroke.hairline,
            ),
          ),
        ),
        child: Padding(
          // Leading and trailing rather than symmetric: on macOS the three
          // window buttons are drawn over the top of this bar, and OAA cannot
          // start until they have ended. See WindowChrome.statusBarLeading.
          padding: EdgeInsets.only(
            left: WindowChrome.statusBarLeading,
            right: Space.md,
          ),
          // **What earns a place in the bar is what changes while you work,
          // or what a reading has to be read against.** The source, the
          // elapsed clock and RESET are the first; the delivery target is the
          // second — every PASS and FAIL on the canvas is a verdict against
          // it, so naming it beside them is the meter's units, not a shortcut
          // to a setting. The refresh rate was neither. It is chosen once for
          // a machine and never looked at again, and its chip sat in the bar
          // duplicating a control two clicks away for no other reason than
          // that it fit — so it is in the settings panel now and only there.
          //
          // **A narrow window cannot hold everything, and a Row that cannot
          // hold its children does not shrink them — it overflows.** One gate
          // was not enough: at the smallest window the platform allows, the
          // bar ran 121 px past its own edge, which is a debug stripe in
          // development and silently clipped controls in a release build.
          //
          // So the items leave in order of how little they carry, each at the
          // width below which the rest no longer fit. Every one of them is
          // still reachable — the four buttons all have shortcuts, listed in
          // the sheet the `?` opens and in docs/site/keyboard.md — and what
          // stays at the narrowest width is what the rule above says stays:
          // the source, the elapsed clock, the delivery target and RESET.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              // Each number is the row width at which everything *up to and
              // including* that item still fits, measured rather than
              // estimated — `test/scaling_test.dart` sweeps the whole
              // application every 20 px and fails on the overflow, and the
              // margin above each measured threshold is about 35 px for the
              // longest string the item beside it can hold. 860 was the single
              // gate this replaced, and it was 20 px short of even its own
              // case: the bar fitted at every window anybody had opened and
              // ran 121 px past the edge at the smallest one the platform
              // allowed.
              //
              // Below 500 the irreducible set — source, clock, target,
              // SETTINGS, RESET — does not fit either, and there is no honest
              // item left to drop. That is under half the supported minimum
              // window and is left to the platform.
              // The transport readout is the widest single item the bar can
              // gain — 92 px and its gap — and the only one that is not always
              // there, so it opens last and highest. 1040 is measured the same
              // way as the rest: with the readout forced on and the longest
              // target name there is, the row needs 1004 px, and this leaves
              // the same ~35 px of margin the gates below it carry.
              // `test/scaling_test.dart` sweeps the bar with a real plugin
              // attached, which is the only state this item exists in.
              final showTransport = transportOf != null && width >= 1040;
              final showFormat = width >= 900;
              final showWordmark = width >= 790;
              final showAnalyse = width >= 730;
              final showRemote = width >= 620;
              final showHelp = width >= 520;

              return Row(
                children: [
                  // **The left group is the slack.** It is `Expanded`, so it
                  // takes whatever the right group leaves and pushes that group
                  // flush right — the job a `Spacer` used to do here.
                  //
                  // The Spacer is gone because it cannot coexist with a child
                  // that shrinks, and the bar needs one. Both pickers cap at
                  // 220 px and ellipsis, so a long device name and a long target
                  // name together add about 200 px that the width gates below
                  // never counted; at 950 px every gate was open and the row ran
                  // 18 px past its edge. Making the source picker `Flexible`
                  // fixes that — but `Flexible` and `Spacer` both default to
                  // `flex: 1`, so `RenderFlex` splits the free space between
                  // them, the loose picker takes only what it needs, and the
                  // Spacer's half is laid out *after* the last child. That is
                  // the bug described two comments down, and this is the shape
                  // that has neither.
                  Expanded(
                    child: Row(
                      children: [
                        if (showWordmark) ...[
                          Text(
                            'OAA',
                            style: OaaType.label.copyWith(
                              color: colors.textPrimary,
                              letterSpacing: 2,
                            ),
                          ),
                          // `Space.md`, not `Space.lg`: the wordmark is three
                          // proportional glyphs and OAA is about 3.4 px wider
                          // than the mark it replaced, which was enough on its
                          // own to run this row 0.136 px past its edge at
                          // 1000 px with the longest target name. The gap the
                          // wordmark owns gives that back rather than the
                          // source picker losing it.
                          const SizedBox(width: Space.md),
                        ],
                        Flexible(
                          child: _SourcePicker(
                            label: sourceLabel,
                            settings: settings,
                          ),
                        ),
                        if (showFormat) ...[
                          const SizedBox(width: Space.lg),
                          Text(
                            '${(source.sampleRate / 1000).toStringAsFixed(1)}'
                            ' kHz · ${source.channels} ch',
                            style: OaaType.readingSmall.copyWith(
                              color: colors.textFaint,
                            ),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ],
                      ],
                    ),
                  ),
                  // **Left of the elapsed clock, because they are two clocks
                  // and only one of them is a measurement.** This is where the
                  // session is; the one beside it is how long this reading has
                  // been running. Reading order puts the host's time first —
                  // it is the one somebody says out loud to another person in
                  // the room — and the measurement's own clock next to the
                  // target it is being judged against.
                  if (showTransport) ...[
                    TransportReadout(transportOf: transportOf!, repaint: clock),
                    const SizedBox(width: Space.md),
                  ],
                  ElapsedReadout(engine: source, clock: clock),
                  const SizedBox(width: Space.md),
                  // Bounded, not `Flexible`. A `Flexible` here shares the row's
                  // free space with the `Spacer` above — both default to
                  // `flex: 1`, so `RenderFlex` hands each of them half. The
                  // Spacer is tight and takes its half; this one is loose and
                  // takes only the width of the name, and the leftover half is
                  // laid out *after* the last child. Everything from the
                  // elapsed clock rightwards then sat in the middle of the bar
                  // with a gap beside it that grew as the window did.
                  //
                  // A maximum with an ellipsis is what the source picker two
                  // rows up already does, and it is the honest constraint: the
                  // bar drops whole items on a narrow window rather than
                  // squeezing them — see the `showFormat` gate.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: _CalibrationPicker(calibration: calibration),
                  ),
                  if (showRemote) ...[
                    const SizedBox(width: Space.sm),
                    RemoteDisplayControl(service: remote),
                  ],
                  if (showAnalyse) ...[
                    const SizedBox(width: Space.sm),
                    BarButton(
                      label: 'ANALYSE FILE',
                      onPressed: () => showReportPanel(context),
                    ),
                  ],
                  const SizedBox(width: Space.sm),
                  BarButton(
                    label: 'SETTINGS',
                    onPressed: () => showSettingsPanel(context),
                  ),
                  const SizedBox(width: Space.sm),
                  // The scope has to be on the button. `RESET` beside
                  // `SETTINGS` in identical chrome reads as "reset everything"
                  // — the layout, the target, the app — when what it actually
                  // discards is the integration in progress. Somebody twenty
                  // minutes into an integrated measurement needs to know that
                  // before they click, not after.
                  BarButton(
                    label: 'RESET',
                    // Wording tracks the contract at oaa_engine_reset() in
                    // oaa.h. If that changes, this changes with it — a button
                    // that describes the wrong thing is worse than one that
                    // describes nothing.
                    tooltip:
                        'Restarts the measurement — integrated loudness, LRA, '
                        'the max-since-reset peaks, the clip counters and the '
                        'elapsed clock. Momentary readings, the layout and the '
                        'delivery target are untouched.',
                    onPressed: onReset,
                  ),
                  // Last, and outside the working set on purpose. Everything to
                  // its left is about the measurement in progress — what is
                  // being measured, against what, and how to start again. This
                  // is about the application, and a glyph sitting between two
                  // words reads as a third word you cannot make out.
                  //
                  // It exists at all because Open Audio Analyzer draws its own
                  // chrome and so has no menu bar: the usual place a desktop
                  // user reads a shortcut off — the chord printed beside a menu
                  // item — is not there, and without this button the sheet is
                  // only reachable by pressing the key that opens the list of
                  // keys.
                  if (showHelp) ...[
                    const SizedBox(width: Space.sm),
                    BarButton(
                      label: '?',
                      tooltip: 'Keyboard shortcuts',
                      semanticLabel: 'Keyboard shortcuts',
                      onPressed: () => showShortcutsSheet(context),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What Open Audio Analyzer is listening to, and how to change it.
class _SourcePicker extends ConsumerWidget {
  const _SourcePicker({required this.label, required this.settings});

  final String label;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = OaaTheme.of(context);
    final controller = ref.read(settingsProvider.notifier);

    return PopupMenuButton<void>(
      tooltip: 'Signal source',
      color: colors.panelRaised,
      position: PopupMenuPosition.under,
      itemBuilder: (context) {
        // Enumerated when the menu opens, not cached at launch. Interfaces are
        // plugged and unplugged constantly in a studio, and a list built once
        // would be wrong by the time anybody looked at it.
        List<OaaDevice> devices;
        try {
          devices = OaaEngine.devices();
        } on OaaEngineException {
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
                style: OaaType.caption.copyWith(color: colors.textFaint),
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
              // Bright means listening, dim means silence. Not the signal hue:
              // this dot sits in the same bar as the readings, where `accent`
              // already means "in spec" — a lit teal dot next to a loudness
              // number reads as a verdict on it.
              color: settings.sourceKind == AudioSourceKind.silence
                  ? colors.textFaint
                  : colors.textPrimary,
              borderRadius: OaaRadius.allXs,
            ),
          ),
          const SizedBox(width: Space.sm),
          // **`Flexible`, not just a maximum.** A `ConstrainedBox` caps how wide
          // the name may grow; it does not make it shrink. This `Row` is
          // `mainAxisSize.min`, so a child that is not flexible is measured
          // against unbounded width — the name took its full 220 px however
          // little room the bar had, and the Row overflowed inside the picker
          // where the status bar's own width gates could not see it.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: OaaType.label.copyWith(color: colors.textMuted),
              ),
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
    final colors = OaaTheme.of(context);
    return PopupMenuItem<void>(
      onTap: onTap,
      height: Space.xl,
      child: Text(
        text,
        style: OaaType.body.copyWith(
          color: selected ? colors.textPrimary : colors.textMuted,
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
    final colors = OaaTheme.of(context);
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
              style: OaaType.body.copyWith(
                color: option.id == calibration.id
                    ? colors.textPrimary
                    : colors.textMuted,
              ),
            ),
          ),
      ],
      child: BarChip(text: calibration.name),
    );
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
    final colors = OaaTheme.of(context);
    // The accent edge is a sibling strip rather than a coloured `left`
    // BorderSide. A BoxDecoration may not combine a borderRadius with a
    // non-uniform Border: Flutter asserts, the decoration paint aborts, and it
    // takes the child with it — which shows up as a correctly sized box
    // containing nothing at all.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ClipRRect(
        borderRadius: OaaRadius.allSm,
        child: DecoratedBox(
          // The radius is repeated on the decoration, not only on the clip: a
          // square border inside a rounded clip loses its corners to the clip
          // and leaves four bare arcs. See `PanelScaffold` for the long note.
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: OaaRadius.allSm,
            border: Border.all(
              color: colors.hairline,
              width: OaaStroke.hairline,
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: severity ?? colors.warn,
                  child: const SizedBox(width: OaaStroke.emphasis),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.smd),
                    child: Text(
                      text,
                      style: OaaType.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
                if (onDismiss != null)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: Center(
                      child: OaaButton(label: 'Dismiss', onPressed: onDismiss!),
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
