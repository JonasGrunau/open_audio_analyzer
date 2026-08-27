// SPDX-License-Identifier: GPL-3.0-or-later
//
// The whole path, both hops: a DAW's audio ends up on a tablet.
//
// ---------------------------------------------------------------------------
// Why this exists when two suites already cover the halves
//
// Getting a plugin's meters onto an iPad is two links, in opposite directions,
// and each already has a suite:
//
//   47822  a plugin publishes, the app accepts     `plugin_link_test.dart`,
//                                                  `packages/oaa_wire/test/plugin_e2e_test.dart`
//   47821  the app publishes, a tablet connects    `remote_display_test.dart`
//
// Nothing covered the *join*. The app does not forward a frame — it hands
// `DisplayHost` a `MeterSource`, and when a plugin is active that source is the
// plugin session's `WireSnapshot`, so the tablet's frame is a fresh encode of a
// snapshot the app itself decoded. That is a re-encode of decoded data, and it
// is the kind of thing that works until one field is dropped in the middle:
// both halves keep passing, and the tablet quietly shows a dash where the
// desktop shows a number. So the assertion here is not "frames arrive" — it is
// **the tablet's readings are the same values the app got from the plugin**,
// compared field by field.
//
// It is a real VST3 in a real host: `plugin/host/` plays a file through the
// plugin the way a DAW does, with a moving playhead and no sound card. Nothing
// between the file and the display is a fake — two TCP sockets, three encodes,
// two decodes.
//
// ---------------------------------------------------------------------------
// What it is not
//
// **It wires the app's one line rather than running the app.** `oaa_app.dart`
// sets `_remote.source = _plugins.active?.snapshot ?? engine` when a plugin
// arrives or leaves; this test does the same by hand, because the application
// wants an engine, a config directory and a widget tree, and a `testWidgets`
// body cannot await a subprocess in the first place. The risk that leaves is
// that line drifting — `plugin_ingest_test.dart` is what holds the app-side
// wiring, and this holds the protocol path it feeds.
//
// It needs the plugin built, and skips rather than fails without it:
//
//   cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
//   cmake --build plugin/build
//
// It also needs port 47822, for the reason given at length in
// `packages/oaa_wire/test/plugin_e2e_test.dart`: the plugin's destination is a
// setting inside the plugin, a host cannot inject one, so this listens where the
// application listens — and therefore cannot run while the application does.
// `OAA_FAKE_DAW` overrides the search for the executable, `OAA_TEST_TRACK` the
// signal it plays.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/plugin/plugin_link.dart';
import 'package:oaa/src/remote/display_client.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa_core/oaa_core.dart';

