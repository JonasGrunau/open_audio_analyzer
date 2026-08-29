/// The whole path, end to end: a file, the plugin, a socket, this decoder.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// `plugin_golden_test.dart` proves the two implementations of the protocol
/// agree about a frame that was written to disk once. It says nothing about
/// whether a running plugin ever sends one — the golden is produced by a
/// fixture that links `OaaWire.cpp` and no JUCE at all, so every part of the
/// real path is outside it: `prepareToPlay`, the FIFO, the playhead, the engine,
/// the streaming thread, the socket, the reconnect.
///
/// This test drives that path. `plugin/host/` builds a host — the fake DAW —
/// which loads the VST3 the way a DAW does, plays an audio file through it and
/// gives it a transport, with no window and no sound card. The test listens on
/// an ephemeral port, tells the host to point the plugin at it, and asserts on
/// what arrives.
///
/// It needs one thing that is not in the repository, and skips rather than fails
/// without it — a suite that cannot run on a clean clone is a suite people stop
/// running:
///
///   cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
///   cmake --build plugin/build
///
/// The audio it plays is generated, not downloaded. A CI runner fetching 35 MB
/// of music from somebody else's CDN to prove that a socket carries frames is a
/// gate that fails for reasons unrelated to this repository, and the assertions
/// here are ranges rather than values, so real music buys nothing. Point
/// `OAA_TEST_TRACK` at a file to run the same cases against one — which is what
/// `tool/fetch_test_audio.dart` downloads for, and what a person looking at the
/// application should use.
///
/// `OAA_FAKE_DAW` overrides the search for the executable.
///
/// It also needs port 47822, and there is no switch to move it. The plugin's
/// destination is the plugin's own setting — changed in its editor, saved into
/// a session — and a host cannot inject one: JUCE's VST3 host wraps plugin
/// state in an XML envelope of its own, so the raw blob a DAW would hand over
/// is silently discarded, and the Audio Unit host wraps it differently again.
/// Rather than keep a copy of two of JUCE's internal formats in a test tool,
/// this listens where the application listens. The consequence is that the
/// application cannot be running while this test does, and the skip below says
/// so instead of failing with a bind error nobody can read.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
import 'package:test/test.dart';

/// Everything one run of the host produced.
class _Session {
  _Session(
    this.hello,
    this.transports,
    this.snapshot,
    this.snapshotFrames,
    this.scopeRuns,
  );

  final WireHello? hello;
  final List<Transport> transports;

  /// Decoded in place, frame after frame, so this holds the last one — which is
  /// what a display would be showing.
  final WireSnapshot snapshot;
  final int snapshotFrames;

  /// Per snapshot frame, in order: the engine clock it was stamped with and
  /// how many stereo pairs of audio its scope run carried. Together they say
  /// whether the audio crossed the wire whole — see the block-size group.
  final List<_ScopeRun> scopeRuns;
}

typedef _ScopeRun = ({double elapsed, int frames, int sampleRate});

/// The port the plugin streams to unless its editor says otherwise, and the
/// port the application listens on. `plugin/src/OaaStreamer.h` is where it is
/// defined; this is the third copy of the number and the only one in Dart, so
/// it is named rather than inlined.
const int _pluginPort = 47822;

