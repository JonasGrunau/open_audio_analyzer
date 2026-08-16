// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bel_core/bel_core.dart';
import 'package:bel_wire/bel_wire.dart';
import 'package:flutter/foundation.dart';

/// Publishes what this machine is measuring, so another screen can draw it.
///
/// The protocol is in `docs/WIRE.md`. Three decisions in here are worth the
/// paragraphs, because each of them is a way a remote meter lies if you get it
/// wrong.
///
/// **It refreshes the source itself rather than riding the [MeterClock].** The
/// clock is a `Ticker`, and a `Ticker` stops when the window is occluded or the
/// app is hidden — which is precisely when somebody is looking at the tablet
/// instead. A remote display fed from the clock would freeze the moment it
/// became the only screen in use, and freeze *convincingly*, still showing a
/// detailed picture of a signal it had stopped reading. So this owns a
/// [Timer.periodic] and does its own acquire. That is safe alongside the clock
/// only because both ask the source what generation it holds rather than
/// trusting a one-shot "is it new" answer — see `MeterClock`.
///
/// **A client that has fallen behind loses frames instead of accumulating
/// them.** If a socket has not flushed the last frame when the next one is due,
/// that client is skipped. Queueing would keep the display busy drawing what
/// the signal did half a second ago, and unlike a dropped frame, nothing about
/// it looks wrong.
///
/// **It does not listen until a human turns it on.** There is no authentication
/// on this port and everything it publishes is readable by anyone who can reach
/// it. That is an acceptable trade for a LAN display and an unacceptable one to
/// make on the user's behalf while they are not looking.
class DisplayHost {
  DisplayHost({
    required this.source,
    required this.hostName,
    required this.abiVersion,
  });

  /// What is being measured. Read-only from here — a remote display never
  /// starts, stops or resets anything.
  final MeterSource source;

  /// What the tablet shows in its list. A name, never an address.
  final String hostName;

  /// `BEL_ABI_VERSION` of the engine behind [source], carried in the handshake
  /// for the benefit of bug reports. It is not a compatibility check; the
  /// snapshot payload size is.
  final int abiVersion;

  /// The default port. Registered to nothing — picked in the dynamic range so
  /// it collides with no service anyone else runs, and configurable because
  /// somebody will need it to be.
  static const int defaultPort = 47821;

  /// How often measurements go out is `kRemoteFpsOptions` from `bel_core`, and
  /// it is a property of the link rather than of either screen's refresh rate:
  /// the host may be drawing at 120 fps and the tablet at 60, and neither is a
  /// reason to put more than 30 measurements a second on a Wi-Fi network.

  /// Frames held for reuse.
  ///
  /// `Socket.add` keeps the list it is given rather than copying it, so a
  /// buffer cannot be overwritten until its write has flushed. Four at the
  /// default rate is 133 ms of slack, which no healthy LAN write comes close
  /// to; the ring exists so that an unhealthy one costs a dropped frame rather
  /// than half of one measurement spliced onto half of another.
  static const int _ringSize = 4;

  ServerSocket? _server;
  Timer? _timer;

  final List<_RemoteClient> _clients = [];
  final List<_FrameSlot> _ring = List.generate(
    _ringSize,
    (_) => _FrameSlot(SnapshotFrame()),
  );

  /// The most recent layout and skin, replayed to every client that connects
  /// after they were set. Without this a tablet that joins mid-session gets
  /// measurements and nothing to draw them in.
  PresetSpec? _layout;
  Skin? _skin;
  Calibration? _calibration;

  /// How many displays are attached, for the UI to show.
  final ValueNotifier<int> clientCount = ValueNotifier<int>(0);

  /// The port actually bound, or null while stopped. Not always [defaultPort]:
  /// a caller may pass 0 and let the OS choose.
  int? get port => _server?.port;

  bool get isListening => _server != null;

  int get fps => _fps;
  int _fps = 30;

  set fps(int value) {
    if (value == _fps || !kRemoteFpsOptions.contains(value)) return;
    _fps = value;
    if (_server != null) _restartTimer();
  }