void main() {
  final binary = _findFakeDaw();

  final String? skip = binary == null
      ? 'The plugin and the fake DAW are not built. See the header of this file.'
      : null;

  tearDownAll(_discardGeneratedTrack);

  test(
    'a DAW\'s meters reach a display through the app',
    () async {
      // --- The app's two ends ------------------------------------------------
      //
      // The ingest port is fixed at 47822 and the display port is asked of the
      // OS, which is the asymmetry of the real thing: the plugin dials a number
      // it holds, and a tablet is told where to dial.
      final link = PluginLink();
      await link.start();

      if (!link.isListening) {
        markTestSkipped(
          'Port $kPluginLinkPort is already in use, so nothing the plugin sends '
          'can be received here. Close Open Audio Analyzer and run this again. '
          '(${link.failure.value})',
        );
        link.dispose();
        return;
      }

      final host = DisplayHost(
        // Null until a plugin connects, exactly as in the application: an app
        // with no engine and no plugin is measuring nothing, and publishes
        // nothing.
        source: null,
        hostName: 'Relay Host',
        // Carried in the handshake for bug reports and used to decide nothing —
        // the snapshot payload size is what refuses an incompatible peer.
        abiVersion: 0,
      );

      // The two lines from `oaa_app.dart`. Everything this test is about
      // happens because of them.
      link.addListener(() {
        host
          ..source = link.active?.snapshot
          ..transport = link.active?.transport ?? Transport.none;
      });

      // Transport cannot ride on the listener above: it arrives per audio block
      // and the relay has to see every frame, because
      // `Transport.flagDiscontinuity` is an edge delivered once. Sampling it at
      // the publish rate would lose two jumps in three — see
      // `PluginLink.onTransport`.
      link.onTransport = (session, transport) {
        if (identical(session, link.active)) host.transport = transport;
      };

      final client = DisplayClient();

      try {
        await host.start(port: 0);

        // A display that joins with no layout gets numbers and nowhere to draw
        // them, so the host replays both to every client that attaches.
        host.publishLayout(defaultPreset());
        host.publishCalibration(BuiltInCalibrations.fallback);

        await client.connect('127.0.0.1', host.port!);
        await _settle(milliseconds: 200);

        expect(client.state.value, RemoteLinkState.live);
        expect(client.hostName.value, 'Relay Host');
        expect(
          client.layout.value?.name,
          defaultPreset().name,
          reason: 'the tablet has nothing to draw the measurements in',
        );

        // --- The DAW ---------------------------------------------------------
        //
        // Twelve seconds of transport at twice real time: long enough for the
        // 3 s short-term window to fill, and with enough left after that for the
        // comparison below to happen while the plugin is still connected.
        final process = await Process.start(binary!.path, <String>[
          '--headless',
          '--track=${_track().path}',
          '--bpm=128',
          // Both stated so the readout's two hardest fields are exercised: a
          // meter that is not 4/4 — where a beat is an eighth rather than a
          // quarter — and a frame rate, without which there is no timecode to
          // relay at all.
          '--time-sig=7/8',
          '--frame-rate=25',
          '--seconds=12',
          '--speed=2',
        ]);

        // Drained rather than ignored: a process whose stdout nobody reads
        // blocks on a full pipe, and that presents as a hang in the host.
        final out = StringBuffer();
        final err = StringBuffer();
        final draining = <Future<void>>[
          process.stdout.forEach((b) => out.write(String.fromCharCodes(b))),
          process.stderr.forEach((b) => err.write(String.fromCharCodes(b))),
        ];

        // Waited for on measured audio, not on the link being up.
        //
        // A plugin streams from the moment it is instantiated, and a DAW that
        // has not been told to play yet is sending real frames of nothing: the
        // loudness flag is set — this build does compute loudness — while every
        // window is still empty, so the readings are NaN. That is the honest
        // state and it passes any "is a frame arriving" test, which is what
        // makes it the wrong thing to synchronise on. Short-term needs 3 s of
        // transport, so this waits for that to have filled.
        final playing = await _waitUntil(() {
          final produced = link.active?.snapshot;
          return produced != null &&
              produced.elapsedSeconds > 3.0 &&
              produced.lufsShort.isFinite &&
              produced.truePeakMax.isFinite;
        }, timeout: const Duration(seconds: 40));

        final session = link.active;

        if (!playing || session == null) {
          process.kill(ProcessSignal.sigkill);
          await Future.wait(draining);
          fail(
            'The plugin never delivered a measurement: connected='
            '${link.active != null}, elapsed='
            '${link.active?.snapshot.elapsedSeconds}, short-term='
            '${link.active?.snapshot.lufsShort}.\n'
            '--- stdout ---\n$out\n--- stderr ---\n$err',
          );
        }

        // The display got there by the publish loop, before anything below
        // forces a frame out of it. Without this the forced publish alone could
        // carry the whole test, and a tablet does not live on forced publishes.
        expect(
          client.snapshot.generation,
          greaterThan(20),
          reason: 'the display was not being published to',
        );
        // And it is at most one tick behind: the wait above returns the instant
        // the *app* has a short-term reading, which is up to a publish period
        // before the display can have been told. Anything longer than a couple
        // of frames here is a publish loop that has stopped following its
        // source.
        final caughtUp = await _waitUntil(
          () => client.snapshot.lufsShort.isFinite,
          timeout: const Duration(seconds: 2),
        );
        expect(
          caughtUp,
          isTrue,
          reason: 'the publish loop was not carrying the plugin\'s readings',
        );

        // --- And the DAW's playhead came with them ---------------------------
        //
        // The hop this test was written without. Measurements and transport
        // travel in different frames and only the first one used to be
        // forwarded, so a tablet showed a plugin's meters beside no position at
        // all — while the desktop had the position in hand, decoded, and threw
        // it away.
        final shownTransport = client.transport.value;
        final producedTransport = session.transport;

        expect(
          producedTransport.isPresent,
          isTrue,
          reason: 'the fake DAW supplied no playhead to relay',
        );
        expect(
          shownTransport.isPresent,
          isTrue,
          reason: 'the playhead stopped at the desktop',
        );

        // What the host was told to be, arriving on a screen two hops away.
        expect(shownTransport.isPlaying, isTrue);
        expect(shownTransport.hasBpm, isTrue);
        expect(shownTransport.bpm, closeTo(128, 1e-6));
        expect(shownTransport.timeSigNumerator, 7);
        expect(shownTransport.timeSigDenominator, 8);
        expect(shownTransport.hasTimecode, isTrue);
        expect(shownTransport.frameRate, TimecodeFrameRate.fps25);

        // Rendered, not just carried: a display draws these two, and both are
        // arithmetic over several fields that a relay could scramble without
        // any of the numbers above looking wrong.
        expect(shownTransport.timecode, isNotNull);
        expect(shownTransport.barAndBeat, isNotNull);
        expect(shownTransport.barAndBeat!.bar, greaterThan(1));

        // Within a publish period of the app's own reading. Not equal: the
        // playhead moves on every audio block and goes out thirty times a
        // second, so the display is always slightly behind — the assertion is
        // that it is *following*, which a frozen or a replayed-from-the-start
        // position would not be.
        expect(
          (shownTransport.timeSeconds - producedTransport.timeSeconds).abs(),
          lessThan(0.5),
          reason:
              'the display is at ${shownTransport.timeSeconds}s and the app at '
              '${producedTransport.timeSeconds}s',
        );

        // And it is moving. A relay that sent one frame and stopped passes
        // everything above.
        await _settle(milliseconds: 300);
        expect(
          client.transport.value.timeSeconds,
          greaterThan(shownTransport.timeSeconds),
          reason: 'the playhead on the display is not advancing',
        );

        // The oscilloscope reaches the display at all. Asserted here, while
        // frames are still arriving, rather than after the freeze below: the
        // frozen frame may carry an empty run for a reason that is the
        // protocol working, and without this that exception could hide a scope
        // that never relays anything.
        final scopeArrived = await _waitUntil(
          () => client.snapshot.scopeFrames > 0,
        );
        expect(
          scopeArrived,
          isTrue,
          reason: 'no frame the display decoded carried any scope audio',
        );

        // --- What the display is showing is what the app received ------------
        //
        // Frozen deliberately, and the freeze is the whole trick. Both sides
        // are moving thirty times a second, so the comparison is made against
        // one measurement that is known to be the last thing on the wire:
        //
        //   * no `await` between reading the app's snapshot and publishing it,
        //     so no frame can arrive from the plugin and no timer tick can
        //     publish in between;
        //   * `source = null` immediately after, so nothing follows it — the
        //     last frame the display decodes is the one just read.
        //
        // The settle before it lets the buffer ring drain, so the publish has a
        // free slot and is not the frame that gets dropped.
        await _settle(milliseconds: 150);

        final produced = _readings(session.snapshot);
        final producedFlags = _flags(session.snapshot);
        host.publishNow();
        host.source = null;

        await _settle(milliseconds: 250);

        // Two snapshots of nothing but NaN agree perfectly, so the comparison
        // below is only worth anything if there is something in it to compare.
        // All twenty-nine are measured on this signal; the bound is loose so
        // that a metric this build stops computing does not read as a relay
        // failure.
        expect(
          produced.values.where((value) => value.isFinite).length,
          greaterThan(20),
          reason: 'too few readings to prove anything crossed the hop',
        );

        final shown = _readings(client.snapshot);
        final shownFlags = _flags(client.snapshot);

        for (final field in produced.keys) {
          final ours = produced[field]!;
          final theirs = shown[field]!;

          if (ours.isNaN) {
            // NaN is the absence of a measurement and it has to survive the
            // hop as an absence: a dash on the desktop must be a dash on the
            // tablet, not a zero.
            expect(
              theirs.isNaN,
              isTrue,
              reason: '$field is unmeasured here and $theirs on the display',
            );
          } else if (theirs.isNaN && field.startsWith('scope[')) {
            // The one absence on the display that is not a relay failure. The
            // app's scope is a fixed block and always full; the display's is
            // the run measured between two sends, and `publishNow` here can
            // land between two of the engine's generations — so the frame that
            // is frozen for this comparison legitimately carries no audio to
            // compare. That the scope relays at all is asserted above, while
            // frames are still arriving.
          } else {
            // Exact, not close. Both sides hold what a float32 decoded to, so
            // a re-encode is lossless and anything but equality is a field
            // going through the middle wrong.
            expect(
              theirs,
              ours,
              reason: '$field is $ours here and $theirs on the display',
            );
          }
        }

        expect(shownFlags, producedFlags);

        // --- And it is a real measurement, not a well-relayed nothing --------
        //
        // Every assertion above would pass if the plugin sent silence and the
        // relay carried it perfectly, so the signal has to be shown to have
        // been measured at all.
        expect(client.snapshot.hasLoudness, isTrue);
        expect(client.snapshot.sampleRate, greaterThan(0));
        expect(client.snapshot.channels, 2);
        expect(client.snapshot.isRunning, isTrue);
        expect(client.snapshot.lufsMomentary, _isFiniteBetween(-60.0, 0.0));
        expect(client.snapshot.lufsShort, _isFiniteBetween(-60.0, 0.0));
        expect(client.snapshot.truePeakMax, _isFiniteBetween(-60.0, 3.0));
        expect(
          client.snapshot.elapsedSeconds,
          greaterThan(0.0),
          reason: 'the transport moved, so the plugin has measured for a while',
        );
        expect(
          client.snapshot.spectrum.any((bin) => bin.isFinite && bin > -120.0),
          isTrue,
          reason: 'a spectrum of nothing but floor is not a relayed spectrum',
        );

        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        await Future.wait(draining);

        if (exitCode != 0) {
          fail(
            'The fake DAW exited with $exitCode.\n'
            '--- stdout ---\n$out\n--- stderr ---\n$err',
          );
        }

        // The plugin's socket closing hands the selection back, and the app
        // stops publishing rather than going on encoding a session that is
        // gone.
        await _waitUntil(() => link.active == null);
        expect(link.sessions, isEmpty);
      } finally {
        await client.disconnect();
        client.dispose();
        await host.stop();
        host.dispose();
        await link.stop();
        link.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Every scalar a module can read, by name, so that a field lost in the middle
/// says which one it was.
Map<String, double> _readings(MeterSource source) => <String, double>{
  'elapsedSeconds': source.elapsedSeconds,
  'lufsMomentary': source.lufsMomentary,
  'lufsShort': source.lufsShort,
  'lufsIntegrated': source.lufsIntegrated,
  'loudnessRange': source.loudnessRange,
  'loudnessRangeLow': source.loudnessRangeLow,
  'loudnessRangeHigh': source.loudnessRangeHigh,
  'loudnessRangeGate': source.loudnessRangeGate,
  'truePeak': source.truePeak,
  'truePeakMax': source.truePeakMax,
  'samplePeakMax': source.samplePeakMax,
  'dynamicRangeShort': source.dynamicRangeShort,
  'dynamicRangeIntegrated': source.dynamicRangeIntegrated,
  'crestFactor': source.crestFactor,
  'peakToLoudnessRatio': source.peakToLoudnessRatio,
  'peakToShortTermRatio': source.peakToShortTermRatio,
  'correlation': source.correlation,
  'balance': source.balance,
  'peak[0]': source.peak[0],
  'peak[1]': source.peak[1],
  'rms[0]': source.rms[0],
  'rms[1]': source.rms[1],
  'vu[0]': source.vu[0],
  'spectrum[64]': source.spectrum[64],
  'spectrum[256]': source.spectrum[256],
  'spectrumPeak[256]': source.spectrumPeak[256],
  'spectrumPan[256]': source.spectrumPan[256],
  // The **newest** pair, not the oldest. The app relays a scope run that
  // accumulates every block it measured between two sends, so the display's
  // `scope[0]` is older audio than the app's — by design, and the whole reason
  // a remote oscilloscope can draw a contiguous trace at all. What must match
  // is the leading edge, which is the same moment on both sides.
  'scope[newest].l': _newestScope(source, 0),
  'scope[newest].r': _newestScope(source, 1),
  'histogram[0]': source.histogram[0],
};

/// The leading edge of the scope, or absence where there is no scope to lead.
///
/// `scopeFrames` is a *count*, and on a display it counts what the app measured
/// between two sends rather than the fixed block an engine always has. It is
/// legitimately **zero**: `DisplayHost` clears the run on every send and grows
/// it only when the engine's generation moves, so a publish that lands between
/// two generations carries an empty one, which is the gap that file documents.
///
/// Indexing it regardless is `scope[-2]`, and that RangeError failed the
/// v0.13.0 tag run with all sixteen other jobs green — on Linux only, and never
/// twice in a row, because it is a race between a 5 ms pump and a 21 ms engine.
double _newestScope(MeterSource source, int channel) {
  final frames = source.scopeFrames;
  if (frames <= 0) return double.nan;
  return source.scope[(frames - 1) * 2 + channel];
}

/// The non-numeric half of a snapshot. A relay that carried every number and
/// dropped `hasLoudness` would show a screen of dashes over perfect data.
Map<String, Object> _flags(MeterSource source) => <String, Object>{
  'sampleRate': source.sampleRate,
  'channels': source.channels,
  'isRunning': source.isRunning,
  'hasLoudness': source.hasLoudness,
  'hasSpectrum': source.hasSpectrum,
  'droppedFrames': source.droppedFrames,
  'hasOverrun': source.hasOverrun,
};

Matcher _isFiniteBetween(double low, double high) => predicate<double>(
  (value) => value.isFinite && value >= low && value <= high,
  'a finite dB value between $low and $high',
);

/// Lets real sockets, timers and subprocesses make progress.
Future<void> _settle({int milliseconds = 50}) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Polls [condition] until it holds. Returns false on timeout, so the caller
/// can say what was missing rather than dying on an expectation.
Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await _settle(milliseconds: 25);
  }
  return condition();
}

/// The fake DAW's executable, wherever this build put it: a bare executable on
/// Linux, an `.exe` in a per-configuration directory on Windows, and the inside
/// of an `.app` bundle on macOS.
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

Directory? _generatedDirectory;
File? _generatedTrack;

/// The file the host plays: whatever `OAA_TEST_TRACK` names, or a signal written
/// on first use.
///
/// Generated rather than committed or downloaded, for the reasons set out at
/// length in `packages/oaa_wire/test/plugin_e2e_test.dart` — which has its own
/// copy of this, because a test fixture is not a reason for the GPL application
/// suite to reach into an MIT package's test directory.
File _track() {
  final override = Platform.environment['OAA_TEST_TRACK'];
  if (override != null && override.isNotEmpty) {
    final file = File(override);
    if (file.existsSync()) return file;
    fail('OAA_TEST_TRACK points at ${file.path}, which does not exist.');
  }

  final cached = _generatedTrack;
  if (cached != null) return cached;

  final directory = Directory.systemTemp.createTempSync('oaa-relay-e2e-');
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

/// A 16-bit stereo 48 kHz RIFF file, sixteen seconds long — longer than the
/// longest run here, so nothing is ever measuring the end of the file by
/// accident.
///
/// Two frequencies per channel with a phase offset, a slow envelope and a little
/// noise: a pure tone gives a correlation of exactly one, a spectrum one bin
/// wide and a loudness range of zero, all of which a broken analyser reproduces
/// as easily as a working one.
Uint8List _toneWav() {
  const rate = 48000;
  const channels = 2;
  const seconds = 16;
  const frames = rate * seconds;
  const bytesPerFrame = channels * 2;

  final random = Random(11); // seeded: a test that is only usually right is not
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
    final envelope = 0.35 + 0.3 * sin(2 * pi * 0.25 * t);

    final left =
        envelope *
            (0.6 * sin(2 * pi * 220.0 * t) + 0.3 * sin(2 * pi * 1320.0 * t)) +
        0.01 * (random.nextDouble() * 2 - 1);
    final right =
        envelope *
            (0.55 * sin(2 * pi * 220.0 * t + 0.7) +
                0.25 * sin(2 * pi * 3300.0 * t)) +
        0.01 * (random.nextDouble() * 2 - 1);

    samples[frame * 2] = (left.clamp(-1.0, 1.0) * 32767).round();
    samples[frame * 2 + 1] = (right.clamp(-1.0, 1.0) * 32767).round();
  }

  bytes.add(samples.buffer.asUint8List());
  return bytes.takeBytes();
}
