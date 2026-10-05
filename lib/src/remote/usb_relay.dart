// SPDX-License-Identifier: GPL-3.0-or-later

/// A display on a USB cable with no developer mode at either end.
///
/// `adb reverse` — see `usb_link.dart` — needs USB debugging on the tablet,
/// which is a developer's setting and not everybody's. The two routes that need
/// nothing switched on are each a single byte stream: an Android *accessory*,
/// which the desktop puts the tablet into over libusb (`packages/oaa_usb`), and
/// an iPad's `usbmuxd` tunnel, which the desktop dials (`usbmux.dart`). Neither
/// is a socket a display can connect to, and a display connects more than once
/// — it knocks to find a host, hangs up, and connects again to attach.
///
/// **So the tablet runs a relay, and the display does not know.** [TabletRelay]
/// listens on two loopback ports: [kUsbPipePort], where the cable arrives — the
/// desktop's `usbmuxd` tunnel on an iPad, `OaaAccessory.kt`'s pump on Android —
/// and [kUsbRelayPort], where a display connects exactly as it connects to the
/// far end of an `adb reverse`. Each connection to the second becomes a channel
/// of the first, in `docs/WIRE.md` § USB carriage. At the desktop,
/// [UsbRelayHost] hands every channel to the [DisplayHost] as if its own
/// listening socket had accepted it, so `HELLO`, the layout, the snapshots and
/// the acknowledgements are the display port's, byte for byte.
///
/// The relay port is bound only while a cable is attached. A knock on it then
/// fails at once, as a knock on an unforwarded port does, and the picker shows
/// no row for a cable that is not there.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:oaa_wire/oaa_wire.dart';

import 'display_host.dart';

/// Where the cable arrives on the tablet. Loopback only.
const int kUsbPipePort = 47823;

/// Where a display finds the host at the far end of the cable. Loopback only.
const int kUsbRelayPort = 47824;

/// One byte stream to the other end of a cable.
abstract interface class UsbPipe {
  /// Single subscription, like a socket's.
  Stream<Uint8List> get input;

  void add(List<int> bytes);

  /// Completes when what was added has left this process. One at a time.
  Future<void> flush();

  void destroy();
}

/// A socket as a pipe — the iPad's tunnel at both ends, and the accessory's
/// pump on Android. [input] may be given separately when something already
/// read the socket's first bytes, as `usbmuxd`'s reply is read before the
/// tunnel begins.
class SocketPipe implements UsbPipe {
  SocketPipe(this._socket, {Stream<Uint8List>? input})
    : input = input ?? _socket;

  final Socket _socket;

  @override
  final Stream<Uint8List> input;

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> flush() => _socket.flush();

  @override
  void destroy() => _socket.destroy();
}

/// Writes to a pipe from many channels, with one flush outstanding at a time.
///
/// **A sink with a flush outstanding refuses `add`** — see `_RemoteClient` in
/// `display_host.dart`, which learnt it the hard way — and here several
/// channels share one sink. So a write during a flush waits in [_queued], and a
/// flush asked for during one is answered by the next, which covers it.
class _Outbox {
  _Outbox(this._pipe);

  final UsbPipe _pipe;
  final List<List<int>> _queued = [];
  List<Completer<void>> _waiting = [];
  bool _flushing = false;
  bool _dead = false;

  void add(List<int> bytes) {
    if (_dead) return;
    if (_flushing) {
      _queued.add(bytes);
      return;
    }
    try {
      _pipe.add(bytes);
    } on Object {
      _fail();
    }
  }

  Future<void> flush() {
    if (_dead) return Future.error(const SocketException('Pipe closed.'));
    final done = Completer<void>();
    _waiting.add(done);
    _kick();
    return done.future;
  }

  void _kick() {
    if (_flushing || _dead) return;
    try {
      for (final bytes in _queued) {
        _pipe.add(bytes);
      }
    } on Object {
      _fail();
      return;
    }
    _queued.clear();
    if (_waiting.isEmpty) return;

    final answering = _waiting;
    _waiting = [];
    _flushing = true;
    _pipe.flush().then(
      (_) {
        _flushing = false;
        for (final done in answering) {
          done.complete();
        }
        _kick();
      },
      onError: (Object error) {
        _flushing = false;
        for (final done in answering) {
          done.completeError(error);
        }
        _fail();
      },
    );
  }

  void _fail() {
    if (_dead) return;
    _dead = true;
    _queued.clear();
    for (final done in _waiting) {
      done.completeError(const SocketException('Pipe closed.'));
    }
    _waiting.clear();
    _pipe.destroy();
  }
}

// ---------------------------------------------------------------------------
// The desktop's half

/// The desktop end of one cable: every channel a [DisplayLink] for [host].
class UsbRelayHost {
  UsbRelayHost(this._pipe, this._host, {this.onClosed})
    : _out = _Outbox(_pipe) {
    _subscription = _pipe.input.listen(
      _receive,
      onError: (Object _) => close(),
      onDone: close,
      cancelOnError: true,
    );
  }

  final UsbPipe _pipe;
  final DisplayHost _host;
  final _Outbox _out;

