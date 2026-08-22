// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';

import 'display_host.dart';
import 'mdns/mdns_service.dart';

/// Publishing this machine's meters, as one switch.
///
/// The socket and the advertisement are owned together because they are only
/// ever correct together. A host that listens without advertising is invisible
/// to every tablet in the building; one that advertises without listening is
/// worse — it puts a row in somebody's list that fails when they tap it, and
/// the failure looks like a bug in the display rather than a host that is not
/// running.
///
/// **Off until a human turns it on**, and it stays off across a device change
/// or a preset load. Everything on this port is readable by anyone who can
/// reach it, and that is a decision to offer, not one to make on the user's
/// behalf while they are not looking.
class RemoteDisplayService {
  RemoteDisplayService(this._source, {required this.abiVersion});

  /// What is being measured here. Read-only: nothing a display does can reach
  /// back through this.
  ///
  /// Set it when the engine is replaced, and set it to null when there is no
  /// engine at all. Neither is optional: an engine is destroyed and rebuilt
  /// whenever the user changes source or device, and a service still pointing at
  /// the previous one publishes freed memory to every attached display. Owned by
  /// whatever owns the engine, for the same reason.
  MeterSource? get source => _source;
  MeterSource? _source;

  set source(MeterSource? value) {
    if (identical(value, _source)) return;
    _source = value;
    _host?.source = value;
  }

  /// The DAW's playhead behind [source], or [Transport.none] when there is
  /// none.
  ///
  /// Set on every producer frame rather than sampled — see
  /// [DisplayHost.transport], which explains why the difference is the whole
  /// point. Held here as well so that a host started *after* a plugin connected
  /// opens with the position the session is at rather than with nothing.
  Transport get transport => _transport;
  Transport _transport = Transport.none;

  set transport(Transport value) {
    _transport = value;
    _host?.transport = value;
  }

  /// `OAA_ABI_VERSION` of the engine, carried in the handshake for bug reports.
  final int abiVersion;

  /// The name tablets see in their list.
  ///
  /// `AppSettings.remoteDisplayName` is null until somebody chooses one, and
  /// null is an instruction rather than a missing value: use this machine's
  /// name. It is resolved here because resolving it needs `dart:io`, which
  /// `oaa_core` does not have and must not acquire.
  String get hostName => _name ?? defaultHostName();
  String? _name;

  int get port => _port;
  int _port = DisplayHost.defaultPort;

  int get fps => _fps;
  int _fps = 30;

  /// Adopts a configuration, restarting only if it has to.
  ///
  /// Safe to call on every rebuild. A changed rate is applied to the running
  /// host in place — it only re-arms a timer — while a changed name or port
  /// means a different socket and a different advertisement, so those restart.
  /// Restarting for a rate change would drop every attached display for no
  /// reason.
  void configure({String? name, required int port, required int fps}) {
    final rebind = name != _name || port != _port;
    if (!rebind && fps == _fps) return;

    _name = name;
    _port = port;
    _fps = fps;

    if (_host == null) return;
    if (rebind) {
      unawaited(reconfigure());
    } else {
      _host!.fps = fps;
    }
  }

  DisplayHost? _host;
  MdnsResponder? _responder;
  Timer? _formatWatch;

  /// Whether the port is open. Distinct from "a display is attached".
  final ValueNotifier<bool> isPublishing = ValueNotifier(false);

  /// How many displays are attached.
  final ValueNotifier<int> clients = ValueNotifier(0);

  /// Why publishing could not start, in a sentence for a person.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  /// Why no display will find this machine, even though it is publishing.
  ///
  /// **Separate from [failure], because the two are independently true and the
  /// difference is the whole of what a person can act on.** Publishing is a
  /// socket on this machine; announcing is a packet leaving it. A refused
  /// local-network permission stops the second and not the first, so the port
  /// stays open, a display handed the address connects and works, and the only
  /// screen that knows anything is wrong is the tablet — which is the one
  /// screen with nothing on it to read.
  ///
  /// [failure] used to claim it covered this case and never once carried it:
  /// `MdnsResponder` threw its bind error, its send error and its socket's
  /// error stream away, so there was nothing to carry. Folding the two into one
  /// notifier now would be the other half of the same mistake — it would have
  /// to say publishing had failed when it plainly had not.
  final ValueNotifier<String?> advertisementFailure = ValueNotifier(null);

