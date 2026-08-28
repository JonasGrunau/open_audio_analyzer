// SPDX-License-Identifier: GPL-3.0-or-later
//
// The desktop end of the plugin link.
//
// ---------------------------------------------------------------------------
// Why this listens instead of connecting
//
// The two halves of Open Audio Analyzer's wire protocol dial in opposite
// directions, and which end listens is decided by which end is long-lived:
//
//   47821  a desktop publishes, a tablet connects in   (remote display)
//   47822  a plugin publishes, this accepts            (here)
//
// A plugin appears and disappears with the DAW's session — it is instantiated,
// bypassed, moved between tracks and deleted, several times an hour. The app is
// the thing that stays open. Making the transient end the one that dials means
// a plugin that loads before the app simply keeps retrying until the app is
// there, and one that is deleted just closes its socket. The reverse
// arrangement would need the app to discover instances that may not exist yet,
// inside a host that does not expose them.
//
// The ports are adjacent rather than shared for a reason worth keeping: on one
// port an accepted socket would be ambiguous about which side sends HELLO
// first, and guessing wrong is not an error anybody sees — it is two peers each
// waiting for the other to speak, which presents as "it connected, and then
// nothing happened".
//
// ---------------------------------------------------------------------------
// Nothing here is on the paint path
//
// Frames arrive on socket events and decode into a `WireSnapshot` whose arrays
// are allocated once. The app's single `MeterClock` reads them at its own rate,
// so two frames arriving between two ticks cost one repaint rather than two —
// the same arithmetic that makes the local engine cheap.

import 'dart:async';
import 'dart:io';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
import 'package:flutter/foundation.dart';

/// The port a desktop Open Audio Analyzer accepts plugin connections on.
const int kPluginLinkPort = 47822;

/// One connected plugin instance.
///
/// A session is a DAW insert: its measurements are of one track, or one bus, or
/// one master, and several may be open at once because somebody has put Open
/// Audio Analyzer on more than one of them.
class PluginSession {
  PluginSession._(this._socket, this.id);

  final Socket _socket;

  /// Stable for the life of the connection, so the UI can keep a selection
  /// across frames without holding the session object itself.
  final int id;

  /// What the plugin calls itself, which includes the host — "Open Audio
  /// Analyzer plugin — Logic Pro". Null until its HELLO arrives.
  String? producerName;

  /// The plugin's engine ABI. Shown, never used to decide anything: an additive
  /// ABI bump leaves the wire byte-identical, so refusing a link over it would
  /// refuse one that works.
  int? abiVersion;

  /// Measurements. Arrays never change identity, so a painter may hold one.
  final WireSnapshot snapshot = WireSnapshot();

  /// The host's playhead, as of the most recent block.
  ///
  /// [Transport.none] until the plugin sends one — which some hosts never do,
  /// and which is why the Elapsed and Timecode LUFS modes check
  /// [Transport.isPresent] rather than assuming a DAW implies a playhead.
  Transport transport = Transport.none;

  DateTime lastFrameAt = DateTime.now();

  /// What this application calls the session, in its own interface.
  ///
  /// **Not [producerName], and the difference is the product's own name.** A
  /// producer names itself in full on the wire — "Open Audio Analyzer plugin —
  /// Logic Pro" — because HELLO is read by things that are not this
  /// application and a bare host name would say nothing about who sent it.
  /// Inside this application the first half is a constant: a source menu that
  /// offers "Open Audio Analyzer plugin — Logic Pro" between "Test tone" and
  /// "Scarlett 2i2" is naming the product in the one list where every other row
  /// names the thing being metered — and it is the longest row in a chip that
  /// ellipsises at 220 px, so what a narrow window actually shows is the half
  /// that is the same on every machine.
  ///
  /// So the prefix comes off and the DAW is what is left. A producer that is
  /// not ours keeps whatever it called itself, unaltered.
  String get displayName {
    final name = producerName;
    if (name == null) return 'DAW plugin';
    const prefix = 'Open Audio Analyzer plugin — ';
    if (!name.startsWith(prefix)) return name;
    final host = name.substring(prefix.length).trim();
    return host.isEmpty ? 'DAW plugin' : 'DAW plugin — $host';
  }

  Future<void> _close() async {
    _socket.destroy();
  }
}

/// Accepts plugin connections and decodes what they send.
///
/// Deliberately a `ChangeNotifier` over *session membership* only. The
/// measurements inside a session are read by painters straight off the
/// `WireSnapshot`, never through a notifier — routing meter data through the
/// widget tree is precisely the rebuild-per-frame this architecture exists to
/// avoid.
class PluginLink extends ChangeNotifier {
  PluginLink({
    this.port = kPluginLinkPort,
    this.staleAfter = const Duration(seconds: 2),
  });

