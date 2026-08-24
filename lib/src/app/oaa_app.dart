// SPDX-License-Identifier: GPL-3.0-or-later

// `AppExitResponse` is a `dart:ui` enum rather than a Flutter one, so neither
// material.dart nor widgets.dart brings it into scope.
import 'dart:async' show Timer, unawaited;
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
import '../panels/report_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/theme_editor.dart';
import '../panels/shortcuts_sheet.dart';
import '../plugin/plugin_link.dart';
import '../remote/display_screen.dart';
import '../remote/remote_control.dart';
import '../remote/remote_display_service.dart';
import '../storage/startup_config.dart';
import 'bar_controls.dart';
import 'file_menu.dart';
import 'launch_options.dart';
import 'preset_file.dart';
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
      // **Counting routes, so the macOS File menu knows when to grey.** AppKit
      // offers a key equivalent to the main menu before the event reaches the
      // Flutter view, so ⌘O in the menu bar fires while a panel is open — where
      // the Dart bindings cannot, because a panel route sits above their
      // `FocusScope`. Without this the same chord would mean different things on
      // macOS and on Windows. See `RouteDepth`.
      navigatorObservers: ref.watch(navigatorObserversProvider),
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

  /// How often the local engine is asked whether its capture source is still
  /// there.
  ///
  /// A `Timer`, and not the meter clock that everything else in the application
  /// hangs off. Two reasons, both of which would have been bugs. A `Ticker`
  /// stops when the window is occluded — which is exactly when a tablet is the
  /// screen being used and a laptop lid is shut, so a source that stopped would
  /// go unrecovered for as long as somebody was relying on the remote display.
  /// And the clock reads whatever is *on the canvas*, which may be a plugin,
  /// while the thing that can stop is always the local engine.
  static const Duration _sourceWatchInterval = Duration(milliseconds: 500);

  /// How long a stopped source is left to the engine's own recovery before the
  /// application throws the engine away and opens a new one.
  ///
  /// The engine retries once a second and fixes everything that does not
  /// involve the format moving: a tap whose rebuild lost a race with a device
  /// change, a device the backend stopped. Two seconds is four polls — long
  /// enough that an outage the engine can repair is repaired without the
  /// integration being restarted, short enough that somebody watching the
  /// meters does not have time to conclude the application is broken.
  static const int _stallPollsBeforeReopen = 4;

  /// How many reopens that did not take before it stops reopening and says so.
  ///
  /// A source that stops again within seconds of every reopen is not going to
  /// be fixed by another one, and a loop of them would discard a measurement
  /// every two seconds for as long as the application stayed open. Three covers
  /// a device that is mid-reconfiguration; it is not enough to be a loop.
  static const int _reopensBeforeGivingUp = 3;

  /// Consecutive healthy polls that put the reopen budget back — thirty
  /// seconds of a source behaving. Without it the third outage of a session
  /// would be permanent, and a laptop that sleeps twice a day would stop
  /// recovering by the afternoon.
  static const int _healthyPollsToForgive = 60;

  Timer? _sourceWatch;

  /// Said out loud while the capture source is not delivering, because the one
  /// thing this state used to do was look like nothing.
  ///
  /// A `ValueNotifier` for the same reason `MeterClock.overrun` is one: it
  /// changes on a transition and must not rebuild the notice column twice a
  /// second in between.
  final ValueNotifier<String?> _sourceStopped = ValueNotifier<String?>(null);

  int _stalledPolls = 0;
  int _healthyPolls = 0;
  int _reopens = 0;

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

    _sourceWatch = Timer.periodic(_sourceWatchInterval, _watchSource);

    // The command line, after the first frame. Both halves need a context below
    // `MaterialApp` — a panel is a route, so it needs the `Navigator` this
    // widget is built under, and it cannot be opened from `main()`.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyLaunchOptions());
  }

  /// Notices that the capture source has stopped, and does something about it.
  ///
  /// This is the application's half of a bug that stood for eight phases, and
  /// the half that makes it visible. A capture source that stops — a tap whose
  /// output device changed to one at another sample rate, an interface the
  /// backend gave up on, a Bluetooth headset that switched to its 24 kHz voice
  /// mode — leaves the engine publishing an empty ring at the same forty-seven
  /// frames a second. Every meter holds its last reading. The window, the
  /// menus, the canvas and the tab strip all stay perfectly responsive around a
  /// picture that has stopped moving, RESET moves the readings to their floors
  /// and they hold *there*, and nothing anywhere says why. The only way out was
  /// to pick a different source and come back, which rebuilds the engine as a
  /// side-effect — which is precisely how it was reported: "the meters freeze,
  /// reset does nothing, and it only comes back when I switch to another
  /// source."
  ///
  /// The engine recovers what it can by itself, at the same format, so most
  /// outages never reach here. What reaches here is the one thing it cannot do
  /// from the inside: adopt a format that has moved. Every filter coefficient,
  /// the true-peak oversampler and the spectrum's axis are derived from the
  /// sample rate at creation, so following a device to a new one means building
  /// a new engine — and building a new engine is this widget's job.
  void _watchSource(Timer _) {
    if (!mounted) return;
    final engine = _engine;
    // Null means `_openFor` failed and `_EngineFailure` is already on screen
    // saying so in the engine's own words. Nothing to add and nothing to poll.
    if (engine == null) return;

    // The meter clock reads whatever is on the canvas, so while a plugin holds
    // it the local engine's snapshot can be minutes stale. One memcpy, twice a
    // second, on the same thread the clock reads from — two threads acquiring
    // one engine is undefined, and a `Timer` is not a second thread.
    engine.refresh();
    if (!engine.isSourceStopped) {
      _stalledPolls = 0;
      if (_sourceStopped.value != null) _sourceStopped.value = null;
      if (_reopens > 0 && ++_healthyPolls >= _healthyPollsToForgive) {
        _healthyPolls = 0;
        _reopens = 0;
      }
      return;
    }

    _healthyPolls = 0;
    _stalledPolls++;

    // Nothing is said while a plugin holds the canvas. The local engine is
    // still worth putting back — it is what the user returns to when they
    // remove the plugin — but "the meters are holding their last reading" is
    // flatly untrue about meters that are showing a DAW, and a notice nobody
    // can act on, over a picture it does not describe, is worse than none.
    final speak = !_onPlugin;

    if (_reopens >= _reopensBeforeGivingUp) {
      // Naming the workaround rather than offering a button, because there is
      // no button: choosing the source that is already chosen changes no
      // setting, so the source listener never fires and nothing reopens. Going
      // away and coming back is what actually works, and saying so beats
      // offering a control that does nothing.
      _sourceStopped.value = speak
          ? '$_sourceLabel has stopped sending audio $_reopens times and been '
                'reopened each time. Open Audio Analyzer has stopped reopening '
                'it. The meters are holding their last reading, not measuring '
                'silence. Pick another source, and come back to this one when '
                'the device has settled.'
          : null;
      return;
    }

    if (_stalledPolls < _stallPollsBeforeReopen) {
      _sourceStopped.value = speak
          ? '$_sourceLabel has stopped sending audio. The meters are holding '
                'their last reading, not measuring silence. Waiting for it to '
                'come back.'
          : null;
      return;
    }

    _stalledPolls = 0;
    _reopens++;
    _sourceStopped.value = null;
    if (speak) {
      ref
          .read(canvasNoticeProvider.notifier)
          .say(
            '$_sourceLabel stopped sending audio. Reopened it — the '
            'measurement starts again from here.',
          );
    }
    _openFor(ref.read(settingsProvider), afterStall: true);
  }

  /// Clears the integrating measurements, where that is possible.
  ///
  /// It is not possible for a plugin. Protocol version 3 opened the app →
  /// plugin direction, but it defines one control frame — `0x0020
  /// SET_LUFS_MODE` — and a reset is not it; `docs/WIRE.md` leaves
  /// `0x0021`–`0x002F` undefined. So rather than resetting the local engine
  /// nobody is looking at, which is what a button wired straight to it would
  /// do, this says so.
  void _reset() {
    final session = _plugins.active;
    if (session != null) {
      ref
          .read(canvasNoticeProvider.notifier)
          .say(
            'RESET cannot reach ${session.displayName}: the link carries no '
            'reset. Restart the integration in your DAW, or switch back to a '
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
      case StartupPanel.calibration:
        showCalibrationEditor(context);
      case StartupPanel.theme:
        // Opened on whatever skin is active, which is what somebody
        // screenshotting it wants: `--open-panel=theme` after picking Daylight
        // renders the editor in the light palette, and the two are the pair
        // worth looking at.
        showThemeEditor(context, ref, base: ref.read(skinProvider));
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
  void _openFor(AppSettings settings, {bool afterStall = false}) {
    // A source the *user* chose starts the watch afresh: the budget spent
    // recovering the last one says nothing about this one, and a stale
    // give-up notice sitting over a working meter is worse than no notice.
    if (!afterStall) {
      _stalledPolls = 0;
      _healthyPolls = 0;
      _reopens = 0;
      _sourceStopped.value = null;
    }

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
    _sourceWatch?.cancel();
    _sourceStopped.dispose();
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
    // **Above both branches, and above the status bar.** It drives the publish
    // service from the settings and the workspace, and a control the bar is
    // allowed to drop cannot be what does that — see `RemoteDisplayScope`. It
    // also carries the service to `showSettingsPanel`, which resolves it before
    // pushing the panel.
    // **Below the `Navigator` and above everything else.** The macOS menu bar's
    // commands open dialogs, so they need a route to open them over; a menu item
    // does not come with one. Off macOS it is a pass-through.
    return MacFileMenuHost(
      child: RemoteDisplayScope(
        service: _remote,
        child: Material(
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
                            // card would still be taking 132 px off a bar that
                            // measures its width in tens.
                            transportOf: _onPlugin
                                ? () =>
                                      _plugins.active?.transport ??
                                      Transport.none
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
                                        'frames never reached the measurement. '
                                        'Integrated loudness and '
                                        'LRA average every block since the reset, so '
                                        'they are now averages of less than what '
                                        'played and cannot be trusted. Press RESET '
                                        'to start a clean measurement.',
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        // **A source that stopped, which used to be the one
                        // failure with no symptom at all.** The engine goes on
                        // publishing an empty ring, so the meters hold their last
                        // reading and the rest of the application stays perfectly
                        // alive around them — see `_watchSource`. Local only: a
                        // plugin's audio arrives over a socket, and a link that
                        // has gone quiet is a different fact with its own
                        // reporting.
                        ValueListenableBuilder<String?>(
                          valueListenable: _sourceStopped,
                          builder: (context, stopped, _) => stopped == null
                              ? const SizedBox.shrink()
                              : _NoticeSlot(
                                  child: _Notice(
                                    severity: colors.over,
                                    text: stopped,
                                  ),
                                ),
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
                        // **A switch that came back off, and did not say why.**
                        // `setEnabled(true)` leaves `isPublishing` false when the
                        // port cannot be bound — the usual cause is a second copy
                        // of Open Audio Analyzer already running — so the switch
                        // in the bar flicks on and back off under the pointer with
                        // the reason written somewhere nobody is looking.
                        ValueListenableBuilder<String?>(
                          valueListenable: _remote.failure,
                          builder: (context, failure, _) => failure == null
                              ? const SizedBox.shrink()
                              : _NoticeSlot(
                                  child: _Notice(
                                    severity: colors.over,
                                    text: 'Could not publish: $failure',
                                  ),
                                ),
                        ),
                        // **Publishing to nobody, which is the failure with no
                        // symptom on this machine.** The port is open, a display
                        // handed the address by hand connects and draws meters
                        // perfectly, and only the announcement is gone — so the
                        // desk looks healthy from the desk and the one screen that
                        // knows is the tablet, which has no diagnostics on it. It
                        // used to be written on the pairing panel's own row, where
                        // it was seen because that panel was the way in to
                        // everything; with the switch in the bar there is no
                        // longer a panel anybody has a reason to open. So it is
                        // said here, beside the other two faults that are true
                        // right now, and only while publishing is actually on.
                        ValueListenableBuilder<bool>(
                          valueListenable: _remote.isPublishing,
                          builder: (context, publishing, _) => !publishing
                              ? const SizedBox.shrink()
                              : ValueListenableBuilder<String?>(
                                  valueListenable: _remote.advertisementFailure,
                                  builder: (context, advertisement, _) =>
                                      advertisement == null
                                      ? const SizedBox.shrink()
                                      : _NoticeSlot(
                                          child: _Notice(
                                            severity: colors.warn,
                                            text:
                                                '$advertisement Publishing is '
                                                'working — a display given this '
                                                'machine’s address by hand, or '
                                                'sent the pairing code, still '
                                                'connects.',
                                          ),
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
                          child: GridCanvas(
                            engine: plugin ?? engine,
                            clock: clock,
                          ),
                        ),
                      ],
                    ),
                  ),
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
          // width below which the rest no longer fit. What stays at the
          // narrowest width is what the rule above says stays: the source, the
          // elapsed clock, the delivery target and RESET.
          //
          // **Most of what leaves is still reachable and PUBLISH is not.**
          // ANALYSE FILE, SETTINGS, RESET and `?` all have shortcuts, listed in
          // the sheet the `?` opens and in docs/site/keyboard.md. The three
          // remote controls have none, so under the lowest gate there is no way
          // in the application to stop publishing. That width is under every
          // desktop minimum except macOS's, which is the only platform that
          // sets one — and a chord that opens a network socket by accident is
          // the wrong fix. It is stated rather than papered over: this is the
          // one item whose absence takes a capability away instead of hiding
          // it.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;

              // **FILE is in this row on two platforms out of three, and every
              // gate above its own is that much further out there.** A gate is
              // a statement about the width at which everything up to and
              // including that item still fits, so an item added below one
              // moves it — the same arithmetic that moved every gate by 165 px
              // when one control became three. macOS keeps the numbers exactly
              // as they were measured, because there the menu is in the system
              // menu bar and this button does not exist.
              //
              // 58 px: the button and the seam before it. Measured the way the
              // rest of this row is — `test/scaling_test.dart` sweeps the bar
              // with the button drawn, and it failed at five widths with the
              // gates left where macOS wants them.
              final menuInWindow = ref.watch(fileMenuInWindowProvider);
              final file = menuInWindow ? 58.0 : 0.0;
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
              // Somewhere below 504 the irreducible set — source, clock,
              // target, SETTINGS, RESET — does not fit either, and there is no
              // honest item left to drop. 504 is the narrowest row
              // `test/scaling_test.dart` sweeps and it fits — with 8 px to
              // spare, which the chip and its seam took 24 of. A measured
              // width rather than the round number this used to be, and either
              // way barely half the supported minimum window: what happens
              // below it is left to the platform.
              // The transport readout is the widest single item the bar can
              // gain — 92 px and its two gaps — and the only one that is not
              // always there, so it opens last and highest. It is measured the
              // same way as the rest: with the readout forced on and the
              // longest target name there is, and leaving the same ~35 px of
              // margin the gates below it carry. Every gate above the remote
              // group moved by 161 px when one control there became three.
              // `test/scaling_test.dart` sweeps the bar with a real plugin
              // attached, which is the only state this item exists in.
              // **Every one of them moved in the change that put the source
              // in a chip**, because every one is a number about the *left
              // group's* floor as much as about its own item: what overflows
              // at the bottom of the bar is the group inside the `Expanded`,
              // and that group's floor is now a bordered chip — its dot, plus
              // 16 px of padding, plus the seam after it. 25 px for the five
              // gates below the format readout, where that seam is 8; 40 for
              // the format gate and the one above it, where it is 24. The
              // margins are the ~35 px they were.
              final showTransport = transportOf != null && width >= 1270 + file;
              final showFormat = width >= 1105 + file;
              final showAnalyse = width >= 920 + file;
              // **Three gates where there was one, and PUBLISH outlives both
              // the things it enables.** Whether this machine has an
              // unauthenticated port open is the fact the bar exists to keep
              // legible, so it is the last of the group to go. The pairing code
              // outlives ATTACH because it is half of the switch beside it —
              // publishing you cannot hand anybody the address for is publishing
              // to nobody — while becoming somebody else's display is a thing
              // you go looking for, and a window this narrow is not one anybody
              // goes looking from. All three numbers are measured, like the rest
              // — see `test/scaling_test.dart`.
              final showAttach = width >= 820 + file;
              final showPairingCode = width >= 735 + file;
              final showPublish = width >= 685 + file;
              // The lowest gate, so the item it drops is the last thing
              // standing between the row and its irreducible set. The source
              // picker gives ground with an ellipsis until it is down to its
              // dot, and that is the group's floor: with `?` open at 524 px of
              // row, the group had 34 px to put a 38 px chip in and ran 4 px
              // past its edge. `test/scaling_test.dart` sweeps this band at
              // five pixels with the longest names there are, which is the
              // only stride and the only content that sees it.
              // **FILE outlives every other command in the row.** Off macOS it
              // is the only way to reach Open and Save without the keyboard,
              // where ANALYSE FILE, SETTINGS and RESET all have a chord and are
              // listed in the sheet. It does not outlive `?`, which is how
              // somebody finds out that the chords exist at all — under this
              // gate the window is narrower than anything anybody arranges
              // meters in, and ⌘O still works.
              //
              // On macOS the button is not built at all: the menu is in the
              // system bar. So this gate has to hold for the platforms where it
              // *is* built, which is what makes it a gate and not a saving.
              final showFile = menuInWindow && width >= 620;
              final showHelp = width >= 555;

              // The document, in the leading slot the wordmark used to have —
              // and it earns it by the same test that took the wordmark out.
              // Three capitals that never changed said nothing about the work;
              // which preset is open, and whether it has been saved, changes
              // while you work and is written down nowhere else in the window.
              //
              // **The highest gate below the transport readout, and it leaves
              // before the format does**, which is the row's own priority
              // rather than a fitting exercise: everything else in this group
              // says what the reading *is*, and this says what the workspace
              // is. It is also the widest fixed item in the group — 150 px and
              // a group seam — and the group's floor is what overflows first.
              //
              // Measured, like the rest. At 1124 px of row with a plugin's name
              // in the source chip the bar ran 9.3 px past its edge, because a
              // fixed 174 px here starves the one item beside it that shrinks:
              // the chip was squeezed to 4.7 px and overflowed inside itself.
              // 1170 is that threshold plus the ~35 px this file carries above
              // every other one. **The gate is on the row, not the window** —
              // on macOS they differ by 96 px, so this is about 1266 px of
              // window; see the plugin band in `test/scaling_test.dart`.
              final showPreset = width >= 1170 + file;

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
                        if (showPreset) ...[
                          const _PresetReadout(),
                          // A boundary between two groups rather than a seam
                          // between two controls: everything after this is
                          // about the signal, and this is about the file.
                          const SizedBox(width: Space.xs),
                        ],
                        // **No wordmark.** The window is the application's
                        // name and the bar's job is what changes while you
                        // work; three capitals that never change were the one
                        // item here that said nothing about the signal. Its
                        // gate went with it, and the gates above it are left
                        // where they are — they are the widths at which the
                        // row still *fits*, and it now fits with about 34 px
                        // to spare above 955.
                        Flexible(
                          child: _SourcePicker(
                            label: sourceLabel,
                            settings: settings,
                          ),
                        ),
                        if (showFormat) ...[
                          const SizedBox(width: Space.md),
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
                        // **The seam between the two groups, and it is the
                        // left group that pays for it.** The group's children
                        // pack left, so the space after them is whatever the
                        // window is not using — which is zero from the moment
                        // the row is full. That used to mean the sample rate
                        // ran flush into the playhead, and it was stated and
                        // left alone; a bordered source chip makes it a
                        // hairline touching the elapsed clock's digits, which
                        // is the spacing mistake the eye does catch in a row
                        // whose borders are its only horizontal line.
                        //
                        // Inside the `Expanded` rather than after it, which is
                        // what makes it free: a fixed box out in the bar's own
                        // row would add 24 px to a sum that does not shrink and
                        // move every gate above. Here the picker gives up 24 px
                        // of name it was going to ellipsise anyway, and the only
                        // number that moves is the lowest gate — the left
                        // group's floor is now the chip plus this.
                        //
                        // **Sized to what is on the other side of it, which
                        // is the item this group ends with.** Above the format
                        // gate that is a text readout and the seam is a
                        // boundary between two groups, which is `Space.lg` and
                        // is asserted as such — `test/scaling_test.dart` holds
                        // the distance from the sample rate to the playhead,
                        // the one thing in this row an overflow check cannot
                        // see. Below it the group ends in a bordered chip and
                        // the seam is a seam between controls, which is the
                        // `Space.sm` every gap in the right-hand group is.
                        //
                        // Not a saving: 24 px at the bottom of the bar does
                        // not exist. With the chip's own 16 it put the left
                        // group's floor past the row at 600 px and past the
                        // analyse gate at 1000, and 8 is what the item beside
                        // it wants there anyway.
                        SizedBox(width: showFormat ? Space.lg : Space.sm),
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
                    // No gap of its own: the left group carries the boundary
                    // now and carries it at every width, which is what the
                    // conditional one here could not do — the gap existed only
                    // when a plugin was attached and the window was wide enough
                    // to show its readout.
                    TransportReadout(
                      transportOf: transportOf!,
                      repaint: clock,
                      // Packed left, like the tablet's — and there is nothing
                      // left over to push anywhere, because the box is the
                      // width of the format the host is reporting rather than
                      // of the widest one there is. See the note at the top of
                      // `transport_readout.dart`.
                      align: TransportAlign.leading,
                    ),
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
                  // Before the switch, because it hands out the address of the
                  // port the switch opens and is inert until that port is open.
                  // At the row's own `Space.sm` like every other seam in it: a
                  // tighter gap to pair the two visually was tried, and a seam
                  // that is 4 px where its neighbours are 8 does not read as
                  // grouping — it reads as a spacing mistake, which in a row
                  // whose borders are the only horizontal line is the one thing
                  // the eye does catch.
                  if (showPairingCode) ...[
                    const SizedBox(width: Space.sm),
                    PairingCodeButton(service: remote),
                  ],
                  if (showPublish) ...[
                    const SizedBox(width: Space.sm),
                    PublishSwitch(service: remote),
                  ],
                  if (showAttach) ...[
                    const SizedBox(width: Space.sm),
                    const AttachButton(),
                  ],
                  // Before ANALYSE FILE because the menu it opens holds it,
                  // and reading order should not put a command after the menu
                  // that also offers it.
                  if (showFile) ...[
                    const SizedBox(width: Space.sm),
                    const FileMenuButton(),
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
                  // chrome, so the usual place a desktop user reads a shortcut
                  // off — the chord printed beside a menu item — covers four of
                  // them and nothing else. The File menu prints ⌘O, ⌘I, ⌘S and
                  // ⇧⌘S; every other chord in the application is in this sheet
                  // and nowhere a pointer can reach, and without this button the
                  // sheet is only reachable by pressing the key that opens the
                  // list of keys.
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

/// Which preset is open, and whether it has been saved.
///
/// Not a [BarChip], though it sits where one would. The bar's two chips are the
/// menus that hold a value — what is being metered, and what against — and they
/// wear a border because they can be clicked. This is a readout: it is the
/// window's title, in the bar that is the window's title bar on macOS, and a
/// border round it would promise a menu that is not there. Off macOS the menu is
/// two items to the right and says FILE.
///
/// **The dot's slot is reserved whether or not there is a dot.** It is one
/// character, but it is one character on the *left* of everything in the group
/// beside it — a mark that appears when you drag a module would shift the source,
/// the sample rate and the playhead by 10 px each time the layout changed.
class _PresetReadout extends ConsumerWidget {
  const _PresetReadout();

  /// Long enough for the names people give these ("Mastering — client B"),
  /// short enough that it is not competing with the source for the group's
  /// slack. Beyond it the name ellipsises, like both pickers.
  static const double _maxWidth = 150;

  /// The mark's reservation. `•` in the label style plus the seam before it.
  static const double _markWidth = Space.sm + Space.xs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = OaaTheme.of(context);
    final name = ref.watch(workspaceProvider).preset.name;
    final modified = ref.watch(presetModifiedProvider);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `Flexible` inside a `ConstrainedBox`, for the reason `BarChip`
          // gives: without it the text is measured against unbounded width and
          // takes it, where the bar's own gates cannot see it.
          Flexible(
            child: Text(
              name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: OaaType.label.copyWith(color: colors.textMuted),
            ),
          ),
          SizedBox(
            width: _markWidth,
            child: modified
                ? Text(
                    ' •',
                    style: OaaType.label.copyWith(color: colors.textFaint),
                  )
                : null,
          ),
        ],
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
            for (final device in devices) ...[
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
              // The system-output tap is enumerated first and is not a piece of
              // hardware — it captures whatever is going to the speakers. A
              // rule under it says so without a label having to, and there is
              // never more than one, so this cannot produce two dividers in a
              // row.
              if (device.isSystemOutput) const PopupMenuDivider(),
            ],
        ];
      },
      // **The same shape as the delivery target's menu, because it is the same
      // kind of thing.** Both report what a reading is rather than doing
      // something, both open on a click, and one of them looked like a caption.
      // The 220 px cap and the ellipsis inside the chip are what keep it
      // shrinkable: a `ConstrainedBox` caps how wide the name may *grow* and
      // does not make it shrink, and the picker sits in a `Flexible` in a row
      // with no slack — see `BarChip`.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: BarChip(
          text: label,
          lit: settings.sourceKind != AudioSourceKind.silence,
        ),
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
      height: OaaMenuRow.height,
      // The row owns its padding, because the fill that marks the source
      // currently being metered has to span it. See [OaaMenuRow].
      padding: EdgeInsets.zero,
      child: OaaMenuRow(
        colors: colors,
        selected: selected,
        child: Text(
          text,
          style: OaaType.body.copyWith(
            color: selected ? colors.textPrimary : colors.textMuted,
          ),
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
            height: OaaMenuRow.height,
            padding: EdgeInsets.zero,
            child: OaaMenuRow(
              colors: colors,
              selected: option.id == calibration.id,
              child: Text(
                option.name,
                style: OaaType.body.copyWith(
                  color: option.id == calibration.id
                      ? colors.textPrimary
                      : colors.textMuted,
                ),
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