  /// Binds and starts publishing.
  ///
  /// Throws [SocketException] if the port is taken or the platform refuses the
  /// bind — on recent macOS and iOS that includes the local-network permission
  /// prompt being declined, which is a thing the UI has to be able to say out
  /// loud rather than showing an empty client list forever.
  Future<void> start({int port = defaultPort}) async {
    if (_server != null) return;

    // Any interface: the tablet is on the same LAN but not necessarily the same
    // subnet the host would guess.
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_accept, onError: (Object _) {}, cancelOnError: false);
    _restartTimer();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;

    // The displays go before anything is awaited. `server.close()` suspends,
    // and every turn between here and the resumption is one in which a frame
    // can still be written to a socket that is on its way out.
    for (final client in List<_RemoteClient>.of(_clients)) {
      client.close();
    }
    _clients.clear();
    clientCount.value = 0;

    final server = _server;
    _server = null;
    await server?.close();
  }

  /// One publish, now, rather than on the next tick.
  ///
  /// The suite needs a frame that is *still in flight* — the state in which a
  /// socket's sink is bound and refuses `add` and `close` alike — and it
  /// cannot wait for a timer to hand it one.
  @visibleForTesting
  void publishNow() => _publish();

  /// Publishes a new layout to every attached display, and to every display
  /// that attaches later.
  void publishLayout(PresetSpec layout) {
    _layout = layout;
    final frame = _layoutFrame(layout);
    for (final client in _clients) {
      client.sendOnce(frame);
    }
  }

  /// Publishes the resolved skin, or null for the built-in one.
  ///
  /// The resolved token set rather than [PresetSpec.skinId], because a
  /// user-authored skin is a file on this machine's disk that the tablet has
  /// never seen. Sending the id and hoping is how two screens end up rendering
  /// the same session in different colours.
  void publishSkin(Skin? skin) {
    _skin = skin;
    final frame = _skinFrame(skin);
    for (final client in _clients) {
      client.sendOnce(frame);
    }
  }

  /// Publishes the active delivery target.
  ///
  /// Resolved, not named, and it matters more than the skin: the target decides
  /// whether a reading is drawn in spec, warning or over. Two screens holding
  /// different targets colour the same measurement differently, and one of them
  /// is going to be the one somebody believes.
  void publishCalibration(Calibration calibration) {
    _calibration = calibration;
    final frame = _calibrationFrame(calibration);
    for (final client in _clients) {
      client.sendOnce(frame);
    }
  }

  void _accept(Socket socket) {
    // Nagle batches small writes, which is the opposite of what a 15 kB frame
    // that must land now wants.
    socket.setOption(SocketOption.tcpNoDelay, true);

    final client = _RemoteClient(socket, _remove);
    _clients.add(client);
    clientCount.value = _clients.length;

    client.sendOnce(
      WireHello.local(
        abiVersion: abiVersion,
        producerName: hostName,
      ).encodeFrame(),
    );
    // Everything a display needs before a measurement means anything, replayed
    // for a tablet that joined mid-session. Without it a client that connects
    // after the layout was set gets numbers and nowhere to draw them.
    final layout = _layout;
    if (layout != null) client.sendOnce(_layoutFrame(layout));
    client.sendOnce(_skinFrame(_skin));
    final calibration = _calibration;
    if (calibration != null) {
      client.sendOnce(_calibrationFrame(calibration));
    }
  }

  void _remove(_RemoteClient client) {
    if (_clients.remove(client)) {
      clientCount.value = _clients.length;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(microseconds: (1000000 / _fps).round()),
      (_) => _publish(),
    );
  }

  void _publish() {
    if (_clients.isEmpty) return;

    // Our own acquire, for the reason in the class comment.
    source.refresh();

    final slot = _freeSlot();
    if (slot == null) {
      // Every buffer is still in flight, which means every client is slower
      // than the publish rate. Dropping this measurement is the whole design.
      return;
    }

    slot.frame.encode(source);
    for (final client in _clients) {
      client.sendPooled(slot);
    }
  }

  _FrameSlot? _freeSlot() {
    for (final slot in _ring) {
      if (slot.inFlight == 0) return slot;
    }
    return null;
  }

  Uint8List _layoutFrame(PresetSpec layout) => WireFrame.encode(
    WireFrameType.layout,
    utf8.encode(jsonEncode(layout.toJson())),
  );

  Uint8List _calibrationFrame(Calibration calibration) => WireFrame.encode(
    WireFrameType.calibration,
    utf8.encode(jsonEncode(calibration.toJson())),
  );

  Uint8List _skinFrame(Skin? skin) => WireFrame.encode(
    WireFrameType.skin,
    skin == null ? Uint8List(0) : utf8.encode(jsonEncode(skin.toJson())),
  );

  void dispose() {
    unawaited(stop());
    clientCount.dispose();
  }
}

