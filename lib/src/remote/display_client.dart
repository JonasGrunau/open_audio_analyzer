// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
import 'package:flutter/foundation.dart';

/// Where the link stands. Everything the display's chrome says comes from here.
enum RemoteLinkState {
  /// Nothing attempted yet.
  idle,

  connecting,

  /// Attached and receiving measurements.
  live,

  /// Attached, but nothing has arrived for [DisplayClient.staleAfter].
  ///
  /// Distinct from [failed] because the socket is still open and frames may
  /// resume at any moment — but the meters must stop claiming to be current in
  /// the meantime.
  stale,

  /// The connection dropped or was refused. A retry is scheduled.
  failed,
}

/// Reads another machine's measurements off a socket.
///
/// The counterpart to `DisplayHost`, and the reason `MeterSource` exists: what
/// comes out of here is fed to the same thirteen modules the desktop uses, with
/// the same painters, so the two screens cannot drift into disagreeing about
/// what the signal did.
///
/// Nothing here is on the paint path. Frames arrive on socket events and are
/// decoded into [snapshot], whose arrays are allocated once; the display's
/// single `MeterClock` then reads them at its own rate. Two frames arriving
/// between two ticks cost one repaint, not two, which is the same arithmetic
/// that makes the desktop cheap.
class DisplayClient {
  DisplayClient({this.staleAfter = const Duration(seconds: 2)});

  /// How long without a measurement before the meters stop claiming to be
  /// current.
  ///
  /// Two seconds is about sixty missed frames at the default rate — long enough
  /// that a Wi-Fi hiccup does not blank a working display, short enough that
  /// nobody reads a delivery decision off a picture of the past.
  final Duration staleAfter;

  /// What the modules read. Its arrays never change identity, so a painter may
  /// hold one across frames.
  final WireSnapshot snapshot = WireSnapshot();

  final ValueNotifier<RemoteLinkState> state = ValueNotifier(
    RemoteLinkState.idle,
  );

  /// The layout to draw, as the host has it. Null until the host sends one.
  final ValueNotifier<PresetSpec?> layout = ValueNotifier(null);

  /// The host's active skin, or null for the built-in one.
  final ValueNotifier<Skin?> skin = ValueNotifier(null);

  /// The host's active delivery target.
  ///
  /// Starts at the fallback so that a display which has not been told one yet
  /// still classifies readings against *something* stated, rather than against
  /// whatever this machine happened to have selected last.
  final ValueNotifier<Calibration> calibration = ValueNotifier(
    BuiltInCalibrations.fallback,
  );

  /// What the host calls itself, and its engine's ABI — both for display, not
  /// for decisions.
  final ValueNotifier<String?> hostName = ValueNotifier(null);
  int? hostAbiVersion;

  /// Why the last attempt failed, in a sentence meant for a person.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _staleTimer;
  Timer? _retryTimer;

  final FrameReader _reader = FrameReader();

  DateTime? _lastFrameAt;
  String? _host;
  int? _port;
  int _attempt = 0;
  bool _wantConnection = false;

  /// Attaches to a host, and keeps trying until [disconnect].
  ///
  /// Reconnection is not a nicety here. A display in a live room is on the far
  /// side of an access point that will drop it, and somebody who has walked
  /// away from the desk cannot be the mechanism that brings the picture back.
  Future<void> connect(String host, int port) async {
    _host = host;
    _port = port;
    _wantConnection = true;
    _attempt = 0;
    await _open();
  }

  Future<void> disconnect() async {
    _wantConnection = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _teardown();
    state.value = RemoteLinkState.idle;
    layout.value = null;
    skin.value = null;
    hostName.value = null;
    failure.value = null;
  }