  final int port;

  /// How long without a frame before a session's meters stop claiming to be
  /// current. A DAW with its transport stopped still calls `processBlock` and
  /// still sends frames, so silence here means the link is gone, not that the
  /// music stopped.
  final Duration staleAfter;

  ServerSocket? _server;
  Timer? _staleTimer;
  int _nextId = 1;

  /// Teardown is asynchronous and notification is not, which is the whole
  /// reason this exists: `dispose` cannot await `stop`, so `stop` finishes
  /// after the notifier is already dead and would notify a disposed object.
  /// Sockets also close on their own schedule, so a plugin dropping at the
  /// moment the app quits arrives at the same place by a different route.
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _fail(String? message) {
    if (!_disposed) failure.value = message;
  }

  final List<PluginSession> _sessions = <PluginSession>[];
  final Map<PluginSession, StreamSubscription<Uint8List>> _subscriptions = {};
  final Map<PluginSession, FrameReader> _readers = {};

  /// Every connected plugin, in the order they arrived.
  List<PluginSession> get sessions => List.unmodifiable(_sessions);

  /// [PluginSession.displayName], with the connection's own number added when
  /// the name alone cannot tell two sessions apart.
  ///
  /// Two inserts in one host are two sessions with identical names — the wire
  /// carries the host and nothing else, so the track a plugin sits on, which is
  /// what a person would actually name it by, is not available to say. A menu
  /// offering "DAW plugin — Logic Pro" twice is a menu with no answer in it.
  ///
  /// The id rather than a position in the list, because a selection has to
  /// survive the list changing: positions renumber when a session ahead of one
  /// drops, and the row somebody chose would then name a different insert.
  String labelFor(PluginSession session) {
    final name = session.displayName;
    final ambiguous = _sessions.any(
      (other) => !identical(other, session) && other.displayName == name,
    );
    return ambiguous ? '$name #${session.id}' : name;
  }

  /// Which session the meters are showing.
  ///
  /// Defaults to the most recent connection rather than the first, because the
  /// plugin somebody just inserted is the one they want to look at — the act of
  /// inserting it *is* the selection. A user who wants otherwise picks from the
  /// list; a user who does not gets what they meant.
  PluginSession? get active => _active;
  PluginSession? _active;

  set active(PluginSession? session) {
    if (session != null && !_sessions.contains(session)) return;
    if (identical(_active, session)) return;
    _active = session;
    _notify();
  }

  /// Called for every transport frame a session sends, as it is decoded.
  ///
  /// **A plain callback, and deliberately not a notification.** This fires once
  /// per audio block — ninety-odd times a second at a typical buffer size — so
  /// routing it through [notifyListeners] would rebuild the canvas at block rate
  /// to move a clock, which is the habit the whole frame path is built to avoid.
  /// Nothing that repaints listens to it.
  ///
  /// It exists because one consumer cannot sample: the remote display forwards
  /// transport to tablets at its own rate, and
  /// [Transport.flagDiscontinuity] is an edge delivered once — see
  /// [Transport.asDiscontinuous] and `docs/WIRE.md`. Anything that only wants a
  /// position reads [PluginSession.transport] when it paints instead.
  void Function(PluginSession session, Transport transport)? onTransport;

  /// Why listening failed, in a sentence meant for a person. Null when fine.
  ///
  /// The overwhelmingly common cause is a second copy of Open Audio Analyzer
  /// already running, and saying so is considerably more use than "address in
  /// use".
  final ValueNotifier<String?> failure = ValueNotifier(null);

  bool get isListening => _server != null;

  /// The port actually bound, which differs from [port] only when [port] is 0 —
  /// a test asking the operating system to pick a free one.
  int? get boundPort => _server?.port;