/// One reusable snapshot frame and the number of writes still referencing it.
class _FrameSlot {
  _FrameSlot(this.frame);
  final SnapshotFrame frame;
  int inFlight = 0;
}

class _RemoteClient {
  _RemoteClient(this._socket, this._onGone) {
    _socket.listen(
      // A display-only protocol has nothing to say back in version 1. Anything
      // arriving here is a scanner or a confused client; ignoring it is
      // cheaper than parsing it and there is nothing it could ask for.
      (_) {},
      onError: (Object _) => close(),
      onDone: close,
      cancelOnError: true,
    );
    unawaited(
      _socket.done.then((_) => close(), onError: (Object _) => close()),
    );
  }

  final Socket _socket;
  final void Function(_RemoteClient) _onGone;

  bool _closed = false;

  /// The slot this client is still flushing, if any. Non-null means "behind" —
  /// the next frame is skipped rather than queued behind this one.
  _FrameSlot? _inFlight;

  /// One-off frames that arrived while a pooled one was still flushing.
  ///
  /// **A socket with a `flush` outstanding is a *bound* sink, and a bound sink
  /// refuses `add`, `flush` and `close` alike** — `IOSink.flush` sets the same
  /// flag `addStream` does, for as long as it takes. So a layout, a skin or a
  /// delivery target published between a snapshot frame and its flush threw
  /// `StateError("StreamSink is bound to a stream")` out of `add`, which this
  /// class caught the only way it could and closed the connection: changing
  /// the skin at the desk dropped the tablet, more often the slower the tablet
  /// was. These frames are rare, small and must not be dropped, so they wait
  /// for the flush instead.
  final List<Uint8List> _waiting = [];

  /// Sends a one-off frame that owns its own bytes: hello, layout, skin.
  ///
  /// These are rare, small and must not be dropped, so they queue normally.
  void sendOnce(Uint8List bytes) {
    if (_closed) return;
    if (_inFlight != null) {
      _waiting.add(bytes);
      return;
    }
    try {
      _socket.add(bytes);
    } on Object {
      close();
    }
  }

  /// Sends a frame from the shared ring, or skips it if this client has not
  /// finished with the last one.
  void sendPooled(_FrameSlot slot) {
    if (_closed || _inFlight != null) return;

    _inFlight = slot;
    slot.inFlight++;
    try {
      _socket.add(slot.frame.bytes);
    } on Object {
      _release();
      close();
      return;
    }

    unawaited(
      _socket.flush().then(
        (_) {
          _release();
          _drain();
        },
        onError: (Object _) {
          _release();
          close();
        },
      ),
    );
  }

  /// Writes whatever was published while the sink was bound. The socket is
  /// free from the moment the flush completes, and the next pooled frame is a
  /// timer tick away, so these keep their order and their place ahead of it.
  void _drain() {
    if (_closed || _waiting.isEmpty) return;
    final pending = List<Uint8List>.of(_waiting);
    _waiting.clear();
    try {
      for (final bytes in pending) {
        _socket.add(bytes);
      }
    } on Object {
      close();
    }
  }

  void _release() {
    final slot = _inFlight;
    if (slot == null) return;
    _inFlight = null;
    slot.inFlight--;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    _waiting.clear();
    _onGone(this);
    // **`destroy`, and not `close` before it.** `Socket.close` throws
    // `StateError("StreamSink is bound to a stream")` while a `flush` is
    // outstanding, *synchronously* — before it returns the future the
    // `catchError` here was attached to. This is called from the socket's own
    // `onDone`, which is precisely when a flush is most likely to be in
    // flight: the display went away mid-frame. So the throw came out of a
    // stream callback in the root zone, where nothing catches it, it was an
    // unhandled exception in the *host* every time a tablet left at the wrong
    // moment, and the `destroy` under it never ran — leaving the socket it was
    // there to give back. `destroy` can always be called, and the graceful
    // close bought nothing anyway with a `destroy` on the next line.
    _socket.destroy();
  }
}
