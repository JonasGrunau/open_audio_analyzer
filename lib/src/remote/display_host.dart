// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
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
    required MeterSource? source,
    required this.hostName,
    required this.abiVersion,
  }) {
    // Assigned in the body rather than through the initialiser list, because
    // the field is private and a named parameter may not be. Not through the
    // setter either: there is nothing yet for it to drop.
    _source = source;
  }

  /// What is being measured. Read-only from here — a remote display never
  /// starts, stops or resets anything.
  ///
  /// **Replaceable, and null when there is nothing to publish.** An engine is
  /// destroyed and rebuilt whenever the source changes, so a host that held the
  /// one it was given at construction went on acquiring through a freed handle
  /// — thirty times a second, forever, reading 15 kB of returned heap and
  /// sending it to a tablet as a measurement. Null is the honest state between
  /// an engine failing to open and one opening: nothing is being measured, so
  /// nothing is published.
  ///
  /// **Setting it drops what the previous source left behind**, the same rule
  /// and for the same reason as `MeterClock.engine`. Two things carry over
  /// otherwise: the audio already collected into [_run], which would be sent as
  /// the *new* source's — one programme's waveform spliced onto another's on a
  /// tablet that has no way to know — and [_collected], a generation from a
  /// counter that restarts at zero for every engine, so the frame it happened
  /// to match would be skipped.
  MeterSource? get source => _source;
  MeterSource? _source;

  set source(MeterSource? value) {
    if (identical(value, _source)) return;
    _source = value;
    _collected = -1;
    _collectedElapsed = -1;
    _runFrames = 0;
  }

  /// The DAW's playhead behind [source], or [Transport.none] when whatever is
  /// being measured has no host — a device, a file, or a plugin in a host that
  /// reports no position.
  ///
  /// **Written on every frame the producer sends, never sampled at the publish
  /// rate.** This is a setter rather than a callback for one reason, and it is
  /// the reason the [Transport.flagDiscontinuity] bit exists: `docs/WIRE.md`
  /// specifies it as an edge delivered once, so a relay that asked "what is the
  /// playhead now?" thirty times a second would see two jumps in three only as
  /// a position that moved. Every frame comes through here, the edge is
  /// accumulated, and the publish tick carries whatever has happened since the
  /// last one.
  set transport(Transport value) {
    // Sticky, and cleared only by a send. A relocate that happens between two
    // publishes belongs to the next frame that goes out, alongside the position
    // the playhead landed on.
    if (value.isDiscontinuous) _edgePending = true;
    _transport = value;
  }

  Transport get transport => _transport;
  Transport _transport = Transport.none;
  bool _edgePending = false;

  /// The last transport put on the wire, so that a parked session and a machine
  /// with no DAW at all cost nothing. Null until one has been sent.
  Transport? _sentTransport;

  /// What the tablet shows in its list. A name, never an address.
  final String hostName;

  /// `OAA_ABI_VERSION` of the engine behind [source], carried in the handshake
  /// for the benefit of bug reports. It is not a compatibility check; the
  /// snapshot payload size is.
  final int abiVersion;

  /// The default port. Registered to nothing — picked in the dynamic range so
  /// it collides with no service anyone else runs, and configurable because
  /// somebody will need it to be.
  static const int defaultPort = 47821;

  /// How often measurements go out is `kRemoteFpsOptions` from `oaa_core`, and
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

  /// The skin published during a cooldown, waiting for it to end.
  ///
  /// [_holdingSkin] rather than a null check on [_heldSkin], because null is a
  /// value this field carries — it means "the built-in skin" everywhere else on
  /// this class, and a display left on the previous palette because somebody
  /// went back to the default mid-drag is exactly the wrong-not-late failure
  /// the trailing send exists to prevent.
  Skin? _heldSkin;
  bool _holdingSkin = false;
  Timer? _skinCooldown;
  Calibration? _calibration;

  /// What the two dynamics readings are called, replayed to a display that
  /// joins and sent again on change. Null until the app has said, which is
  /// before the first client can attach in practice.
  DynamicsNaming? _naming;

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
    _pump?.cancel();
    _pump = null;
    _skinCooldown?.cancel();
    _skinCooldown = null;
    _heldSkin = null;
    _holdingSkin = false;

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
  ///
  /// **The one publish on this class that is rate-limited**, and the theme
  /// editor is why. Dragging a colour in it produces a new [Skin] per pointer
  /// move — sixty a second — and each would be a [_RemoteClient.sendOnce],
  /// which is documented there as being for frames that are "rare, small and
  /// must not be dropped": they queue in `_waiting` behind whatever flush is
  /// outstanding, and on a tablet slow enough to still be flushing, that queue
  /// grows for as long as the pointer is down. It is the same failure the
  /// `_waiting` list was added to fix, arriving from the other side.
  ///
  /// A layout and a delivery target need nothing of the kind. Neither can
  /// change at pointer rate: a layout arrives from a drag the canvas has
  /// already debounced into a commit, and a target from a menu.
  ///
  /// [_skin] itself is assigned at once rather than on the cooldown, because it
  /// is what [_accept] replays to a display that joins — and a tablet that
  /// attaches mid-drag should be handed the colour that is on screen now, not
  /// the one that was last broadcast.
  void publishSkin(Skin? skin) {
    _skin = skin;

    if (_skinCooldown != null) {
      _heldSkin = skin;
      _holdingSkin = true;
      return;
    }

    _broadcastSkin(skin);
  }

  /// Sends now and starts the cooldown, which sends whatever arrived during it.
  ///
  /// **Trailing, not leading-only.** Dropping the frames in the middle of a
  /// drag is the point; dropping the last one would leave every attached
  /// display on whatever colour the pointer happened to be over when the timer
  /// last fired — a tablet that is quietly wrong rather than merely behind.
  void _broadcastSkin(Skin? skin) {
    final frame = _skinFrame(skin);
    for (final client in _clients) {
      client.sendOnce(frame);
    }

    _skinCooldown = Timer(skinInterval, () {
      _skinCooldown = null;
      if (!_holdingSkin) return;
      final held = _heldSkin;
      _heldSkin = null;
      _holdingSkin = false;
      _broadcastSkin(held);
    });
  }

  /// The shortest gap between two skin frames.
  ///
  /// Long enough that a two-second drag is a dozen frames rather than a
  /// hundred and twenty; short enough that the tablet is following the colour
  /// rather than being told about it afterwards.
  static const Duration skinInterval = Duration(milliseconds: 150);

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

  /// Publishes what the two dynamics readings are called.
  ///
  /// A label rather than a measurement, and it travels for the reason the
  /// target does: a tablet printing `ODR-S` under the number the desktop has
  /// `PSR` over is two screens somebody has to reconcile. Sent on change and
  /// replayed to a display that joins; a display that predates the frame
  /// skips it and prints the default, which is what the desktop prints unless
  /// somebody chose otherwise.
  void publishDynamicsNaming(DynamicsNaming naming) {
    _naming = naming;
    final frame = _dynamicsNamingFrame(naming);
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
    final naming = _naming;
    if (naming != null) client.sendOnce(_dynamicsNamingFrame(naming));
    // The playhead too, for the same reason and one of its own: transport goes
    // out on change, so a tablet that attaches to a session parked at bar 57
    // would otherwise show no position at all until somebody pressed play.
    if (_transport.isPresent) {
      client.sendOnce(DawTransportCodec.encodeFrame(_transport));
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

    _pump?.cancel();
    _pump = Timer.periodic(_pumpInterval, (_) => _collect());
  }

  /// How often the source is checked for a new measurement, as opposed to how
  /// often one is sent.
  ///
  /// The engine publishes about every 21 ms and the link runs at 15, 30 or
  /// 60 Hz, so at every rate but the fastest a send stands for more than one
  /// measurement. Sending the newest block and discarding the rest is what made
  /// a remote oscilloscope gap on every single frame — see
  /// `MeterSource.scopeFrames`. 5 ms is comfortably inside the engine's period
  /// at every sample rate it supports, and the check itself is a generation
  /// compare.
  static const Duration _pumpInterval = Duration(milliseconds: 5);

  Timer? _pump;

  /// Audio measured since the last send, oldest first.
  ///
  /// Sized once at the protocol's maximum so that nothing on this path
  /// allocates. It overflows on a link slow enough — 15 Hz above 48 kHz — and
  /// when it does the oldest audio is dropped rather than the newest, because a
  /// display drawing the recent past is right and one drawing a stale window is
  /// not. The consumer is told how much arrived and draws the shortfall as the
  /// gap it is.
  final Float32List _run = Float32List(MeterShape.maxScopeFrames * 2);
  int _runFrames = 0;

  /// The generation [_collect] last took audio from, so that two askers cannot
  /// consume each other's answer — the same rule as `MeterClock`.
  int _collected = -1;

  /// The engine time [_collect] last took audio up to.
  ///
  /// A source's `scope` is a window of its newest few blocks, not the one
  /// block this measurement added — see `MeterSource.scopeFrames` — so how
  /// much of it is new is the difference between two reads of
  /// `elapsedSeconds`, the same arithmetic the oscilloscope does. Appending
  /// the whole window per generation would send every block four times over.
  double _collectedElapsed = -1;

  void _collect() {
    final source = this.source;
    if (source == null) return;

    source.refresh();
    if (source.generation == _collected) return;
    _collected = source.generation;

    final held = source.scopeFrames;
    if (held <= 0) return;

    // On the first look, and after a reset has taken the clock backwards, one
    // block's worth: there is nothing to measure a difference against. A
    // source gone stale reports NaN seconds and a block of NaN, and that block
    // goes out as it is — it is the unavailable state, and the display should
    // have it.
    final elapsed = source.elapsedSeconds;
    final rate = source.sampleRate;
    final measurable =
        !elapsed.isNaN &&
        rate > 0 &&
        _collectedElapsed >= 0 &&
        elapsed >= _collectedElapsed;
    final fresh = measurable
        ? ((elapsed - _collectedElapsed) * rate).round()
        : MeterShape.scopePoints;
    if (!elapsed.isNaN) _collectedElapsed = elapsed;

    // More owed than held is audio the window has already dropped. It is not
    // made up here: the display works out the same shortfall from the elapsed
    // time it is sent and draws it as the gap it is.
    final frames = fresh < held ? fresh : held;
    if (frames <= 0) return;
    final first = held - frames;

    final capacity = MeterShape.maxScopeFrames;
    if (_runFrames + frames > capacity) {
      // Keep the newest. Shifting is a copy of at most one full run, at the
      // engine's rate, and only on a link that cannot keep up at all.
      final keep = capacity - frames;
      if (keep <= 0) {
        _runFrames = 0;
      } else {
        _run.setRange(0, keep * 2, _run, (_runFrames - keep) * 2);
        _runFrames = keep;
      }
    }

    _run.setRange(
      _runFrames * 2,
      (_runFrames + frames) * 2,
      source.scope,
      first * 2,
    );
    _runFrames += frames;
  }

  void _publish() {
    if (_clients.isEmpty) return;

    // **Before the source check, not after.** A plugin that is removed takes
    // the app's source with it, and a display whose last word on the subject
    // was "bar 57, rolling" would hold that playhead on screen until the link
    // itself went stale two seconds later. `Transport.none` is how "there is no
    // playhead here" is said, and it is worth saying immediately.
    _publishTransport();

    final source = this.source;
    if (source == null) return;

    // Our own acquire, for the reason in the class comment. [_collect] does the
    // same on a much finer timer; both compare generations rather than trusting
    // what `refresh` returned, which is what lets there be more than one asker.
    _collect();

    final slot = _freeSlot();
    if (slot == null) {
      // Every buffer is still in flight, which means every client is slower
      // than the publish rate. Dropping this measurement is the whole design.
      //
      // The accumulated run is *kept*, not cleared: the audio was measured and
      // the next frame that does go out should carry it. Clearing here would
      // turn a dropped frame into a hole in the waveform.
      return;
    }

    slot.frame.encode(source, scope: _run, scopeFrames: _runFrames);
    _runFrames = 0;

    for (final client in _clients) {
      client.sendPooled(slot);
    }
  }

  /// Sends the transport if it has moved, or if an edge is waiting.
  ///
  /// On change rather than every tick: a session parked at bar 1 and a desktop
  /// metering a sound card both send one frame and then nothing, where an
  /// unconditional 30 Hz would put a hundred bytes a second of "still nothing"
  /// on a Wi-Fi network for as long as the app is open.
  ///
  /// **The edge is checked separately from the comparison, and that is not
  /// belt-and-braces.** A jump that lands the playhead back where an identical
  /// earlier frame left it compares equal in every field, and `docs/WIRE.md`
  /// lets a consumer count relocations by counting the frames that carry the
  /// bit — a dropped one is a relocation that did not happen as far as every
  /// display is concerned.
  void _publishTransport() {
    final transport = _transport;
    if (!_edgePending && _sentTransport == transport) return;

    final outgoing = _edgePending ? transport.asDiscontinuous() : transport;
    _edgePending = false;

    // What was *submitted*, not what was sent: the next comparison asks whether
    // the host has moved, and the edge is not part of that question.
    _sentTransport = transport;

    // **`sendOnce`, which queues, where a snapshot is dropped.** The rule for
    // measurements is that a client behind on its last write loses the frame
    // rather than working through a backlog, because a display showing what the
    // signal did half a second ago looks exactly like one showing what it is
    // doing now. Transport is the other way round on both counts: an edge that
    // is dropped is a relocation nobody can count, and a backlog cannot be seen
    // — a drain delivers every queued frame in one turn of the event loop, and
    // the readout takes the newest value when it next paints rather than
    // replaying the ones behind it. So these are the rare-and-small path, like
    // a layout, and a slow link costs a display nothing but a few dozen bytes.
    final bytes = DawTransportCodec.encodeFrame(outgoing);
    for (final client in _clients) {
      client.sendOnce(bytes);
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

  /// The key is `settings.json`'s, so the choice has one spelling everywhere
  /// it is written down. See `WireFrameType.dynamicsNaming`.
  Uint8List _dynamicsNamingFrame(DynamicsNaming naming) => WireFrame.encode(
    WireFrameType.dynamicsNaming,
    utf8.encode(jsonEncode({'dynamics_names': naming.id})),
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
      _socket.add(slot.frame.wire);
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