  PresetSpec? _layout;
  Skin? _skin;
  Calibration? _calibration;

  Future<void> setEnabled(bool enabled) => enabled ? _start() : _stop();

  Future<void> _start() async {
    if (_host != null) return;
    if (_source == null) {
      // Nothing is being measured, so there is nothing to advertise. This is
      // the state after an engine failed to open, and a host that listened
      // anyway would put a row in somebody's list that shows em dashes.
      failure.value = 'There is nothing to publish: no engine is running.';
      isPublishing.value = false;
      return;
    }

    final host =
        DisplayHost(source: _source, hostName: hostName, abiVersion: abiVersion)
          ..fps = _fps
          ..transport = _transport;

    try {
      await host.start(port: _port);
    } on Object catch (error) {
      failure.value = _describe(error);
      isPublishing.value = false;
      return;
    }

    _host = host;
    host.clientCount.addListener(_onClients);
    _onClients();
    failure.value = null;
    isPublishing.value = true;

    // Replay whatever the app has already told us, so that turning the service
    // on mid-session does not produce a display with measurements and no layout
    // to draw them in.
    final layout = _layout;
    if (layout != null) host.publishLayout(layout);
    host.publishSkin(_skin);
    final calibration = _calibration;
    if (calibration != null) host.publishCalibration(calibration);

    final responder = MdnsResponder(
      instanceName: hostName,
      port: host.port ?? _port,
    )..txt = _txt();
    _responder = responder;
    // Attached before the bind, which is where the first of the three failures
    // is raised, and read once afterwards for the case where nothing changed.
    responder.failure.addListener(_onAdvertisement);
    await responder.start();
    _onAdvertisement();

    // The advertised format is the one thing in the TXT record that changes
    // while running — an interface switched from 44.1 to 96 kHz, a device that
    // had not reported its channel count yet. Cheap to check, and the
    // alternative is a discovery list describing a signal nobody is measuring.
    _formatWatch = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _responder?.txt = _txt(),
    );
  }

  Future<void> _stop() async {
    _formatWatch?.cancel();
    _formatWatch = null;

    final responder = _responder;
    _responder = null;
    final host = _host;
    _host = null;

    // **Every state a widget builds from is published here, before the first
    // suspension, and every listener is dropped here too** — so nothing can put
    // one of these values back while the sockets are still closing, and nothing
    // writes to a notifier that has been disposed in the meantime. Closing
    // either half suspends, [dispose] does not wait for it, and these notifiers
    // are one statement further down that method: a write after the gap throws
    // from inside a microtask, where the only thing it reaches is the console.
    //
    // It stayed invisible for as long as it did because a write of the value a
    // notifier already holds does not notify, so nothing asserted unless the
    // service had actually been publishing — which is never true of a test that
    // does not open a socket. Clearing the advertisement here is also the
    // honest order: `stop` sends a goodbye, and a goodbye the OS refuses would
    // otherwise raise a notice about a service that is already gone.
    responder?.failure.removeListener(_onAdvertisement);
    host?.clientCount.removeListener(_onClients);
    // Before the value is cleared, or a timer that fires after this puts a
    // notice back for a service that has already stopped.
    _settling?.cancel();
    _settling = null;
    advertisementFailure.value = null;
    isPublishing.value = false;
    clients.value = 0;

    await responder?.stop();
    responder?.dispose();
    await host?.stop();
  }

  /// Restarts the service so a changed port, name or rate takes effect.
  Future<void> reconfigure() async {
    if (_host == null) return;
    await _stop();
    await _start();
  }

  /// Tells attached displays what to draw and how to colour it.
  ///
  /// Safe to call on every rebuild: each of these is compared before it is sent,
  /// so a rebuild that changed nothing costs nothing on the wire.
  void publish({
    required PresetSpec layout,
    required Skin skin,
    required Calibration calibration,
  }) {
    final host = _host;

    if (_layout != layout) {
      _layout = layout;
      host?.publishLayout(layout);
    }
    if (_skin != skin) {
      _skin = skin;
      host?.publishSkin(skin);
    }
    if (_calibration != calibration) {
      _calibration = calibration;
      host?.publishCalibration(calibration);
    }
  }

  Map<String, String> _txt() {
    final source = _source;
    return {
      'v': '1',
      'name': hostName,
      if (source != null && source.sampleRate > 0) 'sr': '${source.sampleRate}',
      if (source != null && source.channels > 0) 'ch': '${source.channels}',
    };
  }

  void _onClients() => clients.value = _host?.clientCount.value ?? 0;

  /// Held back until it has stopped flapping.
  ///
  /// **The first announcement of a session very often fails, and then works.**
  /// The responder sends as soon as the socket is bound, and on macOS a send
  /// issued before the multicast join has settled is refused with the same
  /// `EHOSTUNREACH` a denied local-network permission produces — so
  /// `MdnsResponder.failure` goes non-null a few milliseconds after publishing
  /// starts and null again on the next announcement a second later. That is the
  /// correct behaviour for the responder, which reports what the OS just told
  /// it; it is the wrong thing to put on screen, and it showed as a warning
  /// banner that appeared and vanished every time somebody flipped the switch —
  /// which teaches people to ignore the one notice that means a tablet will
  /// never find this machine.
  ///
  /// So a *failure* has to survive the responder's opening burst — three
  /// announcements at one-second intervals — before it is published, while a
  /// *clear* is passed through at once. Nothing is lost by waiting: the fault
  /// this carries is "no display will list this machine", which is not urgent
  /// and cannot be acted on faster than it takes to read the sentence.
  Timer? _settling;

  void _onAdvertisement() {
    final reported = _responder?.failure.value;

    if (reported == null) {
      _settling?.cancel();
      _settling = null;
      advertisementFailure.value = null;
      return;
    }

    // Already saying something: keep it current, since the sentence itself can
    // change while the fault stays true.
    if (advertisementFailure.value != null) {
      advertisementFailure.value = reported;
      return;
    }

    _settling ??= Timer(_announcementBurst, () {
      _settling = null;
      final settled = _responder?.failure.value;
      if (settled != null) advertisementFailure.value = settled;
    });
  }

  /// How long `MdnsResponder` spends on its opening announcements.
  static const Duration _announcementBurst = Duration(seconds: 3);

  /// This machine's name, for when the user has not chosen one.
  ///
  /// The **first label** of it, not the whole thing. macOS hands back
  /// `studio-mac.local` on a plain network and `studio-mac.fritz.box` on any
  /// network whose DHCP server hands out a domain, and a router that does
  /// that is the normal case rather than the exotic one. Stripping `.local`
  /// alone left the second kind intact, which put a name with dots in it where
  /// DNS-SD allows exactly one label — see `MdnsResponder.instanceLabel` for
  /// what that did to discovery. The domain is also noise in a list where
  /// everything is on the local network by definition.
  static String defaultHostName() {
    try {
      final name = Platform.localHostname.trim().split('.').first;
      return name.isEmpty ? 'Open Audio Analyzer' : name;
    } on Object {
      return 'Open Audio Analyzer';
    }
  }

  static String _describe(Object error) => switch (error) {
    SocketException(:final message, :final osError) =>
      osError == null ? message : '$message (${osError.message})',
    _ => error.toString(),
  };

  void dispose() {
    unawaited(_stop());
    isPublishing.dispose();
    clients.dispose();
    failure.dispose();
    advertisementFailure.dispose();
  }
}
