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

  /// The host's playhead, or [Transport.none] when it has none to give.
  ///
  /// Not part of [snapshot], and deliberately: transport is metadata about a DAW
  /// and the engine must not learn what one is — see `Transport`. It arrives in
  /// its own frame, on change rather than with every measurement, so a session
  /// parked at bar 57 sends one and then nothing.
  ///
  /// **A notifier rather than a field on the snapshot, and nothing on the paint
  /// path may listen to it.** While a DAW is rolling this changes at the publish
  /// rate, so a `ValueListenableBuilder` around a readout would rebuild a widget
  /// thirty times a second forever. Read it from a painter that repaints on the
  /// clock, the way `TransportReadout` does.
  final ValueNotifier<Transport> transport = ValueNotifier(Transport.none);

  /// Whether the host has a playhead at all — the one part of a transport that
  /// the widget tree is allowed to watch.
  ///
  /// The rule above still holds: nothing that *builds* may listen to
  /// [transport], which moves at the publish rate. This does not move with it.
  /// It is what the host has *said about itself* — false on a desktop metering a
  /// sound card, true from the frame a plugin's session appears in — so it flips
  /// once or twice in a session, and it changes a layout rather than a reading.
  /// The link bar gives the readout a slot only while this is true; reserving
  /// one unconditionally left `TransportReadout.fullWidth` of nothing between
  /// the host's name and the tab control on every host with no DAW, which reads
  /// as a control that failed to lay out rather than as an empty readout.
  /// `MeterClock.overrun` is the same shape, for the same reason.
  ///
  /// **It follows what the host stated, not what is currently on screen.** A
  /// link that has gone quiet clears [transport] — nothing there is current —
  /// and deliberately leaves this alone. Dropping the slot on a stale link and
  /// restoring it on recovery would move the tabs out from under the finger of
  /// somebody standing at a tablet on a flaky access point, which is worse than
  /// a blank slot on a bar that is already saying the picture is not current.
  final ValueNotifier<bool> hasTransport = ValueNotifier(false);

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
          case WireFrameType.dawTransport:
            // **Not liveness.** Only a measurement can say the link is
            // current: transport is sent on change, so a host parked at bar 1
            // sends none of it for as long as nobody touches the DAW, and a
            // stale timer that this reset would be a timer a quiet session
            // could hold open with a playhead that has not moved.
            final decoded = DawTransportCodec.decode(_reader.payload);
            transport.value = decoded;
            // The host closing its DAW is a *frame* — the plugin session ends,
            // the desktop's transport becomes `Transport.none`, and that change
            // goes out like any other. So the slot is taken away here as well
            // as given, and neither direction is a guess.
            hasTransport.value = decoded.isPresent;
          default:
          // An unknown type is skipped rather than fatal — that is what lets a
          // host that has learned to send something this build has never heard
          // of talk to it anyway.
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

    // The playhead goes with them. A position held on screen after the
    // measurements have gone to dashes is the same lie in a different unit, and
    // a worse one here: a parked transport legitimately sends nothing for
    // minutes, so a stopped clock and a lost link look identical.
    //
    // The reading goes; the slot it was drawn in stays. This is a timeout, not
    // a statement by the host that its DAW has gone — see [hasTransport], and
    // do not clear it here.
    transport.value = Transport.none;
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

    // With the measurements, and for the same reason the reader is reset below:
    // this outlives the socket. A display that reattached to a different
    // machine — or to the same one after its DAW was closed — opened on the
    // previous session's playhead, which is transport sent on change never
    // arriving to contradict it.
    //
    // Both halves here, unlike the stale path above: the link is over, so
    // nothing has said anything about a playhead and the next host has to say
    // it again. A latch carried across a reattach is a slot reserved on a
    // machine that never mentioned a DAW.
    transport.value = Transport.none;
    hasTransport.value = false;

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
    transport.dispose();
    hasTransport.dispose();
    hostName.dispose();
    failure.dispose();
  }
}