  /// Starts accepting plugins. Safe to call when already listening.
  Future<void> start() async {
    if (_server != null) return;

    try {
      // Loopback only, and this line is load-bearing beyond the obvious.
      //
      // The plain reason: a metering link carries no credentials and performs
      // no authentication, so binding every interface would put an
      // unauthenticated stream on the local network for no benefit anybody
      // asked for. The plugin and the app are on one machine in every case this
      // port exists to serve.
      //
      // The reason that will bite somebody later: **this is what makes control
      // frames permissible here at all.** The two Open Audio Analyzer ports
      // have deliberately different trust boundaries — 47821 binds every
      // interface for the remote display and stays strictly read-only, while
      // 47822 binds loopback, where the set of things that can connect is the
      // set of things already running as this user, a boundary a password would
      // not improve. That asymmetry is why `docs/WIRE.md` allows app-to-plugin
      // control frames (0x0020– 0x002F) on this port and forbids them on the
      // other one. Restarting an integration mid-programme is wrong in a way
      // nothing on screen reveals, and it is not a capability to hand to an
      // unauthenticated LAN port.
      //
      // So: if this ever becomes `anyIPv4` to reach a plugin on another
      // machine, that reasoning lapses and control frames must be refused on
      // the wider socket. Changing the bind address is not a configuration
      // tweak; it is a decision about what this port is allowed to accept.
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      _fail(null);

      _server!.listen(_accept, onError: (Object e) => _fail(_describe(e)));

      _staleTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _checkStale(),
      );
    } on Object catch (error) {
      _server = null;
      _fail(_describe(error));
    }
    _notify();
  }

  Future<void> stop() async {
    _staleTimer?.cancel();
    _staleTimer = null;

    for (final session in List.of(_sessions)) {
      await _drop(session, notify: false);
    }

    await _server?.close();
    _server = null;
    _notify();
  }

  void _accept(Socket socket) {
    if (_disposed) {
      socket.destroy();
      return;
    }

    socket.setOption(SocketOption.tcpNoDelay, true);

    final session = PluginSession._(socket, _nextId++);
    _sessions.add(session);
    _readers[session] = FrameReader();

    // Most recent wins — see `active`.
    _active = session;

    _subscriptions[session] = socket.listen(
      (chunk) => _receive(session, chunk),
      onError: (Object _) => unawaited(_drop(session)),
      onDone: () => unawaited(_drop(session)),
      cancelOnError: true,
    );

    _notify();
  }

  void _receive(PluginSession session, Uint8List chunk) {
    final reader = _readers[session];
    if (reader == null) return;

    reader.add(chunk);

    try {
      while (reader.moveNext()) {
        switch (reader.type) {
          case WireFrameType.hello:
            final hello = WireHello.decode(reader.payload);
            session.producerName = hello.producerName;
            session.abiVersion = hello.abiVersion;

            final refusal = hello.incompatibility;
            if (refusal != null) {
              // Refusing is the honest outcome. Drawing this plugin's frames
              // anyway would not crash — it would put a detailed, wrong picture
              // on screen, which somebody would then make a delivery decision
              // from.
              _fail('${session.displayName}: $refusal');
              unawaited(_drop(session));
              return;
            }
            _notify();

          case WireFrameType.dawTransport:
            final transport = DawTransportCodec.decode(reader.payload);
            session.transport = transport;
            // And on the snapshot the modules read, because the oscilloscope's
            // tempo sync is a display that needs the playhead and a module is
            // handed nothing but a `MeterSource`.
            session.snapshot.transport = transport;
            onTransport?.call(session, transport);

          case WireFrameType.snapshot:
            session.snapshot.decode(reader.payload, version: reader.version);
            session.lastFrameAt = DateTime.now();

          default:
          // Skipped by length. That is what lets a newer plugin, sending frame
          // types this build has never heard of, keep talking to it.
        }
      }
    } on Object catch (error) {
      // A stream that has lost sync stays lost, so there is nothing useful to
      // do with it but drop it and let the plugin reconnect — which it will,
      // within a second, on its own.
      _fail(_describe(error));
      unawaited(_drop(session));
    }
  }

  void _checkStale() {
    final now = DateTime.now();
    for (final session in _sessions) {
      if (now.difference(session.lastFrameAt) >= staleAfter) {
        // The socket is still open, so this is not a disconnection — but
        // nothing on screen can be claimed to be current, and a frozen meter
        // reads exactly like a quiet passage.
        session.snapshot.markStale();
      }
    }
  }

  Future<void> _drop(PluginSession session, {bool notify = true}) async {
    final subscription = _subscriptions.remove(session);
    await subscription?.cancel();
    _readers.remove(session);
    _sessions.remove(session);
    await session._close();

    if (identical(_active, session)) {
      _active = _sessions.isEmpty ? null : _sessions.last;
    }
    if (notify) _notify();
  }

  static String _describe(Object error) => switch (error) {
    SocketException(:final osError)
        when osError?.errorCode == 48 || osError?.errorCode == 98 =>
      'Another copy of Open Audio Analyzer is already listening for plugins on port '
          '$kPluginLinkPort.',
    SocketException(:final message, :final osError) =>
      osError == null ? message : '$message (${osError.message})',
    WireFormatException(:final message) => message,
    _ => error.toString(),
  };

  @override
  void dispose() {
    // Set first, so that the teardown `stop` schedules — and any socket
    // callback still in flight — finds the flag already raised rather than
    // notifying an object that is about to be gone.
    _disposed = true;
    unawaited(stop());
    failure.dispose();
    super.dispose();
  }
}