  /// Lenient about what comes before the tablet's first preamble: on an
  /// Android accessory that can be the tail of a session nobody is reading.
  final CarriageReader _reader = CarriageReader(resync: true);
  final Map<int, _ChannelLink> _channels = {};
  late final StreamSubscription<Uint8List> _subscription;

  /// Called once, when the cable is gone.
  final void Function(UsbRelayHost)? onClosed;

  /// What the tablet calls itself, once it has said.
  final ValueNotifier<String?> name = ValueNotifier(null);

  bool _closed = false;
  bool get isClosed => _closed;

  /// How many displays this cable has open right now. A knock counts while it
  /// lasts.
  int get channelCount => _channels.length;

  void _receive(Uint8List chunk) {
    if (_closed) return;
    _reader.add(chunk);
    try {
      final before = _reader.preambleSeen;
      final more = _reader.moveNext();
      // **Answered, never volunteered.** The desktop's preamble goes out when
      // the tablet's arrives, because only then is anybody reading: an Android
      // accessory drops what was written while no application had it open.
      if (!before && _reader.preambleSeen) _answer();
      if (!more) return;
      do {
        final channel = _reader.channel;
        switch (_reader.kind) {
          case CarriageKind.restart:
            // The tablet's relay started over on a cable that stayed up — the
            // application was restarted. Its channels went with it.
            for (final link in List.of(_channels.values)) {
              link._ended();
            }
            _channels.clear();
            _answer();
          case CarriageKind.name:
            name.value = utf8.decode(_reader.payload, allowMalformed: true);
          case CarriageKind.open:
            if (_channels.containsKey(channel)) continue;
            final link = _ChannelLink(channel, _out, _forget);
            _channels[channel] = link;
            _host.adopt(link);
          case CarriageKind.data:
            _channels[channel]?._deliver(Uint8List.fromList(_reader.payload));
          case CarriageKind.close:
            _channels.remove(channel)?._ended();
        }
      } while (_reader.moveNext());
    } on FormatException {
      close();
    }
  }

  void _answer() {
    _out.add(UsbCarriage.preamble);
    unawaited(_out.flush().catchError((Object _) {}));
  }

  void _forget(int channel) => _channels.remove(channel);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final link in List.of(_channels.values)) {
      link._ended();
    }
    _channels.clear();
    unawaited(_subscription.cancel());
    _pipe.destroy();
    onClosed?.call(this);
    name.dispose();
  }
}

class _ChannelLink implements DisplayLink {
  _ChannelLink(this._channel, this._out, this._forget);

  final int _channel;
  final _Outbox _out;
  final void Function(int) _forget;
  final StreamController<Uint8List> _incoming = StreamController();
  final Completer<void> _done = Completer();

  void _deliver(Uint8List bytes) {
    if (!_incoming.isClosed) _incoming.add(bytes);
  }

  /// The tablet hung up, or the cable went.
  void _ended() {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<void> get done => _done.future;

  @override
  void add(List<int> bytes) {
    if (_done.isCompleted) return;
    _out.add(UsbCarriage.encode(CarriageKind.data, _channel, bytes));
  }

  @override
  Future<void> flush() => _done.isCompleted ? Future.value() : _out.flush();

  @override
  void destroy() {
    if (_done.isCompleted) return;
    _out.add(UsbCarriage.encode(CarriageKind.close, _channel));
    _forget(_channel);
    _ended();
  }
}

// ---------------------------------------------------------------------------
// The tablet's half

/// The tablet end: a cable on [kUsbPipePort], displays on [kUsbRelayPort].
///
/// Started once, at launch, on Android and iOS, and never stopped: both ports
/// are loopback, nothing is relayed until a desktop sends the preamble, and a
/// tablet that is plugged in has to be ready before anybody opens a picker.
class TabletRelay {
  TabletRelay({
    required this.name,
    this.pipePort = kUsbPipePort,
    this.relayPort = kUsbRelayPort,
  });

  /// What this tablet tells the desktop it is called.
  final String name;
  final int pipePort;
  final int relayPort;

  /// Whether this platform ends a cable here: the two tablets. Overridden by
  /// the suite, which runs on a desktop.
  @visibleForTesting
  static bool? platformSupported;

  static bool get supported =>
      platformSupported ?? (Platform.isAndroid || Platform.isIOS);

  /// Whether a desktop is at the other end of a cable right now.
  final ValueNotifier<bool> attached = ValueNotifier(false);

  ServerSocket? _pipeServer;
  ServerSocket? _relayServer;

  /// The ports actually bound, which differ from the asked-for ones only when
  /// a test asks for 0.
  @visibleForTesting
  int? get boundPipePort => _pipeServer?.port;
  @visibleForTesting
  int? get boundRelayPort => _relayServer?.port;
  Socket? _pipe;
  _Outbox? _out;
  CarriageReader? _reader;
  final Map<int, Socket> _displays = {};
  int _nextChannel = 1;
  bool _disposed = false;
  Timer? _greeting;

