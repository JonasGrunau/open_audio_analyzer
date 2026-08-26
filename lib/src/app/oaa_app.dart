// SPDX-License-Identifier: GPL-3.0-or-later

// `AppExitResponse` is a `dart:ui` enum rather than a Flutter one, so neither
// material.dart nor widgets.dart brings it into scope.
import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;
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
import '../data/mic_permission.dart';
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

  /// Whether a microphone request is open, so a second one is not started.
  ///
  /// Android only, and only ever true while its dialog is on screen. The
  /// settings listener fires on every change of source, and a user who taps
  /// through two inputs while the dialog is up would otherwise stack requests
  /// the platform side refuses one at a time.
  bool _askingForMic = false;

  /// Publishing to a tablet, owned here rather than by the status-bar button
  /// that switches it on.
  ///
  /// Two reasons, and both were bugs. It holds a socket and a publish timer
  /// pointed at the engine, so it has to be told when the engine is replaced —
  /// otherwise it keeps acquiring through a destroyed one and sends freed memory
  /// to the tablet as a measurement. And the button that used to own it is
  /// dropped from the bar below 620 px of window width, so narrowing the
  /// window tore down an active session with nothing anywhere saying why. That
  /// gate is gone — the remote group survives every width the menu bar is built
  /// at now — but the rule it taught is not: a control a row may drop is a
  /// control nothing may depend on running.
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

    // **Android will not open a capture device until the user has been asked.**
    // Every other platform grants capture through the act of opening one, so
    // this is the only place in the application that has to ask first — and
    // asking here rather than at launch means a tablet that only ever mirrors
    // another machine's meters is never asked at all. `isRequired` is false
    // everywhere else, so this whole branch compiles out of five of six builds.
    //
    // Re-entrant by design: the answer arrives a dialog later, and the second
    // pass through `_openFor` finds the permission held and opens the device.
    // The test tone and silence do not touch an input and never come through
    // here, which is what keeps the canvas alive while the dialog is up.
    if (source == OaaSource.device && MicPermission.isRequired) {
      unawaited(_openForWithMic(settings, label, afterStall: afterStall));
      return;
    }

    _openResolved(source, deviceId, label);
  }

  /// Asks for the microphone, then opens the source it is for.
  ///
  /// Split out of [_openFor] so that the synchronous path — which is every
  /// platform but Android, and Android's own built-in sources — stays
  /// synchronous. A `setState` after an await needs its `mounted` check, and a
  /// source the user changed *while the dialog was up* has to win over the one
  /// that opened it, which is what re-reading the settings at the end is for.
  Future<void> _openForWithMic(
    AppSettings settings,
    String label, {
    required bool afterStall,
  }) async {
    if (_askingForMic) return;
    _askingForMic = true;
    final granted = await MicPermission.ensure();
    _askingForMic = false;
    if (!mounted) return;

    if (!granted) {
      // Not a fault, and not something to retry: the user answered. Say so
      // where every other source failure is said, and leave whatever was
      // playing alone rather than tearing the canvas down over it.
      setState(() {
        _failure =
            'Open Audio Analyzer needs the microphone to measure an input. '
            'Android has refused it — grant it in Settings › Apps › Open Audio '
            'Analyzer › Permissions, or pick another source.';
        _sourceLabel = label;
      });
      return;
    }

    // The dialog is modal but the settings are not frozen behind it, and the
    // engine this method was called for may no longer be the one wanted.
    final (source, deviceId, current) = _resolve(ref.read(settingsProvider));
    _openResolved(source, deviceId, current);
  }

  /// The engine swap itself, once there is nothing left to ask.
  void _openResolved(OaaSource source, String? deviceId, String label) {
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
    // **Above both branches, and above both bars.** It drives the publish
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
                        // The menu bar is the window's title bar as well on
                        // macOS — there is no system one left to drag. See
                        // window_chrome.dart.
                        WindowDragArea(
                          child: _MenuBar(remote: _remote, onReset: _reset),
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
                        // **Under the canvas, which is what makes it a status
                        // bar rather than a second menu bar.** Everything in it
                        // is a reading or the units of one, and a reading
                        // belongs at the edge of the thing it is about: the
                        // window's own bottom edge is where a person's eye goes
                        // for "what is this and how long has it been running",
                        // and it is not somewhere a pointer travels on its way
                        // to a command. It is outside `WindowDragArea` on
                        // purpose — the window is dragged by its title bar, and
                        // this row is not one.
                        _StatusBar(
                          source: plugin ?? engine,
                          clock: clock,
                          sourceLabel: _onPlugin
                              ? _plugins.active!.displayName.toUpperCase()
                              : _sourceLabel,
                          // Null unless a DAW could be on the other end. The
                          // readout itself draws nothing when a host has said
                          // nothing, so this is about the *row*: an item that is
                          // permanently blank on every machine metering a sound
                          // card would still be taking 108 px off a row that
                          // measures its width in tens.
                          transportOf: _onPlugin
                              ? () =>
                                    _plugins.active?.transport ?? Transport.none
                              : null,
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
            // has no source picker to change it from.
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
            // through the menu bar that this screen does not have — which
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

// ---------------------------------------------------------------------------
// The two bars

/// The bar across the top: the commands, and the document they act on.
///
/// **It was the status bar for eight phases, and everything it reported is in
/// [_StatusBar] across the bottom of the window now.** What is left is what you
/// *do* — the File menu, the three remote controls, the two panels, RESET and
/// the shortcut sheet — with the open preset's name centred between them.
///
/// The split is the whole point rather than a tidying. One row holding the
/// source, the format, two clocks, the delivery target and eight commands had
/// no width left for the document's own name: the name had the highest gate in
/// the bar below the playhead's and was gone under 1170 px of row, and the
/// readings it competed with are the things a person *reads* while working
/// rather than presses. Reading a measurement and pressing a button are two
/// different acts and they have a row each now. What that bought is measurable:
/// the top row fits every one of its controls at 480 px, where the old bar had
/// dropped four of them and was still 121 px over its edge at the narrowest
/// window a platform allowed.
///
/// **PUBLISH no longer has a gate, and that closes a hole this bar used to
/// document.** It was the last of the remote group to be dropped, and below its
/// gate there was no way anywhere in the application to stop publishing — a
/// capability taken away by a window width. With the readings gone the whole
/// group fits at every width the row is built at.
///
/// **On macOS this is still the window's title bar** — there is no system one
/// left to disagree with it — which is what a centred document name is the Mac
/// idiom for, and why the row leaves the window buttons room at its leading
/// edge. See `window_chrome.dart`.
class _MenuBar extends ConsumerWidget {
  const _MenuBar({required this.remote, required this.onReset});

  /// Passed through rather than created here: this widget rebuilds whenever the
  /// document does, and a socket owned by a `build` is a socket a rebuild can
  /// tear down. See `RemoteDisplayScope`.
  final RemoteDisplayService remote;

  /// Not `engine.reset`: a plugin cannot be reset from here, and a button that
  /// silently resets a source nobody is looking at is worse than one that says
  /// it cannot. See `_WorkspaceState._reset`.
  final VoidCallback onReset;

  static const double height = BarMetrics.rowHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = OaaTheme.of(context);

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;

            // Leading and trailing rather than symmetric: on macOS the three
            // window buttons are drawn over the top of this bar, and Open Audio
            // Analyzer cannot start until they have ended. See
            // `WindowChrome.menuBarLeading`.
            final leading = WindowChrome.menuBarLeading;

            // **FILE exists only where there is no system menu bar to put the
            // File menu in.** It costs the leading group 66 px on Windows and
            // Linux and nothing on macOS — where the window buttons cost 64 of
            // it anyway, which is why the numbers below hold on all three
            // platforms from one set of measurements. `test/scaling_test.dart`
            // sweeps the row in both arrangements.
            final inWindow = ref.watch(fileMenuInWindowProvider);

            // **Where each group ends, measured from the window's own edge**,
            // which is what the centred name has to clear. The leading number
            // carries the window buttons on macOS and the FILE button off it,
            // because both sit between the window's edge and the first thing
            // that could touch them; the two arrangements come to 186 px and
            // 188 px, so one set of numbers answers all three platforms.
            //
            // **The groups are grouped by meaning rather than by width, and the
            // name pays for it.** A file on disk is on the left — the document
            // the canvas came from, and a recording to measure — and everything
            // that is another screen or this application's own state is on the
            // right. That leaves 186 px against 394 px, and a name centred in
            // the *window* has to clear the wider of the two twice over, so it
            // needs 900 px of window before there is room to draw it. That is
            // under the narrowest window the application supports, which is the
            // number that had to be beaten: the readout this replaced needed
            // 1266 px, and was in neither the middle nor a group.
            final leadingWith =
                leading +
                (inWindow ? BarMetrics.file + Space.sm : 0) +
                BarMetrics.analyse;
            final leadingWithout = leading + (inWindow ? BarMetrics.file : 0);
            const trailingAll =
                Space.md +
                BarMetrics.pairingCode +
                Space.sm +
                BarMetrics.publish +
                Space.sm +
                BarMetrics.attach +
                Space.sm +
                BarMetrics.settings +
                Space.sm +
                BarMetrics.reset +
                Space.sm +
                BarMetrics.help;

            // Two gates, in the order the items leave: the two commands with a
            // chord and a menu row behind them. Everything else in the row
            // stays at every width the row is built at.
            //
            // ANALYSE FILE goes first because ⌘I reaches it and the File menu
            // lists it — it is the one command here that is offered three ways.
            // ATTACH second because becoming somebody else's display is a thing
            // you go looking for, and a window this narrow is not one anybody
            // goes looking from; the pairing code stays because it is half of
            // the switch beside it, and publishing you cannot hand anybody the
            // address for is publishing to nobody.
            //
            // Arithmetic on the table above rather than two measured totals, so
            // that a label growing moves the gate that admits it instead of
            // being caught by the margin — and so that macOS's window buttons
            // and the other platforms' FILE button, which differ by 2 px, are
            // each answered with their own number. Below 394 px the row has
            // nothing left it is honest to drop; that is well under half the
            // narrowest window any of the three platforms allows, and
            // `test/scaling_test.dart` sweeps to 480.
            final showAnalyse =
                width >= leadingWith + trailingAll + BarMetrics.margin;
            final showAttach =
                width >=
                (showAnalyse ? leadingWith : leadingWithout) +
                    trailingAll +
                    BarMetrics.margin;

            final leadingEdge = showAnalyse ? leadingWith : leadingWithout;
            final trailingEdge =
                trailingAll - (showAttach ? 0 : BarMetrics.attach + Space.sm);

            // **Centred in the window, so the room is symmetric about its
            // centre and has to clear the wider group twice.** That is what
            // makes it a title rather than an item, and it is also why the two
            // marks in the trailing group are worth what they cost a reader:
            // with `SETTINGS` and `RESET` spelled out, the wider group is 455 px
            // and this arithmetic gives the name nothing at all until 1026 px of
            // window. With the marks it has 124 px at the narrowest window the
            // application supports and 604 px at the default one.
            final room =
                width -
                2 * math.max(leadingEdge, trailingEdge) -
                2 * BarMetrics.titleGap;

            return Stack(
              // Both layers are the row: one holds the controls, the other
              // holds the name centred between them. Expanded rather than the
              // default loose fit, or a `Center` in here shrink-wraps its child
              // and is then aligned to the stack's own corner.
              fit: StackFit.expand,
              children: [
                // **A layer of its own, and not a child of the row.** A row can
                // only centre a child between its neighbours, and these
                // neighbours are nothing like the same width — 186 px of window
                // buttons and one command against 394 px of everything else.
                // Centred in the window is what a document's name means, on the
                // row that is the window's title bar on macOS; centred between
                // those two groups it would sit 104 px left of where a reader
                // looks for it.
                //
                // Nothing overlaps because [room] is what the wider group
                // leaves: it is the *smaller* of the two clearances, doubled, so
                // a title that fits it clears both. Below the floor there is no
                // title at all rather than a name given three characters and an
                // ellipsis. `test/scaling_test.dart` measures the distance from
                // the name to every control in the row at every width it sweeps,
                // which is the assertion an overflow check cannot make: two
                // layers of a `Stack` overlap in silence.
                if (room >= BarMetrics.titleFloor)
                  Center(
                    child: SizedBox(
                      width: math.min(room, BarMetrics.titleCap),
                      child: const _PresetTitle(),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(left: leading, right: Space.md),
                  child: Row(
                    children: [
                      // **FILE all the way at the leading edge**, where a menu
                      // bar's first menu is on every platform that has one. On
                      // macOS that is where the system menu bar already puts it
                      // and this button is not built at all.
                      if (inWindow) ...[
                        const FileMenuButton(),
                        // **The row's own seam, like every other gap in it.**
                        // This was `Space.md`, on the reasoning that a menu and
                        // a command are two kinds of thing and deserve a group
                        // boundary between them. On screen it is one gap in a
                        // row of eight that is twice the others, which reads as
                        // a control that was placed rather than as two groups —
                        // the same lesson the pairing code learnt in the other
                        // direction further down this row, where 4 px between
                        // two related controls read as a spacing mistake rather
                        // than as grouping.
                        const SizedBox(width: Space.sm),
                      ],
                      // **After the menu that also offers it**, which is why it
                      // is on this side of the row: the File menu's second entry
                      // is "Analyse an audio file…", and reading order should
                      // not put a command before the menu that holds it. Both of
                      // them are a file on disk; nothing else in this row is.
                      if (showAnalyse)
                        BarButton(
                          label: 'ANALYSE FILE',
                          onPressed: () => showReportPanel(context),
                        ),
                      // **The slack, and the row's only flexible child.**
                      // Nothing in either group may be `Flexible`: `Spacer` is
                      // an `Expanded` with `flex: 1` and `Flexible` defaults to
                      // `flex: 1` too, so `RenderFlex` would divide the free
                      // space between them — the Spacer is tight and takes its
                      // share, a loose `Flexible` takes only what its child asks
                      // for, and the difference is laid out after the last
                      // child. The whole trailing group then drifts left by half
                      // of every pixel the window gains, with nothing
                      // overflowing and no assertion fired.
                      const Spacer(),
                      // Before the switch, because it hands out the address of
                      // the port the switch opens and is inert until that port
                      // is open. At the row's own `Space.sm` like every other
                      // seam in it: a tighter gap to pair the two visually was
                      // tried, and a seam that is 4 px where its neighbours are
                      // 8 does not read as grouping — it reads as a spacing
                      // mistake, which in a row whose borders are the only
                      // horizontal line is the one thing the eye does catch.
                      PairingCodeButton(service: remote),
                      const SizedBox(width: Space.sm),
                      PublishSwitch(service: remote),
                      if (showAttach) ...[
                        const SizedBox(width: Space.sm),
                        const AttachButton(),
                      ],
                      const SizedBox(width: Space.sm),
                      // **A mark rather than the word, and the word is what it
                      // cost the row.** `SETTINGS` and `RESET` were 145 px of a
                      // trailing group that a centred document name has to clear
                      // twice over; two marks are 84, and that 61 px is the
                      // difference between the name being on screen at the
                      // narrowest window the application supports and it needing
                      // 1026 px. See `OaaMark`, where the exception to a closed
                      // set of marks is argued.
                      BarButton(
                        mark: OaaMark.settings,
                        tooltip: 'Settings',
                        semanticLabel: 'Settings',
                        onPressed: () => showSettingsPanel(context),
                      ),
                      const SizedBox(width: Space.sm),
                      BarButton(
                        mark: OaaMark.restart,
                        // **The scope was always in the tooltip, which is what
                        // makes this one safe to draw as a mark.** `RESET` beside
                        // `SETTINGS` in identical chrome read as "reset
                        // everything" — the layout, the target, the application —
                        // when what it discards is the integration in progress,
                        // so this sentence has been carrying the part that
                        // matters from the start. Somebody twenty minutes into an
                        // integrated measurement needs to know that before they
                        // click, not after.
                        //
                        // Wording tracks the contract at oaa_engine_reset() in
                        // oaa.h. If that changes, this changes with it — a
                        // button that describes the wrong thing is worse than one
                        // that describes nothing.
                        tooltip:
                            'Restart the measurement — integrated loudness, '
                            'LRA, the max-since-reset peaks, the clip counters '
                            'and the elapsed clock. Momentary readings, the '
                            'layout and the delivery target are untouched.',
                        semanticLabel: 'Restart the measurement',
                        onPressed: onReset,
                      ),
                      const SizedBox(width: Space.sm),
                      // Last, and outside the working set on purpose.
                      // Everything to its left is something you do to the
                      // measurement or to the machine; this is about the
                      // application. It keeps its `?` where the two beside it
                      // became marks, because a question mark *is* the mark for
                      // it — and it is a third of the width of the shortest
                      // honest word for a sheet of key bindings.
                      //
                      // It exists at all because Open Audio Analyzer draws its
                      // own chrome, so the usual place a desktop user reads a
                      // shortcut off — the chord printed beside a menu item —
                      // covers four of them and nothing else. The File menu
                      // prints ⌘O, ⌘I, ⌘S and ⇧⌘S; every other chord in the
                      // application is in this sheet and nowhere a pointer can
                      // reach, and without this button the sheet is only
                      // reachable by pressing the key that opens the list of
                      // keys.
                      BarButton(
                        label: '?',
                        // Drawn at a mark's size, because that is what it is
                        // now standing among: at the row's 10 px it was the
                        // smallest ink in a group that is otherwise two marks
                        // in a 16 px box. See `BarButton.labelIsMark`.
                        labelIsMark: true,
                        tooltip: 'Keyboard shortcuts',
                        semanticLabel: 'Keyboard shortcuts',
                        onPressed: () => showShortcutsSheet(context),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The bar across the bottom: what is being measured, for how long, against
/// what.
///
/// **Everything here is a reading or the units of one, and that is the whole
/// membership rule.** The source and the format say what is being measured; the
/// playhead and the elapsed clock say when and for how long; the delivery target
/// is what every PASS and FAIL on the canvas is a verdict against, which makes
/// naming it beside the readings the meter's units rather than a shortcut to a
/// setting. Nothing in this row does anything to the measurement — the two
/// pickers change what is *measured* and what it is measured *against*, which is
/// the same statement read the other way round.
///
/// **The two pickers are chips and stay chips.** They report a value and open on
/// a click, and the source spent eight phases as a bare dot and a word beside
/// four bordered controls, which reads as a caption rather than as a menu: the
/// commonest thing anybody changes in either bar was the one item that did not
/// look changeable. See `BarChip`.
///
/// It is not the window's title bar and has no window buttons drawn over it, so
/// unlike [_MenuBar] its leading padding is `Space.md` on every platform and its
/// gates are one set of numbers rather than two.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.source,
    required this.clock,
    required this.sourceLabel,
    required this.transportOf,
  });

  /// What is being measured: this machine's engine, or a connected plugin's
  /// frames.
  final MeterSource source;

  final MeterClock clock;

  final String sourceLabel;

  /// The DAW's playhead, read at paint time, or null when nothing being metered
  /// could have one.
  ///
  /// A getter rather than a `Transport`, because this widget rebuilds a few
  /// times an hour and the position moves ninety times a second. See
  /// [TransportReadout].
  final Transport Function()? transportOf;

  static const double height = BarMetrics.rowHeight;

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
    //
    // **In this row rather than the one above because this is the row that
    // watches the settings anyway**, and neither bar is ever dropped — only
    // items inside them are. Anything that has to keep happening whatever the
    // window is doing belongs above both, in `RemoteDisplayScope`.
    clock.targetFps = settings.targetFps;
    clock.reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.panel,
          // The hairline is on top here, because the edge this row shares with
          // the canvas is its upper one. The two bars' borders face each other.
          border: Border(
            top: BorderSide(color: colors.hairline, width: OaaStroke.hairline),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;

            // The row with nothing in it that a gate can take away: what is
            // being measured, for how long, and against what. 384 px, so it
            // fits at 480 with room to spare — which is where both rows stop
            // and half the narrowest window any platform allows.
            const irreducible =
                Space.md * 2 +
                BarMetrics.chipFloor +
                Space.sm +
                BarMetrics.elapsed +
                Space.md +
                BarMetrics.pickerCap;

            // Two gates, in the order the items leave, both arithmetic on the
            // table above and both counting the *longest* string the item can
            // print rather than the one this machine happens to be showing.
            // That distinction is the one that ships: the format readout is
            // 112 px at 48 kHz stereo and 126 at 192 kHz with 24 channels.
            //
            // The playhead is the widest single item this row can gain — 92 px
            // and its gap — and the only one that is not always there, so it
            // opens last and highest. The format readout goes next: a sample
            // rate and a channel count are what the source chip beside it
            // already implies, where the elapsed clock and the delivery target
            // are readings nothing else in the window carries.
            //
            // The seam the left group ends with is `Space.lg` above the format
            // gate and `Space.sm` below it — it is sized to whichever item the
            // group ends with — so both are counted where they belong.
            const withFormat =
                irreducible -
                Space.sm +
                Space.md +
                BarMetrics.format +
                Space.lg;
            const withTransport =
                withFormat + TransportReadout.defaultWidth + Space.md;

            final showFormat = width >= withFormat + BarMetrics.margin;
            final showTransport =
                transportOf != null &&
                width >= withTransport + BarMetrics.margin;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: Row(
                children: [
                  // **The left group is the slack.** It is `Expanded`, so it
                  // takes whatever the right group leaves and pushes that group
                  // flush right — the job a `Spacer` used to do here, and it
                  // cannot be one: the source picker shrinks, and a `Flexible`
                  // sharing a row with a `Spacer` splits the free space with it.
                  // See the note in `_MenuBar`'s row.
                  Expanded(
                    child: Row(
                      children: [
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
                        // **The seam between the two groups, and it is the left
                        // group that pays for it.** The group's children pack
                        // left, so the space after them is whatever the window
                        // is not using — which is zero from the moment the row
                        // is full. That used to leave the sample rate running
                        // flush into the playhead, and with a bordered source
                        // chip it is a hairline touching the elapsed clock's
                        // digits, which is the spacing mistake the eye does
                        // catch in a row whose borders are its only horizontal
                        // line.
                        //
                        // Inside the `Expanded` rather than after it, which is
                        // what makes it free: a fixed box out in the row itself
                        // would add to a sum that does not shrink and move both
                        // gates above it. Here the picker gives up 24 px of
                        // name it was going to ellipsise anyway.
                        //
                        // **Sized to what is on the other side of it, which is
                        // the item this group ends with.** Above the format gate
                        // that is a text readout and the seam is a boundary
                        // between two groups; below it the group ends in a
                        // bordered chip and the seam is the `Space.sm` every
                        // seam between controls is.
                        SizedBox(width: showFormat ? Space.lg : Space.sm),
                      ],
                    ),
                  ),
                  // **Left of the elapsed clock, because they are two clocks and
                  // only one of them is a measurement.** This is where the
                  // session is; the one beside it is how long this reading has
                  // been running. Reading order puts the host's time first — it
                  // is the one somebody says out loud to another person in the
                  // room — and the measurement's own clock next to the target it
                  // is being judged against.
                  if (showTransport) ...[
                    TransportReadout(
                      transportOf: transportOf!,
                      repaint: clock,
                      // Packed left, like the tablet's — and there is nothing
                      // left over to push anywhere, because the box is the width
                      // of the format the host is reporting rather than of the
                      // widest one there is. See the note at the top of
                      // `transport_readout.dart`.
                      align: TransportAlign.leading,
                    ),
                    const SizedBox(width: Space.md),
                  ],
                  ElapsedReadout(engine: source, clock: clock),
                  const SizedBox(width: Space.md),
                  // Bounded, not `Flexible`. A `Flexible` here shares the row's
                  // free space with the `Expanded` group above — both default to
                  // `flex: 1`, so `RenderFlex` hands each of them half, the loose
                  // one takes only the width of the name, and the leftover half
                  // is laid out *after* the last child. Everything from the
                  // elapsed clock rightwards then sits in the middle of the bar
                  // with a gap beside it that grows as the window does.
                  //
                  // A maximum with an ellipsis is what the source picker two
                  // rows up already does, and it is the honest constraint: the
                  // row drops whole items on a narrow window rather than
                  // squeezing them — see the `showFormat` gate.
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: BarMetrics.pickerCap,
                    ),
                    child: _CalibrationPicker(calibration: calibration),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Which preset is open, and whether it has been saved, centred in the top row.
///
/// Not a [BarChip], though it sits in a row of controls. The two chips are the
/// menus that hold a value — what is being metered, and what against — and they
/// wear a border because they can be clicked. This is a readout: it is the
/// window's title, in the row that is the window's title bar on macOS, and a
/// border round it would promise a menu that is not there. The menu is at the
/// other end of the row and says FILE, or on macOS it is in the system menu bar.
///
/// **The mark's slot is reserved on both sides of the name.** It is one
/// character, and a character on one side only of a *centred* readout moves the
/// name half its width every time the layout is edited — a title that shifts
/// when you drag a module. Reserved twice, the ink stays where it is and the
/// mark appears in room that was already being left for it. The old readout
/// reserved it once, on the left of the group beside it, because there it was a
/// leading item and everything to its right would have moved instead.
class _PresetTitle extends ConsumerWidget {
  const _PresetTitle();

  /// The mark's reservation. `•` in the label style plus the seam before it.
  static const double _markWidth = Space.sm + Space.xs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = OaaTheme.of(context);
    final name = ref.watch(workspaceProvider).preset.name;
    final modified = ref.watch(presetModifiedProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // The mark's mirror. Nothing is drawn in it ever; it is here so that
        // the name either side of it is the same distance from the window's
        // centre whether the document has been touched or not.
        const SizedBox(width: _markWidth),
        // `Flexible` inside a sized box, for the reason `BarChip` gives:
        // without it the text is measured against unbounded width and takes
        // it, where the room this title was given cannot see it.
        Flexible(
          child: Text(
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            textAlign: TextAlign.center,
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