void main() {
  final binary = _findFakeDaw();

  final String? skip = binary == null
      ? 'The fake DAW is not built. See the header of this file.'
      : null;

  tearDownAll(_discardGeneratedTrack);

  group('the plugin, hosted', () {
    // Null when port 47822 was already taken. `_run` explains that once; every
    // test here then reports itself skipped rather than failing on an empty
    // session, because a developer with the application open has broken
    // nothing.
    _Session? rolling;

    setUpAll(() async {
      if (skip != null) return;

      // Six seconds of transport time at twice real time: long enough for the
      // 3 s short-term window to fill and for a few hundred frames to arrive,
      // short enough that nobody deletes the test for being slow.
      rolling = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--bpm=128',
        '--time-sig=7/8',
        '--frame-rate=25',
        '--seconds=6',
        '--speed=2',
      ]);
    });

    test('says hello, and this build agrees with it', () {
      final session = _required(rolling);
      if (session == null) return;

      expect(session.hello, isNotNull);

      // The handshake is refused on payload size, so a plugin built against a
      // different snapshot layout fails here rather than drawing wrong numbers.
      expect(session.hello!.incompatibility, isNull);
      expect(session.hello!.protocolVersion, WireFrame.protocolVersion);
      expect(session.hello!.snapshotPayloadBytes, SnapshotWire.payloadBytes);
    });

    test('streams frames for the whole run', () {
      final session = _required(rolling);
      if (session == null) return;

      // The engine publishes at roughly 47 Hz — one snapshot per 1024-frame
      // push — so six seconds of audio is a few hundred frames. The floor is
      // deliberately far below that: this asserts "the link carried a stream",
      // not a rate, because a loaded CI runner is allowed to drop frames and
      // the plugin counts them when it does.
      expect(session.snapshotFrames, greaterThan(50));
      expect(session.transports, isNotEmpty);
    });

    test('measures the audio it was given', () {
      final session = _required(rolling);
      if (session == null) return;

      final snapshot = session.snapshot;

      expect(snapshot.sampleRate, greaterThan(0));
      expect(snapshot.channels, 2);
      expect(snapshot.elapsedSeconds, greaterThan(1.0));

      // Real music, so every one of these is a number rather than a dash. What
      // is asserted is the range no master can be outside of, not a value —
      // pinning a value here would make this a conformance test of the engine,
      // which `packages/oaa_engine` already is against signals whose answer is
      // known.
      expect(snapshot.hasLoudness, isTrue);
      expect(snapshot.lufsIntegrated, _isFiniteBetween(-70, 0));
      expect(snapshot.lufsShort, _isFiniteBetween(-70, 0));
      expect(snapshot.truePeakMax, _isFiniteBetween(-70, 6));
      expect(snapshot.samplePeakMax, _isFiniteBetween(-70, 0));

      expect(snapshot.hasSpectrum, isTrue);

      // Version 5: the per-source spectra, measured on a two-channel file
      // and so every one of them a number rather than the NaN code. Left,
      // right and mid carry the tone; side is whatever the file's two
      // channels disagree by, which is a measurement even when it is the
      // floor.
      for (final source in SpectrumSource.values) {
        expect(
          snapshot.spectrumOf(source).every((band) => !band.isNaN),
          isTrue,
          reason: '${source.id} arrived as not measured on a stereo file',
        );
        expect(
          snapshot.spectrumPeakOf(source).every((band) => !band.isNaN),
          isTrue,
          reason: '${source.id} hold arrived as not measured',
        );
      }
      for (final source in [
        SpectrumSource.left,
        SpectrumSource.right,
        SpectrumSource.mid,
      ]) {
        expect(
          snapshot.spectrumOf(source).any((band) => band > -120.0),
          isTrue,
          reason: '${source.id} is nothing but floor',
        );
      }
    });

    test('reports the transport the host actually set', () {
      final session = _required(rolling);
      if (session == null) return;

      final rolled = session.transports.where((t) => t.isPlaying).toList();
      expect(
        rolled,
        isNotEmpty,
        reason: 'no frame reported a rolling transport',
      );

      final transport = rolled.last;

      expect(transport.hasBpm, isTrue);
      expect(transport.bpm, closeTo(128.0, 0.001));

      expect(transport.hasTimeSignature, isTrue);
      expect(transport.timeSigNumerator, 7);
      expect(transport.timeSigDenominator, 8);

      expect(transport.hasTimecode, isTrue);
      expect(transport.frameRate.wireValue, 2, reason: '25 fps is wire code 2');

      expect(transport.hasTimeSeconds, isTrue);
      expect(transport.hasTimeSamples, isTrue);
      expect(transport.hasPpq, isTrue);
      expect(transport.hasBarStart, isTrue);

      // 7/8 is three and a half quarter notes to the bar, and the bar start has
      // to land on a multiple of that. This is the one place the host's
      // arithmetic and the plugin's transcription of it are checked against
      // each other.
      expect(transport.ppqBarStart % 3.5, closeTo(0.0, 1e-9));
      expect(
        transport.ppqPosition,
        greaterThanOrEqualTo(transport.ppqBarStart),
      );

      // Not recording: the host was not asked to be.
      expect(transport.isRecording, isFalse);
      expect(transport.isLooping, isFalse);
    });

    test('the playhead moves forward', () {
      final session = _required(rolling);
      if (session == null) return;

      final rolled = session.transports.where((t) => t.isPlaying).toList();
      expect(rolled.length, greaterThan(4));

      expect(rolled.last.timeSeconds, greaterThan(rolled.first.timeSeconds));
      expect(rolled.last.ppqPosition, greaterThan(rolled.first.ppqPosition));

      // Ordinary playback is continuous. A frame flagged otherwise here would
      // mean the plugin thinks the host relocated when it did not, which is how
      // an integrated reading gets reset in the middle of a pass.
      expect(rolled.map((t) => t.isDiscontinuous), everyElement(isFalse));
    });
  }, skip: skip);

  group('a host buffer larger than the engine block', () {
    // Every push publishes a snapshot whose scope run is the block just
    // pushed. A 2048-frame host buffer hands the streamer two engine blocks
    // per callback, and the streamer used to drain both and send one — so the
    // first block's audio never crossed the wire, and the app's oscilloscope,
    // which turns the engine clock into a count of frames it should have
    // seen, drew that block as silence: a waveform in bursts with a gap
    // between every pair. Nothing else noticed, because every other reading
    // is an integral and the second push carried it.
    test('every block of audio crosses the wire in its own frame', () async {
      if (skip != null) return;
      final session = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--block=2048',
        '--seconds=3',
        '--speed=2',
      ]);
      if (session == null) return;

      final runs = session.scopeRuns;
      expect(runs.length, greaterThan(20));

      // Between consecutive frames the clock advances by the audio the
      // second one carries — not by twice it. Rounded, because the clock is
      // a double of frames over the sample rate. The first frame has no
      // predecessor, and a frame whose run is at the wire's cap has been
      // relayed rather than pushed, which this host never does.
      var checked = 0;
      for (var i = 1; i < runs.length; i++) {
        final advanced =
            ((runs[i].elapsed - runs[i - 1].elapsed) * runs[i].sampleRate)
                .round();
        if (advanced <= 0) continue; // a reset, or a repeated frame
        expect(
          advanced,
          runs[i].frames,
          reason:
              'frame $i: the clock advanced $advanced frames but the scope '
              'run carried ${runs[i].frames} — the audio between them was '
              'measured and never sent',
        );
        checked++;
      }
      expect(checked, greaterThan(20));
    });
  }, skip: skip);

  group('the transport cases a real DAW is hard to force', () {
    test('a loop wraps the playhead and reports its region', () async {
      // A one-second loop over four seconds of transport time: three laps.
      final session = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--seconds=4',
        '--speed=2',
        '--loop',
        '--loop-start=0',
        '--loop-end=1',
      ]);
      if (session == null) return;

      final rolled = session.transports.where((t) => t.isPlaying).toList();
      expect(rolled, isNotEmpty);
      expect(rolled.map((t) => t.isLooping), everyElement(isTrue));

      // The region, in quarter notes. One second at the default 120 bpm is two
      // of them, so this checks the host's arithmetic and the plugin's
      // transcription of it in one number.
      final withPoints = rolled.where((t) => t.hasLoopPoints).toList();
      expect(
        withPoints,
        isNotEmpty,
        reason: 'the loop region was never reported',
      );
      expect(withPoints.last.loopStartPpq, closeTo(0.0, 1e-9));
      expect(withPoints.last.loopEndPpq, closeTo(2.0, 1e-9));

      // The playhead went backwards, which is what a lap looks like from here.
      final wraps = _backwardSteps(rolled);
      expect(
        wraps,
        greaterThanOrEqualTo(2),
        reason: 'the loop never came round',
      );

      // And never left the region by more than a block.
      expect(rolled.map((t) => t.timeSeconds), everyElement(lessThan(1.5)));

      // One discontinuity per lap, no more and no fewer.
      //
      // Tied to the laps this run actually observed rather than to a constant,
      // because that is the invariant: the flag marks a relocate, so a flagged
      // frame and a lap are the same event counted two ways.
      //
      // This is the assertion the fake DAW was built to make. The plugin raises
      // the flag on the single audio block where the playhead jumps, and the
      // streaming thread reads the transport once per published frame — every
      // other block at a 512-frame buffer, one in sixteen at 64 — so before
      // TransportBox accumulated edge flags outside its seqlock, three laps
      // reached the app zero times out of 186 frames. Missing it is the exact
      // failure the flag exists to prevent: an integrated reading that silently
      // spans two passes of the same music.
      expect(
        rolled.where((t) => t.isDiscontinuous).length,
        wraps,
        reason: 'expected one flagged frame per lap',
      );
    });

    test('a stopped transport is not a relocate', () async {
      // A DAW runs its graph whether or not it is playing, and parked is the
      // state a session spends most of its time in. The position it reports
      // sits still while real time keeps moving.
      //
      // Against a prediction of "one block further on", a frozen position is a
      // mismatch of exactly one block — which clears the plugin's half-block
      // tolerance, so this reported a relocate on every published frame for as
      // long as the transport sat still. Measured before the fix: 140 out
      // of 140.
      final session = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--seconds=3',
        '--speed=4',
        '--parked',
      ]);
      if (session == null) return;

      expect(session.transports, isNotEmpty);
      expect(session.transports.map((t) => t.isPlaying), everyElement(isFalse));
      expect(
        session.transports.map((t) => t.isDiscontinuous),
        everyElement(isFalse),
        reason: 'a transport that never moved cannot have relocated',
      );

      // Frozen rather than drifting: every frame reports the same instant.
      expect(
        session.transports.map((t) => t.timeSeconds).toSet(),
        hasLength(1),
      );
    });

    test('play, stop, jump to the start, play again is reported once', () async {
      // The gesture docs/WIRE.md names as the reason this bit exists: "plays
      // bars 1-16, stops, drags back to bar 1, plays again". A loop wrap
      // relocates while rolling; this relocates across a stop, which reaches
      // the plugin's continuity test by a different path — the prediction has to
      // survive the parked blocks in between rather than being rebuilt from
      // wherever the playhead was left sitting.
      final session = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--seconds=4',
        '--speed=4',
        '--relocate-at=2',
      ]);
      if (session == null) return;

      final transports = session.transports;
      expect(transports, isNotEmpty);

      final parked = transports.where((t) => !t.isPlaying).toList();
      final rolling = transports.where((t) => t.isPlaying).toList();

      expect(parked, isNotEmpty, reason: 'the parked interval never arrived');
      expect(rolling, isNotEmpty);

      // Nothing while parked, exactly one on the way back out.
      expect(parked.map((t) => t.isDiscontinuous), everyElement(isFalse));

      final flagged = transports.where((t) => t.isDiscontinuous).toList();
      expect(flagged, hasLength(1));
      expect(flagged.single.isPlaying, isTrue);
      expect(
        flagged.single.timeSeconds,
        lessThan(0.5),
        reason: 'the flag belongs to the first block of the second pass',
      );

      // And the playhead really did go back to the start, once.
      expect(_backwardSteps(transports), 1);
    });

    test('a host that supplies no position invents nothing', () async {
      final session = await _run(binary!, <String>[
        '--track=${_track().path}',
        '--seconds=2',
        '--speed=4',
        '--no-playhead',
      ]);
      if (session == null) return;

      expect(session.transports, isNotEmpty);

      // Nothing invented to fill the gap. This is the whole reason the wire
      // carries presence bits instead of values with sentinel defaults: the app
      // has to show dashes rather than "bar 1, beat 1, 120 bpm", which is a
      // perfectly plausible thing to show somebody while the host is parked at
      // bar 57.
      for (final transport in session.transports) {
        expect(transport.hasBpm, isFalse);
        expect(transport.hasTimeSignature, isFalse);
        expect(transport.hasTimecode, isFalse);
        expect(transport.hasPpq, isFalse);
        expect(transport.hasBarStart, isFalse);
        expect(transport.hasLoopPoints, isFalse);
        expect(transport.isPlaying, isFalse);
        expect(transport.bpm, 0.0);
      }

      // Time survives, and that is not this host misbehaving — it is the
      // furthest a *format* can go towards saying nothing.
      //
      // `--no-playhead` makes the fake DAW's `getPosition()` return nothing.
      // JUCE's VST3 host then does what the format allows: `toProcessContext`
      // zeroes a `ProcessContext`, fills in the sample rate and leaves every
      // validity flag clear — which is also exactly what it sends for a host
      // holding no playhead at all, so the two are the same bytes. The plugin's
      // own VST3 wrapper reads `timeInSamples` and `timeInSeconds` back out of
      // it unconditionally, because VST3 has no bit for "not saying". So the
      // plugin is told *parked at zero, nothing else valid*, and reporting that
      // is the correct reading of what arrived.
      expect(session.transports.last.hasTimeSeconds, isTrue);
      expect(session.transports.last.timeSeconds, 0.0);

      // Which means the plugin's *empty* transport — the branch behind
      // `getPlayHead() == nullptr` and an empty `getPosition()`, and the reason
      // the application has a dashes state at all — cannot be reached from
      // here, or from any DAW, through either shipping format. It is covered
      // instead by `plugin/test/transport_capture_test.cpp`, which hosts the
      // processor as the C++ object it is: `ctest -R transport_capture`.

      // The audio still went through: withholding a playhead does not stop a
      // meter from metering.
      expect(session.snapshotFrames, greaterThan(10));
      expect(session.snapshot.hasLoudness, isTrue);
    });
  }, skip: skip);
}

