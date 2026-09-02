// SPDX-License-Identifier: GPL-3.0-or-later
//
// The remote display, end to end over a real socket.
//
// `packages/oaa_wire` proves the codec in isolation; this proves the two halves
// that use it actually talk. It runs a DisplayHost and a DisplayClient in one
// process over the loopback interface, which is a genuine TCP connection with
// genuine framing — no fakes between them — so a mistake in the handshake, the
// frame boundaries or the publish loop fails here rather than on a tablet in
// somebody's live room.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oaa/src/remote/display_client.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
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

  // The defect this was written for: `OAA_SCOPE_POINTS` is 1,024 and so is the
  // engine's analysis block, so a snapshot carries 21.3 ms of audio at 48 kHz
  // and the engine publishes about 47 of them a second. A link at 15 or 30 Hz
  // stands for more audio than one block holds, and a host that forwarded the
  // newest block would hand the oscilloscope a fraction of the waveform — which
  // the module correctly detects as a discontinuity and responds to by clearing
  // its ring. Every frame. It never showed as an error; it showed as a scope
  // that would not draw.
  group('a link slower than the engine still carries every sample', () {
    for (final fps in kRemoteFpsOptions) {
      test('at $fps fps the run accounts for all the audio measured', () async {
        host.fps = fps;
        await connect();

        // Sampled *while* audio is flowing. Once the source stops there is
        // nothing left to accumulate and a frame honestly carries a run of
        // zero, so the last frame of the run is the wrong one to look at.
        //
        // `lastRunFrames`, not `scopeFrames`: the client keeps a window of
        // every run it decoded, which grows past a block at any link rate.
        // What this asserts is what *one frame* carried.
        var widest = 0;

        const blocks = 40;
        for (var i = 0; i < blocks; i++) {
          source.generation++;
          source.elapsedSeconds += MeterShape.scopePoints / 48000;
          await _settle(milliseconds: 21);
          final seen = client.snapshot.lastRunFrames;
          if (seen > widest) widest = seen;
        }

        expect(
          client.snapshot.generation,
          greaterThan(0),
          reason: 'nothing arrived at all',
        );

        // What one publish period covers, in samples. Below the engine's ~47 Hz
        // that is more than one block, which is the whole point.
        final perFrame = 48000 / fps;
        final wanted = perFrame < MeterShape.scopePoints
            ? MeterShape.scopePoints
            : perFrame;

        if (wanted > MeterShape.scopePoints) {
          // The defect, stated directly: below the engine's rate a frame has to
          // carry more than one block, and the old transport carried exactly
          // one at every link rate. A slack of one block would have made this
          // vacuous at 30 fps, where a block is already two thirds of a frame.
          expect(
            widest,
            greaterThan(MeterShape.scopePoints),
            reason:
                'the widest run at $fps fps was $widest pairs — one analysis '
                'block, against ${wanted.round()} of audio a frame. The run is '
                'not accumulating and the oscilloscope will gap every frame',
          );
          expect(
            widest,
            greaterThanOrEqualTo((wanted * 0.75).round()),
            reason: 'the run is accumulating but losing audio',
          );
        } else {
          expect(widest, greaterThanOrEqualTo(MeterShape.scopePoints));
        }
        expect(widest, lessThanOrEqualTo(MeterShape.maxScopeFrames));
      });
    }
  });

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

  // --- What the host is reading can be replaced under it ------------------
  //
  // An engine is destroyed and rebuilt whenever the source or the device
  // changes, and this host outlives that. Holding the source it was constructed
  // with meant the publish timer went on acquiring through a freed handle,
  // thirty times a second, sending 15 kB of returned heap to a tablet as a
  // measurement — for as long as the app stayed open.
  test('a replaced source is what gets published', () async {
    source
      ..generation = 1
      ..lufsIntegrated = -14.2
      ..isRunning = true;

    await connect();
    await _settle(milliseconds: 200);
    expect(client.snapshot.lufsIntegrated, closeTo(-14.2, 1e-5));

    // The engine the user just switched to.
    final replacement = _FakeSource()
      ..generation = 99
      ..lufsIntegrated = -23.0
      ..sampleRate = 44100
      ..isRunning = true;
    host.source = replacement;

    await _settle(milliseconds: 200);
    expect(client.snapshot.lufsIntegrated, closeTo(-23.0, 1e-5));
    expect(client.snapshot.sampleRate, 44100);
  });

  test('no source publishes nothing rather than the last frame', () async {
    source
      ..generation = 1
      ..lufsIntegrated = -14.2
      ..isRunning = true;

    await connect();
    await _settle(milliseconds: 200);
    final seen = client.snapshot.generation;

    // An engine that failed to open — a declined microphone permission, an
    // interface unplugged. There is nothing being measured, so there is nothing
    // honest to send; the display goes stale and says so rather than holding a
    // detailed picture of a source that no longer exists.
    host.source = null;
    source.generation = 2;

    await _settle(milliseconds: 200);
    expect(
      client.snapshot.generation,
      seen,
      reason: 'a host with no source must not publish',
    );
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
      ..publishCalibration(calibration)
      ..publishDynamicsNaming(DynamicsNaming.odr);

    await connect();

    expect(client.layout.value?.name, 'Mastering');
    expect(client.layout.value?.tabs.single.modules.single.id, 'a');
    expect(
      client.layout.value?.tabs.single.modules.single.kind,
      ModuleKind.lufsMeter,
    );
    expect(client.calibration.value.id, calibration.id);
    // The names too, replayed to a display that joined after they were set:
    // a tablet printing `PSR` under a desktop printing `ODR-S` is the
    // disagreement the frame exists to prevent.
    expect(client.dynamicsNaming.value, DynamicsNaming.odr);

    // The built-in skin travels as an empty payload, which the display reads as
    // "use the default" rather than as a missing frame.
    expect(client.skin.value, isNull);
  });

  test(
    'the dynamics names follow the host, and start at the default',
    () async {
      await connect();
      // A host that has said nothing — or one that predates the frame — leaves
      // the display on the default, which is what such a host prints itself.
      expect(client.dynamicsNaming.value, DynamicsNaming.defaultNaming);

      host.publishDynamicsNaming(DynamicsNaming.odr);
      await _settle();
      expect(client.dynamicsNaming.value, DynamicsNaming.odr);

      host.publishDynamicsNaming(DynamicsNaming.psr);
      await _settle();
      expect(client.dynamicsNaming.value, DynamicsNaming.psr);
    },
  );

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

  // --- The DAW's playhead, one hop further than it used to go --------------
  //
  // The desktop decodes transport off a plugin's socket and forwards it here.
  // Everything below is about that relay rather than about the codec, which
  // `packages/oaa_wire` holds: what reaches a tablet, what does not go on the
  // wire at all, and the one bit that cannot simply be sampled.

  // Written for the theme editor: dragging a colour in it produces a new skin
  // per pointer move, and `_RemoteClient.sendOnce` is documented as being for
  // frames that are rare and must not be dropped — they queue behind whatever
  // flush is outstanding. Sixty of those a second is the `_waiting` list
  // growing for as long as somebody holds the pointer down.
  group('a skin dragged rather than chosen', () {
    Skin tinted(int argb) => BuiltInSkins.precisionInstrument
        .resolved()
        .copyWith(id: 'drag', name: 'Drag', colors: {SkinColor.accent: argb})
        .resolved();

    test('a burst is a handful of frames, and ends on the last one', () async {
      await connect();

      var seen = 0;
      void count() => seen++;
      client.skin.addListener(count);
      addTearDown(() => client.skin.removeListener(count));

      // Fifty distinct palettes with no pause between them: about a second of
      // dragging, arriving as fast as the editor can produce it.
      for (var i = 0; i < 50; i++) {
        host.publishSkin(tinted(0xFF000000 | i));
      }
      await _settle();

      // Un-throttled this is fifty. The exact number depends on how many
      // cooldowns elapse while the loop runs, which is why the assertion is an
      // order of magnitude rather than a count.
      expect(seen, lessThan(10));
      expect(seen, greaterThan(0));

      // And the display is on the *last* colour, not on whichever one the timer
      // happened to catch. A tablet that is behind is tolerable; a tablet that
      // is quietly wrong is not.
      await Future<void>.delayed(DisplayHost.skinInterval * 3);
      await _settle();
      expect(client.skin.value?.colors[SkinColor.accent], 0xFF000031);
    });

    test('a single change still lands immediately', () async {
      await connect();

      host.publishSkin(tinted(0xFFFF8800));
      await _settle();
      expect(client.skin.value?.colors[SkinColor.accent], 0xFFFF8800);
    });

    test(
      'a display that joins mid-drag gets the colour on screen now',
      () async {
        await connect();

        for (var i = 0; i < 20; i++) {
          host.publishSkin(tinted(0xFF000000 | i));
        }

        // Not the last one broadcast — the last one published. The replay path
        // reads the field, which is assigned on every call.
        final joiner = DisplayClient(staleAfter: const Duration(seconds: 1));
        addTearDown(() async {
          await joiner.disconnect();
          joiner.dispose();
        });
        await joiner.connect('127.0.0.1', host.port!);
        await _settle();

        expect(joiner.skin.value?.colors[SkinColor.accent], 0xFF000013);
      },
    );
  });

  group('the transport', () {
    const parked = Transport(
      flags:
          Transport.flagHasTimeSeconds |
          Transport.flagHasBpm |
          Transport.flagHasTimeSig,
      timeSeconds: 61.5,
      bpm: 128,
      timeSigNumerator: 7,
      timeSigDenominator: 8,
    );

    test('reaches a display', () async {
      await connect();

      host.transport = parked;
      await _settle();

      expect(client.transport.value.hasBpm, isTrue);
      expect(client.transport.value.bpm, closeTo(128, 1e-9));
      expect(client.transport.value.timeSigNumerator, 7);
      expect(client.transport.value.timeSigDenominator, 8);
      expect(client.transport.value.timeSeconds, closeTo(61.5, 1e-9));
      expect(client.transport.value.isPlaying, isFalse);
    });

    test('a host with no playhead sends none, not a zeroed one', () async {
      await connect();
      await _settle();

      // `flags == 0` is the difference between "parked at bar 1, 120 bpm" and
      // "no DAW here", and it is the whole reason the frame carries presence
      // bits. A display that had been handed zeroes would draw the first.
      expect(client.transport.value.isPresent, isFalse);
      expect(client.transport.value, Transport.none);
    });

    test('a display that joins mid-session gets the position', () async {
      // Transport goes out on change, so a tablet that attaches to a session
      // parked at bar 57 would see nothing at all until somebody touched the
      // DAW — which is exactly when they are not looking at the tablet.
      host.transport = parked;
      await _settle();

      await connect();

      expect(client.transport.value.timeSeconds, closeTo(61.5, 1e-9));
    });

    test('a playhead that goes away says so at once', () async {
      await connect();
      host.transport = parked;
      await _settle();
      expect(client.transport.value.isPresent, isTrue);

      // The plugin was removed from the DAW. The app has no source and nothing
      // to publish — and that is precisely when a display must be told, rather
      // than holding bar 57 on screen until the link itself goes stale two
      // seconds later.
      host
        ..source = null
        ..transport = Transport.none;
      await _settle();

      expect(client.transport.value, Transport.none);
    });

    test('an edge between two frames is carried, not lost', () async {
      await connect();
      await _settle();

      // The case `docs/WIRE.md` spells out: DISCONTINUITY is an edge delivered
      // once, and this host publishes thirty times a second against a DAW's
      // ninety-odd blocks. Somebody drags the playhead back to bar 1 and
      // playback continues, so the jump arrives on one producer frame and the
      // two after it are ordinary — a relay that answered "what is the playhead
      // now?" on its own schedule would report a position that moved and no
      // relocation at all, and a display cannot count what it is never told.
      host
        ..transport = parked.asDiscontinuous()
        ..transport = const Transport(
          flags: Transport.flagPlaying | Transport.flagHasTimeSeconds,
          timeSeconds: 0.1,
        );
      await _settle();

      expect(
        client.transport.value.isDiscontinuous,
        isTrue,
        reason: 'the relocate was dropped on the way to the display',
      );
      expect(
        client.transport.value.timeSeconds,
        closeTo(0.1, 1e-9),
        reason: 'the flag belongs to the position the playhead landed on',
      );

      // And it is an edge here too: the next frame does not repeat it.
      host.transport = const Transport(
        flags: Transport.flagPlaying | Transport.flagHasTimeSeconds,
        timeSeconds: 0.2,
      );
      await _settle();

      expect(client.transport.value.isDiscontinuous, isFalse);
      expect(client.transport.value.timeSeconds, closeTo(0.2, 1e-9));
    });

    test('goes to nothing when the link goes quiet', () async {
      await connect();
      host.transport = parked;
      await _settle();
      expect(client.transport.value.isPresent, isTrue);

      await host.stop();
      await _settle(milliseconds: 700);

      // A parked transport legitimately sends nothing for minutes, so a held
      // position and a dead link look identical on screen. The meters go to
      // dashes here; the playhead has to go with them.
      expect(client.transport.value, Transport.none);
    });
  });

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
          ..add(Uint8List.sublistView(frame.wire, 0, 6000));
        Future<void>.delayed(const Duration(milliseconds: 60), socket.destroy);
        return;
      }

      socket.add(hello);
      final pump = Timer.periodic(const Duration(milliseconds: 30), (timer) {
        try {
          socket.add(frame.wire);
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

  test(
    'a layout published mid-frame arrives rather than dropping the display',
    () async {
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
    },
  );

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
  Transport transport = Transport.none;

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
  double crestFactor = double.nan;

  @override
  double odrIntegrated = double.nan;

  @override
  double odrShort = double.nan;

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
  Float32List spectrumOf(SpectrumSource source) => spectrum;

  @override
  Float32List spectrumPeakOf(SpectrumSource source) => spectrumPeak;

  @override
  final Float32List scope = Float32List(MeterShape.scopePoints * 2);

  @override
  int scopeFrames = MeterShape.scopePoints;

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  @override
  bool refresh() => true;
}
