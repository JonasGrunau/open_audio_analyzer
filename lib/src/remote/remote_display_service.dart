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
  RemoteDisplayService({required this.source, required this.abiVersion});

  /// What is being measured here. Read-only: nothing a display does can reach
  /// back through this.
  final MeterSource source;

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
  ///
  /// The one that matters in practice is a refused local-network permission on
  /// macOS and iPadOS, which otherwise presents as a host nobody can find and
  /// no indication why.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  PresetSpec? _layout;
  Skin? _skin;
  Calibration? _calibration;

  Future<void> setEnabled(bool enabled) => enabled ? _start() : _stop();

  Future<void> _start() async {
    if (_host != null) return;

    final host = DisplayHost(
      source: source,
      hostName: hostName,
      abiVersion: abiVersion,
    )..fps = _fps;

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

    _responder = MdnsResponder(instanceName: hostName, port: host.port ?? _port)
      ..txt = _txt();
    await _responder!.start();

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
    await responder?.stop();

    final host = _host;
    _host = null;
    host?.clientCount.removeListener(_onClients);
    await host?.stop();

    isPublishing.value = false;
    clients.value = 0;
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

  Map<String, String> _txt() => {
    'v': '1',
    'name': hostName,
    if (source.sampleRate > 0) 'sr': '${source.sampleRate}',
    if (source.channels > 0) 'ch': '${source.channels}',
  };

  void _onClients() => clients.value = _host?.clientCount.value ?? 0;

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
  }
}
