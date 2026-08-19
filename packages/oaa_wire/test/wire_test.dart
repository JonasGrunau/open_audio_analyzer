// SPDX-License-Identifier: MIT
//
// The wire protocol's correctness gate.
//
// Two implementations of `docs/WIRE.md` have to agree byte for byte and were
// written by different people who never saw each other's code. This suite
// cannot check the C++ one, so it does the next most useful thing: it pins the
// numbers both sides assert on, and it proves that a value survives the round
// trip *unchanged* — including the values that mean "no measurement", which are
// the ones a careless codec quietly turns into readings.

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';
import 'package:test/test.dart';

void main() {
  group('the frozen shape of protocol version 1', () {
    test('a snapshot payload is 15,056 bytes', () {
      // Frozen. `docs/WIRE.md` publishes this number, the plugin's C++ sender
      // asserts it, and HELLO refuses a producer that disagrees. If a change to
      // MeterShape moved it, every remote display in the field would refuse
      // every host that had not been updated in lockstep — which is the correct
      // behaviour, and this test is where you find that out.
      expect(SnapshotWire.payloadBytes, 15056);
    });

    test('field offsets match the published table', () {
      expect(SnapshotWire.offsetGeneration, 0);
      expect(SnapshotWire.offsetElapsedSeconds, 8);
      expect(SnapshotWire.offsetSampleRate, 16);
      expect(SnapshotWire.offsetFlags, 24);
      expect(SnapshotWire.offsetLufsMomentary, 32);
      expect(SnapshotWire.offsetTruePeak, 48);
      expect(SnapshotWire.offsetDrShort, 64);
      expect(SnapshotWire.offsetCorrelation, 88);
      expect(SnapshotWire.offsetPeak, 96);
      expect(SnapshotWire.offsetRms, 128);
      expect(SnapshotWire.offsetVu, 160);
      expect(SnapshotWire.offsetClip, 192);
      expect(SnapshotWire.offsetSpectrum, 224);
      expect(SnapshotWire.offsetSpectrumPeak, 2272);
      expect(SnapshotWire.offsetLraLow, 4320);
      expect(SnapshotWire.offsetSpectrumPan, 4336);
      expect(SnapshotWire.offsetScope, 6384);
      expect(SnapshotWire.offsetHistogram, 14576);
    });

    test('a whole snapshot frame is header plus payload', () {
      expect(SnapshotFrame().bytes.length, 12 + 15056);
    });
  });

  group('snapshot round trip', () {
    test('every scalar arrives unchanged', () {
      final source = _FakeSource()
        ..generation = 42
        ..elapsedSeconds = 123.456
        ..sampleRate = 96000
        ..channels = 6
        ..droppedFrames = 7
        ..lufsMomentary = -23.5
        ..lufsShort = -18.25
        ..lufsIntegrated = -14.0
        ..loudnessRange = 6.5
        ..loudnessRangeLow = -20.0
        ..loudnessRangeHigh = -13.5
        ..loudnessRangeGate = -34.0
        ..truePeak = -1.25
        ..truePeakMax = -0.5
        ..samplePeakMax = -0.75
        ..dynamicRangeShort = 12.0
        ..dynamicRangeIntegrated = 13.5
        ..crestFactor = 9.25
        ..peakToLoudnessRatio = 13.0
        ..peakToShortTermRatio = 11.5
        ..correlation = -0.5
        ..balance = 0.25;

      final decoded = _roundTrip(source);

      expect(decoded.generation, 42);
      expect(decoded.elapsedSeconds, closeTo(123.456, 1e-12));
      expect(decoded.sampleRate, 96000);
      expect(decoded.channels, 6);
      expect(decoded.droppedFrames, 7);
      expect(decoded.lufsMomentary, -23.5);
      expect(decoded.lufsShort, -18.25);
      expect(decoded.lufsIntegrated, -14.0);
      expect(decoded.loudnessRange, 6.5);
      expect(decoded.loudnessRangeLow, -20.0);
      expect(decoded.loudnessRangeHigh, -13.5);
      expect(decoded.loudnessRangeGate, -34.0);
      expect(decoded.truePeak, -1.25);
      expect(decoded.truePeakMax, -0.5);
      expect(decoded.samplePeakMax, -0.75);
      expect(decoded.dynamicRangeShort, 12.0);
      expect(decoded.dynamicRangeIntegrated, 13.5);
      expect(decoded.crestFactor, 9.25);
      expect(decoded.peakToLoudnessRatio, 13.0);
      expect(decoded.peakToShortTermRatio, 11.5);
      expect(decoded.correlation, -0.5);
      expect(decoded.balance, 0.25);
    });

    test('every array arrives element for element', () {
      final source = _FakeSource();
      for (var i = 0; i < MeterShape.maxChannels; i++) {
        source.peak[i] = -i.toDouble();
        source.rms[i] = -10.0 - i;
        source.vu[i] = -20.0 - i;
        source.clip[i] = i * 3;
      }
      for (var i = 0; i < MeterShape.spectrumBands; i++) {
        source.spectrum[i] = -i.toDouble() / 4;
        source.spectrumPeak[i] = -i.toDouble() / 8;
        source.spectrumPan[i] = (i % 5 - 2) / 2;
      }
      for (var i = 0; i < source.scope.length; i++) {
        source.scope[i] = (i % 512 - 256) / 256;
      }
      for (var i = 0; i < MeterShape.histogramBins; i++) {
        source.histogram[i] = i / 1000;
      }

      final decoded = _roundTrip(source);

      expect(decoded.peak, source.peak);
      expect(decoded.rms, source.rms);
      expect(decoded.vu, source.vu);
      expect(decoded.clip, source.clip);
      expect(decoded.spectrum, source.spectrum);
      expect(decoded.spectrumPeak, source.spectrumPeak);
      expect(decoded.spectrumPan, source.spectrumPan);
      expect(decoded.scope, source.scope);
      expect(decoded.histogram, source.histogram);
    });

    test('a NaN stays a NaN and never becomes a reading', () {
      // The cardinal rule of the whole project, on the one path where it is
      // easiest to break by accident: a codec that writes zero for "not
      // measured" produces a display full of confident readings nobody took.
      final source = _FakeSource()
        ..lufsIntegrated = double.nan
        ..loudnessRange = double.nan
        ..correlation = double.nan
        ..balance = double.nan;
      source.spectrum[0] = double.nan;
      source.peak[0] = double.nan;

      final decoded = _roundTrip(source);

      expect(decoded.lufsIntegrated.isNaN, isTrue);
      expect(decoded.loudnessRange.isNaN, isTrue);
      expect(decoded.correlation.isNaN, isTrue);
      expect(decoded.balance.isNaN, isTrue);
      expect(decoded.spectrum[0].isNaN, isTrue);
      expect(decoded.peak[0].isNaN, isTrue);
    });

    test('digital silence survives as negative infinity', () {
      // -inf is what the engine reports for true digital silence, and it is not
      // interchangeable with the -144 dB floor: a codec that clamped it would
      // change a measurement on the way to the screen.
      final source = _FakeSource()..truePeak = double.negativeInfinity;
      source.rms[0] = double.negativeInfinity;

      final decoded = _roundTrip(source);

      expect(decoded.truePeak, double.negativeInfinity);
      expect(decoded.rms[0], double.negativeInfinity);
    });

    test('the availability flags survive both ways round', () {
      final available = _roundTrip(
        _FakeSource()
          ..isRunning = true
          ..hasLoudness = true
          ..hasSpectrum = true
          ..hasOverrun = false,
      );
      expect(available.isRunning, isTrue);
      expect(available.hasLoudness, isTrue);
      expect(available.hasSpectrum, isTrue);
      expect(available.hasOverrun, isFalse);

      final unavailable = _roundTrip(
        _FakeSource()
          ..isRunning = false
          ..hasLoudness = false
          ..hasSpectrum = false
          ..hasOverrun = true,
      );
      expect(unavailable.isRunning, isFalse);
      expect(unavailable.hasLoudness, isFalse);
      expect(unavailable.hasSpectrum, isFalse);
      expect(unavailable.hasOverrun, isTrue);
    });

    test('the decoder never replaces its arrays', () {
      // The contract the modules depend on: a painter may hold an array across
      // frames, so decoding must overwrite contents and not swap objects. If
      // this ever fails, every painter on the tablet is drawing last second's
      // list while the new one is filled somewhere else.
      final snapshot = WireSnapshot();
      final spectrum = snapshot.spectrum;
      final scope = snapshot.scope;

      snapshot.decode(_encode(_FakeSource()..generation = 1));
      snapshot.decode(_encode(_FakeSource()..generation = 2));
      snapshot.markStale();

      expect(identical(snapshot.spectrum, spectrum), isTrue);
      expect(identical(snapshot.scope, scope), isTrue);
    });
  });

  group('refresh', () {
    test('reports a change once per published generation', () {
      final snapshot = WireSnapshot()
        ..decode(_encode(_FakeSource()..generation = 5));

      expect(snapshot.refresh(), isTrue, reason: 'first look at generation 5');
      expect(snapshot.refresh(), isFalse, reason: 'nothing new since');

      snapshot.decode(_encode(_FakeSource()..generation = 6));
      expect(snapshot.refresh(), isTrue);
      expect(snapshot.refresh(), isFalse);
    });

    test('two frames between two ticks collapse into one repaint', () {
      final snapshot = WireSnapshot()
        ..decode(_encode(_FakeSource()..generation = 1))
        ..decode(_encode(_FakeSource()..generation = 2))
        ..decode(_encode(_FakeSource()..generation = 3));

      expect(snapshot.refresh(), isTrue);
      expect(snapshot.refresh(), isFalse);
      expect(snapshot.generation, 3);
    });
  });

  group('a link that has gone quiet', () {
    test('opens stale rather than showing a measured silence', () {
      final snapshot = WireSnapshot();

      expect(snapshot.isStale, isTrue);
      expect(snapshot.isRunning, isFalse);
      expect(snapshot.hasLoudness, isFalse);
      expect(snapshot.hasSpectrum, isFalse);
      expect(snapshot.lufsIntegrated.isNaN, isTrue);
      expect(snapshot.spectrum[0].isNaN, isTrue);
    });

    test('drops the last frame instead of freezing it on screen', () {
      final snapshot = WireSnapshot()
        ..decode(
          _encode(
            _FakeSource()
              ..generation = 9
              ..lufsShort = -14.0
              ..isRunning = true
              ..hasLoudness = true
              ..hasSpectrum = true,
          ),
        );
      expect(snapshot.lufsShort, -14.0);
      expect(snapshot.refresh(), isTrue);

      snapshot.markStale();

      expect(snapshot.lufsShort.isNaN, isTrue);
      expect(snapshot.isRunning, isFalse);
      expect(snapshot.hasLoudness, isFalse);
      expect(snapshot.hasSpectrum, isFalse);
      expect(
        snapshot.refresh(),
        isTrue,
        reason: 'going stale is itself a change the meters must repaint for',
      );
    });

    test('a spectrum with no data is NaN, not a flat line at the floor', () {
      // Filling with the dB floor would draw a picture of silence, and silence
      // is a measurement we did not take.
      final snapshot = WireSnapshot()
        ..decode(_encode(_FakeSource()..hasSpectrum = true))
        ..markStale();

      expect(snapshot.spectrum.every((v) => v.isNaN), isTrue);
      expect(snapshot.scope.every((v) => v.isNaN), isTrue);
    });
  });

  group('framing', () {
    test('a frame split across three chunks reassembles', () {
      final frame = SnapshotFrame()..encode(_FakeSource()..generation = 3);
      final bytes = frame.bytes;
      final reader = FrameReader();

      reader.add(bytes.sublist(0, 5));
      expect(reader.moveNext(), isFalse, reason: 'header incomplete');

      reader.add(bytes.sublist(5, 4000));
      expect(reader.moveNext(), isFalse, reason: 'payload incomplete');

      reader.add(bytes.sublist(4000));
      expect(reader.moveNext(), isTrue);
      expect(reader.type, WireFrameType.snapshot);

      final snapshot = WireSnapshot()..decode(reader.payload);
      expect(snapshot.generation, 3);
    });

    test('two frames in one chunk both come out', () {
      final first = SnapshotFrame()..encode(_FakeSource()..generation = 1);
      final second = SnapshotFrame()..encode(_FakeSource()..generation = 2);

      final reader = FrameReader()
        ..add(first.bytes)
        ..add(second.bytes);

      final snapshot = WireSnapshot();

      expect(reader.moveNext(), isTrue);
      snapshot.decode(reader.payload);
      expect(snapshot.generation, 1);

      expect(reader.moveNext(), isTrue);
      snapshot.decode(reader.payload);
      expect(snapshot.generation, 2);

      expect(reader.moveNext(), isFalse);
    });

    test('an unknown frame type is skipped by length, not fatal', () {
      // What lets a plugin sending DAW transport talk to a display built before
      // transport existed.
      final unknown = WireFrame.encode(0x0010, Uint8List(88));
      final snapshot = SnapshotFrame()..encode(_FakeSource()..generation = 11);

      final reader = FrameReader()
        ..add(unknown)
        ..add(snapshot.bytes);

      expect(reader.moveNext(), isTrue);
      expect(reader.type, 0x0010);
      expect(reader.payload.lengthInBytes, 88);

      expect(reader.moveNext(), isTrue);
      expect(reader.type, WireFrameType.snapshot);
      expect((WireSnapshot()..decode(reader.payload)).generation, 11);
    });

    test(
      'a stream that is not an Open Audio Analyzer stream fails on the first frame',
      () {
        final reader = FrameReader()
          ..add(Uint8List.fromList(List.filled(64, 7)));
        expect(reader.moveNext, throwsA(isA<WireFormatException>()));
      },
    );

    test('an absurd length is refused rather than allocated', () {
      final bytes = Uint8List(WireFrame.headerBytes);
      WireFrame.writeHeader(ByteData.view(bytes.buffer), 0x0003, 0xFFFFFFF);

      final reader = FrameReader()..add(bytes);
      expect(reader.moveNext, throwsA(isA<WireFormatException>()));
    });

    test('a reset reader forgets what the previous stream left behind', () {
      // The reader outlives the connection. A socket that dies mid-frame leaves
      // the head of that frame here, and those bytes are not a prefix of
      // anything the next connection sends — so without the reset the tail of
      // a dead stream is reassembled onto the head of a live one, at exactly
      // the right length to decode. The display drew that: a detailed,
      // confident, entirely invented measurement.
      final interrupted = SnapshotFrame()
        ..encode(_FakeSource()..generation = 41);
      final fresh = SnapshotFrame()..encode(_FakeSource()..generation = 42);

      final reader = FrameReader()
        ..add(interrupted.bytes.sublist(0, 6000))
        ..reset()
        ..add(fresh.bytes);

      expect(reader.moveNext(), isTrue);
      expect(reader.type, WireFrameType.snapshot);
      expect((WireSnapshot()..decode(reader.payload)).generation, 42);
      expect(reader.moveNext(), isFalse, reason: 'nothing of the old stream');
    });

    test('a reset keeps the reader usable, not merely empty', () {
      // A reset in the middle of a healthy frame must leave a reader that can
      // still reassemble across chunks, rather than one that has lost its
      // buffer or its offsets.
      final frame = SnapshotFrame()..encode(_FakeSource()..generation = 5);
      final reader = FrameReader()..add(frame.bytes);

      expect(reader.moveNext(), isTrue);
      reader.reset();

      reader.add(frame.bytes.sublist(0, 100));
      expect(reader.moveNext(), isFalse);
      reader.add(frame.bytes.sublist(100));
      expect(reader.moveNext(), isTrue);
      expect((WireSnapshot()..decode(reader.payload)).generation, 5);
    });

    test('a frame from a future protocol version is refused', () {
      final bytes = Uint8List(WireFrame.headerBytes);
      final view = ByteData.view(bytes.buffer)
        ..setUint32(0, WireFrame.magic, Endian.little)
        ..setUint16(4, WireFrame.protocolVersion + 1, Endian.little)
        ..setUint16(6, WireFrameType.snapshot, Endian.little)
        ..setUint32(8, 0, Endian.little);
      expect(view.getUint16(4, Endian.little), WireFrame.protocolVersion + 1);

      final reader = FrameReader()..add(bytes);
      expect(reader.moveNext, throwsA(isA<WireFormatException>()));
    });
  });

  group('hello', () {
    test('round trips, name and all', () {
      final hello = WireHello.local(abiVersion: 3, producerName: 'Studio Mac');
      final frame = hello.encodeFrame();

      final reader = FrameReader()..add(frame);
      expect(reader.moveNext(), isTrue);
      expect(reader.type, WireFrameType.hello);

      final decoded = WireHello.decode(reader.payload);
      expect(decoded.producerName, 'Studio Mac');
      expect(decoded.abiVersion, 3);
      expect(decoded.snapshotPayloadBytes, SnapshotWire.payloadBytes);
      expect(decoded.spectrumBands, MeterShape.spectrumBands);
      expect(decoded.incompatibility, isNull);
    });

    test('a non-ASCII host name survives', () {
      final decoded = _decodeHello(
        WireHello.local(abiVersion: 3, producerName: 'Björns Regieraum 🎚'),
      );
      expect(decoded.producerName, 'Björns Regieraum 🎚');
    });

    test('a differently shaped producer is refused, by name', () {
      final decoded = _decodeHello(
        WireHello(
          snapshotPayloadBytes: SnapshotWire.payloadBytes,
          abiVersion: 3,
          maxChannels: MeterShape.maxChannels,
          spectrumBands: 1024,
          scopePoints: MeterShape.scopePoints,
          histogramBins: MeterShape.histogramBins,
          producerName: 'wider',
        ),
      );
      expect(decoded.incompatibility, contains('shape'));
    });

    test('a differently sized snapshot is refused', () {
      final decoded = _decodeHello(
        WireHello(
          snapshotPayloadBytes: SnapshotWire.payloadBytes + 4,
          abiVersion: 3,
          maxChannels: MeterShape.maxChannels,
          spectrumBands: MeterShape.spectrumBands,
          scopePoints: MeterShape.scopePoints,
          histogramBins: MeterShape.histogramBins,
          producerName: 'appended a field',
        ),
      );
      expect(decoded.incompatibility, contains('15060'));
    });

    test('a newer ABI is accepted — it is not the check that matters', () {
      // Phase 5 bumps OAA_ABI_VERSION to 4 without moving a snapshot byte. A
      // display that refused on ABI alone would refuse a host it could draw
      // perfectly.
      final decoded = _decodeHello(
        WireHello.local(abiVersion: 4, producerName: 'newer engine'),
      );
      expect(decoded.abiVersion, 4);
      expect(decoded.incompatibility, isNull);
    });
  });
}

WireHello _decodeHello(WireHello hello) {
  final reader = FrameReader()..add(hello.encodeFrame());
  reader.moveNext();
  return WireHello.decode(reader.payload);
}

ByteData _encode(MeterSource source) {
  final bytes = ByteData(SnapshotWire.payloadBytes);
  SnapshotWire.encode(source, bytes);
  return bytes;
}

WireSnapshot _roundTrip(MeterSource source) =>
    WireSnapshot()..decode(_encode(source));

/// A [MeterSource] whose values are set by hand.
///
/// Nothing about a real engine is involved: the codec is pure Dart and so is
/// its test, which is why this suite runs with no toolchain, no native library
/// and no audio device.
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