/// Reports the test skipped and hands back null when the shared run could not
/// happen, so that a busy port produces one explanation rather than five
/// unrelated-looking failures.
_Session? _required(_Session? session) {
  if (session == null) markTestSkipped(_portBusy(null));
  return session;
}

String _portBusy(Object? error) =>
    'Port $_pluginPort is already in use, so nothing sent by the plugin can be '
    'received here. Close Open Audio Analyzer and run this again.'
    '${error != null ? " ($error)" : ""}';

/// How many times the reported playhead went backwards between consecutive
/// frames — a lap, a relocate, a scrub — counted from the evidence rather than
/// from what the host was asked to do.
int _backwardSteps(List<Transport> transports) {
  var steps = 0;
  for (var i = 1; i < transports.length; i++) {
    if (transports[i].timeSeconds < transports[i - 1].timeSeconds - 1e-9) {
      steps++;
    }
  }
  return steps;
}

Matcher _isFiniteBetween(double low, double high) => predicate<double>(
  (value) => value.isFinite && value >= low && value <= high,
  'a finite dB value between $low and $high',
);

/// Runs the fake DAW once and collects everything the plugin sent.
///
/// The listener is bound before the host is started, so the plugin's first
/// connection attempt succeeds — it does retry with a backoff, but waiting for
/// that would make every case here seconds slower for no coverage.
Future<_Session?> _run(File binary, List<String> arguments) async {
  final ServerSocket server;
  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _pluginPort);
  } on SocketException catch (error) {
    // Almost always Open Audio Analyzer itself, listening for the plugin. That
    // is not a failure of anything being tested, and saying so is more use than
    // an errno.
    markTestSkipped(_portBusy(error));
    return null;
  }

  WireHello? hello;
  final transports = <Transport>[];
  final snapshot = WireSnapshot();
  var snapshotFrames = 0;
  final scopeRuns = <_ScopeRun>[];
  final reader = FrameReader();

  final finished = Completer<void>();

  final subscription = server.listen((socket) {
    socket.listen(
      (chunk) {
        reader.add(chunk);
        while (reader.moveNext()) {
          switch (reader.type) {
            case WireFrameType.hello:
              hello = WireHello.decode(reader.payload);
            case WireFrameType.dawTransport:
              transports.add(DawTransportCodec.decode(reader.payload));
            case WireFrameType.snapshot:
              snapshot.decode(reader.payload, version: reader.version);
              snapshotFrames++;
              scopeRuns.add((
                elapsed: snapshot.elapsedSeconds,
                frames: snapshot.scopeFrames,
                sampleRate: snapshot.sampleRate,
              ));
          }
        }
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object _) {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
  });

  final process = await Process.start(binary.path, <String>[
    '--headless',
    ...arguments,
  ]);

  // Drained rather than ignored: a process whose stdout nobody reads blocks on
  // a full pipe, and the failure looks like a hang in the host.
  final out = StringBuffer();
  final err = StringBuffer();
  final draining = <Future<void>>[
    process.stdout.forEach((bytes) => out.write(String.fromCharCodes(bytes))),
    process.stderr.forEach((bytes) => err.write(String.fromCharCodes(bytes))),
  ];

  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );

  await Future.wait(draining);

  // The socket's own close can arrive after the process is gone; a short wait
  // for it keeps the last frames out of the next test's collection.
  await finished.future.timeout(const Duration(seconds: 2), onTimeout: () {});

  await subscription.cancel();
  await server.close();

  if (exitCode != 0) {
    fail(
      'The fake DAW exited with $exitCode.\n'
      '--- arguments ---\n${arguments.join('\n')}\n'
      '--- stdout ---\n$out\n--- stderr ---\n$err',
    );
  }

  return _Session(hello, transports, snapshot, snapshotFrames, scopeRuns);
}

