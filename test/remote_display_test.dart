// SPDX-License-Identifier: GPL-3.0-or-later
//
// The remote display, end to end over a real socket.
//
// `packages/bel_wire` proves the codec in isolation; this proves the two halves
// that use it actually talk. It runs a DisplayHost and a DisplayClient in one
// process over the loopback interface, which is a genuine TCP connection with
// genuine framing — no fakes between them — so a mistake in the handshake, the
// frame boundaries or the publish loop fails here rather than on a tablet in
// somebody's live room.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bel/src/remote/display_client.dart';
import 'package:bel/src/remote/display_host.dart';
import 'package:bel_core/bel_core.dart';
import 'package:bel_wire/bel_wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeSource source;
  late DisplayHost host;
  late DisplayClient client;

  setUp(() {
    source = _FakeSource();
    host = DisplayHost(source: source, hostName: 'Test Host', abiVersion: 4);
    client = DisplayClient(staleAfter: const Duration(milliseconds: 300));
  });

  tearDown(() async {
    await client.disconnect();
    client.dispose();
    await host.stop();
    host.dispose();
  });

  Future<void> connect() async {
    // Port 0 asks the OS for a free one, so the suite cannot collide with a
    // developer running the real app on the default port while it runs.
    await host.start(port: 0);
    await client.connect('127.0.0.1', host.port!);
    await _settle();
  }

  test('a display learns who it is attached to', () async {
    await connect();

    expect(client.state.value, RemoteLinkState.live);
    expect(client.hostName.value, 'Test Host');
    expect(client.hostAbiVersion, 4);
    expect(host.clientCount.value, 1);
  });

  test('a display says it is connecting before it suspends once', () async {
    await host.start(port: 0);

    // Not a nicety about a label. [DisplayClient.connect] is called from the
    // display screen's `initState`, and that screen draws the host picker for
    // as long as the link is idle — so a state published after the first
    // `await` is published after that screen's first build. The display was
    // handed a host and still built a picker nobody asked for, which searches
    // the network in its own `initState`: a panel flashing on the way in, and
    // a second browse started and torn down a frame later.
    final connecting = client.connect('127.0.0.1', host.port!);
    expect(client.state.value, RemoteLinkState.connecting);

    await connecting;
    await _settle();
    expect(client.state.value, RemoteLinkState.live);
  });

  test('measurements arrive and match what the host is reading', () async {
    source
      ..generation = 1
      ..lufsIntegrated = -14.2
      ..truePeakMax = -0.8
      ..correlation = 0.35
      ..channels = 2
      ..sampleRate = 48000
      ..isRunning = true;
    source.peak[0] = -3.5;
    source.peak[1] = -4.25;
    source.spectrum[100] = -37.5;

    await connect();
    await _settle(milliseconds: 200);

    expect(client.snapshot.lufsIntegrated, closeTo(-14.2, 1e-5));
    expect(client.snapshot.truePeakMax, closeTo(-0.8, 1e-5));
    expect(client.snapshot.correlation, closeTo(0.35, 1e-6));
    expect(client.snapshot.peak[0], closeTo(-3.5, 1e-6));
    expect(client.snapshot.peak[1], closeTo(-4.25, 1e-6));
    expect(client.snapshot.spectrum[100], closeTo(-37.5, 1e-5));
    expect(client.snapshot.sampleRate, 48000);
    expect(client.snapshot.channels, 2);
    expect(client.snapshot.isRunning, isTrue);
  });

  test('an unmeasured quantity arrives unmeasured', () async {
    // The rule that matters most on this path. A remote display that turned a
    // NaN into a zero somewhere between two machines would show a confident
    // reading nobody took, and it would look exactly like a real one.
    source
      ..generation = 1
      ..lufsIntegrated = double.nan
      ..loudnessRange = double.nan;

    await connect();
    await _settle(milliseconds: 200);

    expect(client.snapshot.lufsIntegrated.isNaN, isTrue);
    expect(client.snapshot.loudnessRange.isNaN, isTrue);
  });

  test('the layout, skin and target reach the display', () async {
    final preset = PresetSpec(
      name: 'Mastering',
      tabs: const [
        TabSpec(
          name: 'Main',
          modules: [
            ModuleSpec(
              id: 'a',
              kind: ModuleKind.lufsMeter,
              rect: GridRect(column: 0, row: 0, columns: 6, rows: 8),
              options: {'metric': 'lufs_i'},
            ),
          ],
        ),
      ],
    );
    final calibration = BuiltInCalibrations.all.first;

    host
      ..publishLayout(preset)
      ..publishCalibration(calibration);

    await connect();

    expect(client.layout.value?.name, 'Mastering');
    expect(client.layout.value?.tabs.single.modules.single.id, 'a');
    expect(
      client.layout.value?.tabs.single.modules.single.kind,
      ModuleKind.lufsMeter,
    );
    expect(client.calibration.value.id, calibration.id);

    // The built-in skin travels as an empty payload, which the display reads as
    // "use the default" rather than as a missing frame.
    expect(client.skin.value, isNull);
  });

  test(
    'a display that joins mid-session is caught up, not left blank',
    () async {
      await connect();

      final preset = PresetSpec(
        name: 'Later',
        tabs: const [TabSpec(name: 'Main', modules: [])],
      );
      host.publishLayout(preset);
      await _settle();

      expect(client.layout.value?.name, 'Later');
    },
  );

  test('a quiet link stops claiming to be current', () async {
    source
      ..generation = 1
      ..lufsShort = -18.0
      ..isRunning = true;

    await connect();
    await _settle(milliseconds: 200);
    expect(client.snapshot.lufsShort, closeTo(-18.0, 1e-5));

    // The host goes away without closing cleanly — the tablet's Wi-Fi drops,
    // the laptop lid closes. The socket does not necessarily notice.
    await host.stop();
    await _settle(milliseconds: 700);

    expect(client.state.value, isNot(RemoteLinkState.live));
    expect(
      client.snapshot.lufsShort.isNaN,
      isTrue,
      reason: 'a frozen reading is indistinguishable from a quiet passage',
    );
    expect(client.snapshot.isRunning, isFalse);
    expect(client.snapshot.hasLoudness, isFalse);
  });

  test('a display comes back after a link that dropped mid-frame', () async {
    // The failure this guards against is not the drop — it is everything
    // after it. [DisplayClient] holds one [FrameReader] for its whole life,
    // and a socket that dies partway through a 15 kB snapshot leaves the head
    // of that frame in it. Reading on reassembles those bytes onto the head of
    // the *next* connection's stream, at exactly the right length to decode:
    // the display drew one frame of confident, invented measurement, lost sync
    // on whatever followed, and dropped the link — carrying the leftovers into
    // the retry, which repeated it. A tablet that lost one frame to a Wi-Fi
    // hiccup never came back, and Disconnect did not clear it either.
    //
    // A real DisplayHost cannot be asked to die mid-frame, so the host here is
    // a raw socket that does exactly that once and behaves perfectly after.
    final hello = WireHello.local(
      abiVersion: 4,
      producerName: 'Interrupted Host',
    ).encodeFrame();
    final frame = SnapshotFrame()..encode(source..generation = 77);

    var connections = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      connections++;

      if (connections == 1) {
        socket
          ..add(hello)
          // Partway through a snapshot, and then the network is gone.
          ..add(Uint8List.sublistView(frame.bytes, 0, 6000));
        Future<void>.delayed(const Duration(milliseconds: 60), socket.destroy);
        return;
      }

      socket.add(hello);
      final pump = Timer.periodic(const Duration(milliseconds: 30), (timer) {
        try {
          socket.add(frame.bytes);
        } on Object {
          timer.cancel();
        }
      });
      addTearDown(pump.cancel);
    }, onError: (Object _) {});

    final display = DisplayClient(staleAfter: const Duration(seconds: 5));
    addTearDown(() async {
      await display.disconnect();
      display.dispose();
    });

    await display.connect('127.0.0.1', server.port);
    // Past the 1 s first retry, with room for the reconnected stream to land.
    await _settle(milliseconds: 1800);

    expect(connections, greaterThan(1), reason: 'the retry never happened');
    expect(
      display.state.value,
      RemoteLinkState.live,
      reason: 'the display never recovered: ${display.failure.value}',
    );
    expect(display.snapshot.isStale, isFalse);
    expect(
      display.snapshot.generation,
      77,
      reason: 'the reassembled frame was not the one the host sent',
    );
  });

  test('a frame still in flight does not take the host with it', () async {
    await connect();
    source.generation = 1;

    // **A socket with a `flush` outstanding is a bound sink, and a bound sink
    // refuses `close`** — with a `StateError` thrown *synchronously*, before
    // the future the host attached a `catchError` to exists. It surfaced as an
    // unhandled exception in the host every time a display went away
    // mid-frame, and the `destroy` underneath it never ran.
    host.publishNow();
    await expectLater(host.stop(), completes);
  });

  test('a layout published mid-frame arrives rather than dropping the display', () async {
    await connect();
    source.generation = 1;

    // The same bound sink, through the other door: `add` refuses too, and the
    // only thing this path could do with the throw was close the connection.
    // So changing the skin or the delivery target at the desk dropped the
    // tablet — more often the slower the tablet was, because a display that
    // takes longer to read is a socket that spends longer flushing.
    host
      ..publishNow()
      ..publishLayout(
        PresetSpec(
          name: 'Mid-frame',
          tabs: const [TabSpec(name: 'Main', modules: [])],
        ),
      );
    await _settle(milliseconds: 200);

    expect(client.layout.value?.name, 'Mid-frame');
    expect(host.clientCount.value, 1);
    expect(client.state.value, isNot(RemoteLinkState.failed));
  });

  test('the host notices a display leaving', () async {
    await connect();
    expect(host.clientCount.value, 1);

    await client.disconnect();
    await _settle();

    expect(host.clientCount.value, 0);
  });

  test('publishing is off until it is switched on', () async {
    expect(host.isListening, isFalse);
    expect(host.port, isNull);
  });
}