  /// Binds the cable's port. Safe to call again — on an iPad coming back to the
  /// foreground, whose listening socket the system may have taken away.
  Future<void> start() async {
    if (_disposed || _pipeServer != null) return;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        pipePort,
      );
      _pipeServer = server;
      server.listen(
        _acceptPipe,
        onError: (Object _) => _pipeServer = null,
        onDone: () => _pipeServer = null,
      );
    } on SocketException {
      // Somebody else holds it — a second copy of the application. That copy
      // is the one the cable will reach.
    }
  }

  void _acceptPipe(Socket socket) {
    // The newest cable wins: a replug arrives before the old tunnel has been
    // noticed as gone.
    _dropPipe();
    socket.setOption(SocketOption.tcpNoDelay, true);
    final pipe = SocketPipe(socket);
    final out = _Outbox(pipe);
    final reader = CarriageReader();
    _pipe = socket;
    _out = out;
    _reader = reader;
    _greet(out);
    // **Said again until it is answered.** The desktop answers a preamble and
    // never volunteers one, and on an Android accessory the first may have
    // gone into a cable that was still draining an older session — the
    // desktop skips to the next preamble it sees, so repeating is free.
    _greeting?.cancel();
    _greeting = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (!identical(_out, out) || (_reader?.preambleSeen ?? true)) {
        timer.cancel();
        return;
      }
      _greet(out);
    });

    socket.listen(
      (chunk) => _fromDesktop(socket, chunk),
      onError: (Object _) => _pipeGone(socket),
      onDone: () => _pipeGone(socket),
      cancelOnError: true,
    );
  }

  void _greet(_Outbox out) {
    out
      ..add(UsbCarriage.preamble)
      ..add(UsbCarriage.encodeName(name));
    unawaited(out.flush().catchError((Object _) {}));
  }

  Future<void> _bindRelay() async {
    if (_relayServer != null) return;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        relayPort,
      );
      if (_pipe == null || _disposed) {
        await server.close();
        return;
      }
      _relayServer = server;
      server.listen(_acceptDisplay, onError: (Object _) {});
      attached.value = true;
    } on SocketException {
      // Held by something else; the cable is up and nobody can reach it, which
      // is what a picker with no USB row says.
    }
  }

  void _acceptDisplay(Socket display) {
    final out = _out;
    if (out == null) {
      display.destroy();
      return;
    }
    display.setOption(SocketOption.tcpNoDelay, true);
    final channel = _nextChannel++;
    _displays[channel] = display;
    out.add(UsbCarriage.encode(CarriageKind.open, channel));
    unawaited(out.flush().catchError((Object _) {}));

    display.listen(
      (bytes) {
        // Acknowledgements, a few bytes each; flushed with whatever is next.
        _out?.add(UsbCarriage.encode(CarriageKind.data, channel, bytes));
        unawaited(_out?.flush().catchError((Object _) {}));
      },
      onError: (Object _) => _displayGone(channel),
      onDone: () => _displayGone(channel),
      cancelOnError: true,
    );
  }

  void _displayGone(int channel) {
    final display = _displays.remove(channel);
    if (display == null) return;
    display.destroy();
    _out?.add(UsbCarriage.encode(CarriageKind.close, channel));
    unawaited(_out?.flush().catchError((Object _) {}));
  }

  void _fromDesktop(Socket pipe, Uint8List chunk) {
    final reader = _reader;
    if (!identical(pipe, _pipe) || reader == null) return;
    reader.add(chunk);
    try {
      final before = reader.preambleSeen;
      final more = reader.moveNext();
      // The relay port opens on the desktop's preamble, not on the connection:
      // anything else that finds the cable's port never gets a display to it.
      if (!before && reader.preambleSeen) {
        _greeting?.cancel();
        unawaited(_bindRelay());
      }
      if (!more) return;
      do {
        final channel = reader.channel;
        switch (reader.kind) {
          case CarriageKind.data:
            try {
              _displays[channel]?.add(Uint8List.fromList(reader.payload));
            } on Object {
              _displayGone(channel);
            }
          case CarriageKind.close:
            _displays.remove(channel)?.destroy();
          case CarriageKind.open || CarriageKind.name || CarriageKind.restart:
            // The first two are the tablet's to send; a second preamble is the
            // desktop answering a greeting it had already answered.
            break;
        }
      } while (reader.moveNext());
    } on FormatException {
      _dropPipe();
    }
  }

  void _pipeGone(Socket pipe) {
    if (identical(pipe, _pipe)) _dropPipe();
  }

  void _dropPipe() {
    _greeting?.cancel();
    _greeting = null;
    final pipe = _pipe;
    _pipe = null;
    _out = null;
    _reader = null;
    pipe?.destroy();
    // Copied first: a socket destroyed here reports itself done, and its
    // handler removes it from the map being walked.
    final displays = List.of(_displays.values);
    _displays.clear();
    for (final display in displays) {
      display.destroy();
    }
    final relay = _relayServer;
    _relayServer = null;
    unawaited(relay?.close());
    if (!_disposed) attached.value = false;
  }

  void dispose() {
    _disposed = true;
    _dropPipe();
    unawaited(_pipeServer?.close());
    _pipeServer = null;
    attached.dispose();
  }
}