/// The fake DAW's executable, wherever this build put it.
///
/// Resolved by search rather than by one hard-coded path: the artefact is a
/// bare executable on Linux, an `.exe` in a per-configuration subdirectory on
/// Windows, and the inside of an `.app` bundle on macOS. A single path would be
/// wrong on two platforms out of three.
File? _findFakeDaw() {
  final override = Platform.environment['OAA_FAKE_DAW'];
  if (override != null && override.isNotEmpty) {
    final file = File(override);
    return file.existsSync() ? file : null;
  }

  final root = _repositoryRoot();
  if (root == null) return null;

  final artefacts = Directory(
    '${root.path}/plugin/build/host/OaaFakeDaw_artefacts',
  );
  if (!artefacts.existsSync()) return null;

  final wanted = Platform.isWindows ? 'oaa-fake-daw.exe' : 'oaa-fake-daw';

  for (final entity in artefacts.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && entity.uri.pathSegments.last == wanted) return entity;
  }

  return null;
}

Directory? _generatedDirectory;
File? _generatedTrack;

/// The file the host plays: whatever `OAA_TEST_TRACK` names, or a signal written
/// on first use.
///
/// Generated rather than committed and rather than downloaded. Committed audio
/// is megabytes in every clone forever; downloaded audio makes a gate depend on
/// a third-party CDN, which the first host this project used stopped being for
/// hours at a time. And a generated signal is
/// deterministic, which a test would want even if the other two were free.
///
/// It is deliberately not a single sine. A pure tone gives a correlation of
/// exactly one, a spectrum that is one bin wide and a loudness range of zero —
/// all correct, and none of it distinguishes a working analyser from a broken
/// one. Two frequencies per channel with a phase offset, a slow envelope and a
/// little noise produce readings that are merely plausible, which is what the
/// assertions here check.
File _track() {
  final override = Platform.environment['OAA_TEST_TRACK'];
  if (override != null && override.isNotEmpty) {
    final file = File(override);
    if (file.existsSync()) return file;
    fail('OAA_TEST_TRACK points at ${file.path}, which does not exist.');
  }

  final cached = _generatedTrack;
  if (cached != null) return cached;

  final directory = Directory.systemTemp.createTempSync('oaa-fake-daw-e2e-');
  final file = File('${directory.path}/tone.wav');
  file.writeAsBytesSync(_toneWav());

  _generatedDirectory = directory;
  return _generatedTrack = file;
}