/// Real time, not fake: these are real sockets and a real periodic timer, so
/// the test has to actually wait for them.
Future<void> _settle({int milliseconds = 120}) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

class _FakeSource implements MeterSource {
  @override
  int generation = 0;

  @override
  double elapsedSeconds = 0;

  @override
  int sampleRate = 48000;

  @override
  int channels = 2;

  @override
  bool isRunning = false;

  @override
  int droppedFrames = 0;

  @override
  bool hasOverrun = false;

  @override
  bool hasLoudness = true;

  @override
  bool hasSpectrum = true;

  @override
  double lufsMomentary = double.nan;

  @override
  double lufsShort = double.nan;

  @override
  double lufsIntegrated = double.nan;

  @override
  double loudnessRange = double.nan;

  @override
  double loudnessRangeLow = double.nan;

  @override
  double loudnessRangeHigh = double.nan;

  @override
  double loudnessRangeGate = double.nan;

  @override
  double truePeak = double.nan;

  @override
  double truePeakMax = double.nan;

  @override
  double samplePeakMax = double.nan;

  @override
  double dynamicRangeShort = double.nan;

  @override
  double dynamicRangeIntegrated = double.nan;

  @override
  double crestFactor = double.nan;

  @override
  double peakToLoudnessRatio = double.nan;

  @override
  double peakToShortTermRatio = double.nan;

  @override
  double correlation = double.nan;

  @override
  double balance = double.nan;

  @override
  final Float32List peak = Float32List(MeterShape.maxChannels);

  @override
  final Float32List rms = Float32List(MeterShape.maxChannels);

  @override
  final Float32List vu = Float32List(MeterShape.maxChannels);

  @override
  final Uint32List clip = Uint32List(MeterShape.maxChannels);

  @override
  final Float32List spectrum = Float32List(MeterShape.spectrumBands);

  @override
  final Float32List spectrumPeak = Float32List(MeterShape.spectrumBands);

  @override
  final Float32List spectrumPan = Float32List(MeterShape.spectrumBands);

  @override
  final Float32List scope = Float32List(MeterShape.scopePoints * 2);

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  @override
  bool refresh() => true;
}