  Future<void> _open() async {
    final host = _host;
    final port = _port;
    if (host == null || port == null || !_wantConnection) return;

    // Said before the first `await`, never after it. [connect] is called from
    // a screen's `initState`, and a suspension there lands after that screen's
    // first build — so a display handed a host built one frame of the host
    // picker, which is what it shows while the link is idle. That frame is not
    // only a panel flashing on the way in: the picker starts a search in its
    // own `initState`, so entering a display opened a second browse and tore it
    // down again a frame later.
    state.value = RemoteLinkState.connecting;
    await _teardown();

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      if (!_wantConnection) {
        socket.destroy();
        return;
      }

      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _lastFrameAt = DateTime.now();
      failure.value = null;
      state.value = RemoteLinkState.live;

      _subscription = socket.listen(
        _receive,
        onError: (Object error) => _lost(error.toString()),
        onDone: () => _lost('The host closed the connection.'),
        cancelOnError: true,
      );

      _staleTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _checkStale(),
      );
    } on Object catch (error) {
      _lost(_describe(error));
    }
  }

  void _receive(Uint8List chunk) {
    _reader.add(chunk);

    try {
      while (_reader.moveNext()) {
        switch (_reader.type) {
          case WireFrameType.hello:
            _handleHello(WireHello.decode(_reader.payload));
          case WireFrameType.layout:
            layout.value = PresetSpec.fromJson(_json(_reader.payload));
          case WireFrameType.skin:
            skin.value = _reader.payload.lengthInBytes == 0
                ? null
                : Skin.fromJson(_json(_reader.payload));
          case WireFrameType.calibration:
            calibration.value = Calibration.fromJson(_json(_reader.payload));
          case WireFrameType.snapshot:
            snapshot.decode(_reader.payload);
            _lastFrameAt = DateTime.now();
            if (state.value != RemoteLinkState.live) {
              state.value = RemoteLinkState.live;
            }
          default:
          // An unknown type is skipped rather than fatal — that is what lets a
          // host that has learned to send DAW transport talk to this build.
        }
      }
    } on Object catch (error) {
      // A stream that has lost sync stays lost, so there is nothing to do with
      // it but drop it and start again.
      _lost(_describe(error));
    }
  }

  void _handleHello(WireHello hello) {
    hostName.value = hello.producerName;
    hostAbiVersion = hello.abiVersion;

    final refusal = hello.incompatibility;
    if (refusal != null) {
      // Refusing is the honest outcome and it has to *say* what it refused.
      // Drawing this host's frames anyway would not crash — it would put a
      // detailed, wrong picture on screen, which somebody would then trust.
      _wantConnection = false;
      unawaited(_teardown());
      failure.value = refusal;
      state.value = RemoteLinkState.failed;
    }
  }

  Map<String, Object?> _json(ByteData payload) =>
      (jsonDecode(
                utf8.decode(
                  Uint8List.view(
                    payload.buffer,
                    payload.offsetInBytes,
                    payload.lengthInBytes,
                  ),
                ),
              )
              as Map)
          .cast<String, Object?>();

  void _checkStale() {
    final last = _lastFrameAt;
    if (last == null) return;
    if (DateTime.now().difference(last) < staleAfter) return;

    // The socket is still open, so this is not a failure — but nothing on
    // screen can be claimed to be current, and a frozen meter reads exactly
    // like a quiet passage.
    snapshot.markStale();
    if (state.value == RemoteLinkState.live) {
      state.value = RemoteLinkState.stale;
    }
  }

  void _lost(String reason) {
    unawaited(_teardown());
    if (!_wantConnection) return;

    failure.value = reason;
    state.value = RemoteLinkState.failed;

    // Backoff, capped: a display left switched on overnight next to a host that
    // is off should not spend the night opening sockets.
    final seconds = [1, 2, 4, 8][_attempt.clamp(0, 3)];
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () => unawaited(_open()));
  }

  Future<void> _teardown() async {
    _staleTimer?.cancel();
    _staleTimer = null;
    snapshot.markStale();

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    _socket?.destroy();
    _socket = null;
    _lastFrameAt = null;

    // Every path that ends a connection comes through here, which is the only
    // place this can go: the reader outlives the socket, and a link that
    // dropped mid-frame left the head of that frame in it. See
    // [FrameReader.reset] for what reading on would have drawn instead.
    //
    // **After the cancel, not before it.** A chunk already scheduled for
    // delivery lands during the suspension above, and a reset in front of that
    // would be undone by the last bytes of the connection it was there to
    // forget.
    _reader.reset();
  }

  static String _describe(Object error) => switch (error) {
    SocketException(:final message, :final osError) =>
      osError == null ? message : '$message (${osError.message})',
    WireFormatException(:final message) => message,
    _ => error.toString(),
  };

  void dispose() {
    _wantConnection = false;
    _retryTimer?.cancel();
    unawaited(_teardown());
    state.dispose();
    layout.dispose();
    skin.dispose();
    calibration.dispose();
    hostName.dispose();
    failure.dispose();
  }
}