void _discardGeneratedTrack() {
  _generatedDirectory?.deleteSync(recursive: true);
  _generatedDirectory = null;
  _generatedTrack = null;
}

/// A 16-bit stereo 48 kHz RIFF file, twelve seconds long.
///
/// Twelve rather than the six the longest case renders, so that nothing here is
/// ever measuring the end of the file by accident — a run that falls off the
/// end stops early, and the failure would look like the socket closing.
Uint8List _toneWav() {
  const rate = 48000;
  const channels = 2;
  const seconds = 12;
  const frames = rate * seconds;
  const bytesPerFrame = channels * 2;

  final random = Random(7); // seeded: a test that is only usually right is not
  final bytes = BytesBuilder(copy: false);

  void u32(int value) => bytes.add(<int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
  void u16(int value) => bytes.add(<int>[value & 0xff, (value >> 8) & 0xff]);

  bytes.add(ascii.encode('RIFF'));
  u32(36 + frames * bytesPerFrame);
  bytes.add(ascii.encode('WAVEfmt '));
  u32(16); // the size of the fmt chunk that follows
  u16(1); // PCM, uncompressed
  u16(channels);
  u32(rate);
  u32(rate * bytesPerFrame); // byte rate
  u16(bytesPerFrame); // block align
  u16(16); // bits per sample
  bytes.add(ascii.encode('data'));
  u32(frames * bytesPerFrame);

  final samples = Int16List(frames * channels);
  for (var frame = 0; frame < frames; frame++) {
    final t = frame / rate;
    final envelope = 0.5 + 0.4 * sin(2 * pi * 0.4 * t);

    final left =
        0.30 * sin(2 * pi * 220.0 * t) +
        0.12 * sin(2 * pi * 1760.0 * t) +
        0.06 * (random.nextDouble() * 2 - 1);
    final right =
        0.28 * sin(2 * pi * 220.0 * t + 0.6) +
        0.10 * sin(2 * pi * 2637.0 * t) +
        0.06 * (random.nextDouble() * 2 - 1);

    samples[frame * 2] = (left * envelope * 32000).round().clamp(-32768, 32767);
    samples[frame * 2 + 1] = (right * envelope * 32000).round().clamp(
      -32768,
      32767,
    );
  }

  bytes.add(samples.buffer.asUint8List());
  return bytes.takeBytes();
}

/// Walks up from the working directory looking for the repository root.
///
/// The same reasoning as `plugin_golden_test.dart`: this suite is run both from
/// the repository root and from inside this package, and `Platform.script`
/// under `dart test` points at a generated kernel file somewhere else entirely.
Directory? _repositoryRoot() {
  var directory = Directory.current;

  for (var depth = 0; depth < 6; depth++) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/plugin').existsSync()) {
      return directory;
    }

    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  return null;
}
