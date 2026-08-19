/// Holds the Dart codec against bytes the C++ plugin actually produced.
///
/// SPDX-License-Identifier: MIT
///
/// The other codec tests in this package round-trip Dart against Dart, which
/// proves the encoder and decoder agree with each other and nothing at all
/// about whether either agrees with the plugin. This one reads
/// `plugin/test/golden/wire_v2.bin` — a file written by `oaa_wire_fixture`,
/// compiled from `plugin/src/OaaWire.cpp` — and asserts the values that went
/// in come back out.
///
/// That is the only test in the repository that would catch the two
/// implementations drifting apart, and the drift is silent: every frame is a
/// fixed length, so a field transcribed into the wrong slot still parses. The
/// app would draw a spectrum out of the scope buffer and look entirely
/// plausible doing it.
///
/// If this fails after a deliberate protocol change, the golden is regenerated
/// — see the header of plugin/test/wire_fixture.cpp. If it fails otherwise, one
/// of the two implementations is wrong and the golden is the evidence.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
import 'package:test/test.dart';

void main() {
  group('the C++ plugin golden', () {
    late FrameReader reader;
    late Transport transport;
    late WireSnapshot snapshot;
    WireHello? hello;

    setUpAll(() {
      // Found by walking up from the working directory rather than resolved
      // against `Platform.script`, which under `dart test` points at a
      // generated kernel file somewhere else entirely. The suite is run both
      // from the repository root (`flutter test`) and from inside this package
      // (`dart test`), and it has to find the fixture either way.
      final bytes = _goldenBytes();

      reader = FrameReader()..add(bytes);
      transport = Transport.none;
      snapshot = WireSnapshot();

      while (reader.moveNext()) {
        switch (reader.type) {
          case WireFrameType.hello:
            hello = WireHello.decode(reader.payload);
          case WireFrameType.dawTransport:
            transport = DawTransportCodec.decode(reader.payload);
          case WireFrameType.snapshot:
            snapshot.decode(reader.payload);
        }
      }
    });

    test('carries three frames of the expected sizes', () {
      // A 32-byte hello block plus a 38-byte UTF-8 name, an 88-byte transport
      // and a 15,056-byte snapshot, each behind a 12-byte envelope.
      final bytes = _goldenBytes().length;
      expect(bytes, (12 + 32 + 38) + (12 + 88) + (12 + 15056));
      expect(bytes, 15250);
    });

    test('agrees with this build about what a frame means', () {
      // The whole point of the handshake. If the plugin and the app disagree
      // about any of these, every byte after the hello means something
      // different to each of them — and nothing about that looks broken on
      // screen, which is why it is checked at connect time and refused.
      expect(hello, isNotNull);
      expect(hello!.incompatibility, isNull);

      expect(hello!.protocolVersion, WireFrame.protocolVersion);
      expect(hello!.snapshotPayloadBytes, SnapshotWire.payloadBytes);
      expect(hello!.maxChannels, MeterShape.maxChannels);
      expect(hello!.spectrumBands, MeterShape.spectrumBands);
      expect(hello!.scopePoints, MeterShape.scopePoints);
      expect(hello!.histogramBins, MeterShape.histogramBins);
    });

    test('accepts a producer whose engine ABI differs from ours', () {
      // The fixture pins ABI 3 while the engine in this tree is on 4, so this
      // is a genuine mismatch rather than a hypothetical one — and it must be
      // accepted. The two numbers move for different reasons: an additive ABI
      // bump leaves every byte of this protocol untouched, and refusing a link
      // that would have worked perfectly is its own kind of wrong answer. The
      // payload size above is the check that catches a real reordering.
      expect(hello!.abiVersion, 3);
      expect(hello!.incompatibility, isNull);
    });

    test('names itself, in UTF-8, without mangling non-ASCII', () {
      // The em dash is three bytes. A length written in characters rather than
      // bytes truncates the name here, which is the cheapest possible place to
      // notice that class of mistake.
      expect(hello!.producerName, 'Open Audio Analyzer plugin — fixture');
    });

    test('decodes the scalar measurements', () {
      expect(snapshot.generation, 0x0123456789ABCDEF);
      expect(snapshot.elapsedSeconds, closeTo(123.456, 1e-9));
      expect(snapshot.sampleRate, 48000);
      expect(snapshot.channels, 2);
      expect(snapshot.droppedFrames, 7);
      expect(snapshot.isRunning, isTrue);

      expect(snapshot.lufsShort, closeTo(-18.5, 1e-5));
      expect(snapshot.lufsIntegrated, closeTo(-14.0, 1e-5));
      expect(snapshot.loudnessRange, closeTo(7.25, 1e-5));
      expect(snapshot.truePeakMax, closeTo(-0.5, 1e-5));
      expect(snapshot.dynamicRangeShort, closeTo(12.5, 1e-5));
      expect(snapshot.loudnessRangeLow, closeTo(-20.0, 1e-5));
      expect(snapshot.loudnessRangeHigh, closeTo(-12.0, 1e-5));
      expect(snapshot.loudnessRangeGate, closeTo(-34.0, 1e-5));
    });

    test('preserves NaN as NaN rather than substituting a number', () {
      // The fixture leaves momentary loudness unmeasured. A codec that
      // normalised this to 0.0 would be reporting −0 LUFS — a legitimate,
      // extremely loud reading — for a measurement nobody took.
      expect(snapshot.lufsMomentary.isNaN, isTrue);
    });

    test('preserves negative infinity rather than clamping to the floor', () {
      // Digital silence. Clamping it to OAA_DB_FLOOR would be a different
      // claim: that something was measured, and it was very quiet.
      expect(snapshot.truePeak, double.negativeInfinity);
    });

    test('places every array in its own slot', () {
      // Each array carries a distinct pattern, so an array serialised into the
      // wrong position is caught rather than merely a wrong length.
      for (var i = 0; i < MeterShape.maxChannels; i++) {
        expect(snapshot.peak[i], closeTo(-i.toDouble(), 1e-5));
        expect(snapshot.rms[i], closeTo(-10.0 - i, 1e-5));
        expect(snapshot.vu[i], closeTo(i * 0.5, 1e-5));
        expect(snapshot.clip[i], i);
      }

      for (var i = 0; i < MeterShape.spectrumBands; i++) {
        expect(snapshot.spectrum[i], closeTo(-(i % 100).toDouble(), 1e-5));
        expect(
          snapshot.spectrumPeak[i],
          closeTo(-(i % 100).toDouble() + 1, 1e-5),
        );
        expect(snapshot.spectrumPan[i], closeTo((i % 3).toDouble() - 1, 1e-5));
      }

      for (var i = 0; i < MeterShape.scopePoints * 2; i++) {
        expect(snapshot.scope[i], closeTo((i % 7) / 7.0 - 0.5, 1e-6));
      }

      for (var i = 0; i < MeterShape.histogramBins; i++) {
        expect(snapshot.histogram[i], closeTo(i / 120.0, 1e-6));
      }
    });

    test('decodes the DAW transport', () {
      expect(transport.isPlaying, isTrue);
      expect(transport.isRecording, isFalse);
      expect(transport.hasTimecode, isTrue);
      expect(transport.frameRate, TimecodeFrameRate.fps2997drop);
      expect(transport.frameRate.isDropFrame, isTrue);

      expect(transport.timeSeconds, closeTo(61.5, 1e-9));
      expect(transport.ppqPosition, closeTo(8.25, 1e-9));
      expect(transport.bpm, closeTo(120.0, 1e-9));
      expect(transport.editOriginSeconds, closeTo(3600.0, 1e-9));
      expect(transport.timeSamples, 2952000);
      expect(transport.timeSigNumerator, 7);
      expect(transport.timeSigDenominator, 8);
      expect(transport.hostFrames, 512);
    });

    test('reports that the playhead jumped', () {
      // Somebody dragged the playhead. Anything integrating across that
      // boundary is averaging two passes of the same music into one number,
      // and nothing about that number looks wrong — which is the whole reason
      // it is carried rather than inferred.
      expect(transport.isDiscontinuous, isTrue);

      // Ordinary playback must not set it, or it means nothing.
      expect(Transport.none.isDiscontinuous, isFalse);
    });

    test('renders timecode against the edit origin, not against zero', () {
      // The session starts at 01:00:00:00 and the playhead is 61.5 s in, so the
      // wall-clock timecode is one hour, one minute, one and a half seconds.
      // Ignoring editOriginSeconds would put this an hour out — which looks
      // entirely reasonable until somebody matches it to picture.
      //
      // Frame 15 of 30, not 14: this is 29.97 *drop*, and at 3,661.5 s the
      // dropped numbers have accumulated to exactly one frame. That the
      // drop-frame arithmetic is really being done — rather than 30 fps
      // numbers wearing a semicolon — is the whole distinction, and it is
      // worth a full frame here and up to four seconds across a feature.
      expect(transport.timecode, '01:01:01;15');
    });

    test('drop-frame tracks the wall clock where non-drop does not', () {
      // The same instant, labelled by the two 29.97 variants. Drop-frame is
      // designed to stay with the clock; non-drop is designed to count frames
      // and is expected to fall behind, by 3.6 seconds an hour.
      const at = Transport(
        flags: Transport.flagHasTimeSeconds | Transport.flagHasTimecode,
        frameRate: TimecodeFrameRate.fps2997drop,
        timeSeconds: 3600,
      );
      expect(at.timecode, '01:00:00;00');

      const nonDrop = Transport(
        flags: Transport.flagHasTimeSeconds | Transport.flagHasTimecode,
        frameRate: TimecodeFrameRate.fps2997,
        timeSeconds: 3600,
      );
      // 3.6 s behind after an hour, which is exactly why broadcast uses drop.
      expect(nonDrop.timecode, '00:59:56:12');
    });

    test('an integer rate counts to its own nominal, not to 29.97 of it', () {
      const at = Transport(
        flags: Transport.flagHasTimeSeconds | Transport.flagHasTimecode,
        frameRate: TimecodeFrameRate.fps25,
        timeSeconds: 3661.5,
      );
      expect(at.timecode, '01:01:01:12');
    });

    test('derives bar and beat only from what the host actually supplied', () {
      final position = transport.barAndBeat;
      expect(position, isNotNull);

      // 7/8 means 3.5 quarter-notes to the bar; the bar starts at ppq 8.0, so
      // this is bar 3, and the playhead is a quarter of a quarter-note past it,
      // which in eighths is half a beat.
      expect(position!.bar, 3);
      expect(position.beat, closeTo(1.5, 1e-9));
    });

    test('reports nothing when the host supplied nothing', () {
      expect(Transport.none.isPresent, isFalse);
      expect(Transport.none.timecode, isNull);
      expect(Transport.none.barAndBeat, isNull);
    });
  });

  test('a transport survives a Dart round trip', () {
    const original = Transport(
      flags: Transport.flagPlaying | Transport.flagHasBpm,
      frameRate: TimecodeFrameRate.fps24,
      bpm: 128.5,
      timeSamples: -1,
    );

    final reader = FrameReader()..add(DawTransportCodec.encodeFrame(original));
    expect(reader.moveNext(), isTrue);
    expect(reader.type, WireFrameType.dawTransport);

    final decoded = DawTransportCodec.decode(reader.payload);
    expect(decoded.flags, original.flags);
    expect(decoded.frameRate, TimecodeFrameRate.fps24);
    expect(decoded.bpm, closeTo(128.5, 1e-9));

    // Signed, and it must stay signed: a host can report a negative sample
    // position for a playhead before the timeline origin, and reading it as
    // unsigned would turn that into roughly 584,000 years.
    expect(decoded.timeSamples, -1);
  });

  test('a short transport payload is refused rather than read past', () {
    expect(
      () => DawTransportCodec.decode(ByteData(40)),
      throwsA(isA<WireFormatException>()),
    );
  });
}

/// The fixture the plugin's C++ writes, found from wherever the suite was
/// started.
///
/// It deliberately lives under `plugin/` rather than being copied in here. A
/// copy would make this package self-contained and would also, sooner or later,
/// be a stale copy — and the entire value of this file is that the bytes came
/// out of a different implementation in a different language. A golden that has
/// drifted back into agreement with the code it is checking proves nothing.
Uint8List _goldenBytes() {
  var directory = Directory.current;
  for (var depth = 0; depth < 5; depth++) {
    final candidate = File('${directory.path}/plugin/test/golden/wire_v2.bin');
    if (candidate.existsSync()) return candidate.readAsBytesSync();
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'plugin/test/golden/wire_v2.bin not found from ${Directory.current.path}. '
    'Regenerate it with the oaa_wire_fixture target in plugin/.',
  );
}
