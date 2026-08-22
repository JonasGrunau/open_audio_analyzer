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
  _lufsModeTests();

  group('the frozen shape of protocol version 4', () {
    test('a snapshot payload is 7,652 bytes for one analysis block', () {
      // Frozen for as long as the protocol version is. `docs/WIRE.md` publishes
      // this number, the plugin's C++ sender asserts it, and HELLO refuses a
      // producer that announces neither this nor the legacy size. If a change
      // to MeterShape moved it, every remote display in the field would refuse
      // every host that had not been updated in lockstep — which is the correct
      // behaviour, and this test is where you find that out.
      expect(SnapshotWire.payloadBytes, 7652);
      expect(SnapshotWire.baseBytes, 3556);
      expect(SnapshotWire.maxPayloadBytes, 3556 + 4096 * 4);
    });

    test('field offsets match the published table', () {
      // Identical to versions 1-3 up to the end of `clip`; everything after it
      // moved, because the five plotted arrays are two bytes an element now.
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
      expect(SnapshotWire.offsetSpectrumPeak, 1248);
      expect(SnapshotWire.offsetLraLow, 2272);
      expect(SnapshotWire.offsetSpectrumPan, 2288);
      expect(SnapshotWire.offsetHistogram, 3312);
      expect(SnapshotWire.offsetScopeFrames, 3552);
      expect(SnapshotWire.offsetScope, 3556);
    });

    test('every 16-bit array starts on an even offset', () {
      // Not decoration: a `Uint16List.view` onto an odd offset throws, and the
      // layout is derived from MeterShape rather than written out, so a future
      // shape change could quietly produce one.
      for (final offset in [
        SnapshotWire.offsetSpectrum,
        SnapshotWire.offsetSpectrumPeak,
        SnapshotWire.offsetSpectrumPan,
        SnapshotWire.offsetScope,
        SnapshotWire.offsetHistogram,
      ]) {
        expect(offset.isEven, isTrue, reason: 'offset $offset is odd');
      }
      // And every float32 field stays four-byte aligned for the same reason.
      for (final offset in [
        SnapshotWire.offsetLraLow,
        SnapshotWire.offsetLraHigh,
        SnapshotWire.offsetLraGate,
      ]) {
        expect(offset % 4, 0, reason: 'offset $offset is not 4-aligned');
      }
    });

    test('the frozen version 1-3 table is still described exactly', () {
      // Decode-only, and it must not drift: an older plugin outlives an app
      // upgrade, and these are the offsets its bytes are written at.
      expect(SnapshotWireLegacy.payloadBytes, 15056);
      expect(SnapshotWireLegacy.offsetSpectrum, 224);
      expect(SnapshotWireLegacy.offsetSpectrumPeak, 2272);
      expect(SnapshotWireLegacy.offsetLraLow, 4320);
      expect(SnapshotWireLegacy.offsetSpectrumPan, 4336);
      expect(SnapshotWireLegacy.offsetScope, 6384);
      expect(SnapshotWireLegacy.offsetHistogram, 14576);
    });

    test('a whole snapshot frame is header plus payload', () {
      expect(SnapshotFrame().bytes.length, 12 + SnapshotWire.maxPayloadBytes);
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

      // Exact, because these four are still float32 on the wire: they are read
      // as numbers beside the meters they drive, not only as pixels.
      expect(decoded.peak, source.peak);
      expect(decoded.rms, source.rms);
      expect(decoded.vu, source.vu);
      expect(decoded.clip, source.clip);

      // The five plotted arrays are fixed point at version 4, so the claim is
      // half a step of their own encoding — not "close enough". Anything looser
      // would stop this noticing an array written through the wrong codec.
      _expectClose(decoded.spectrum, source.spectrum, 0.5 / Quantise.dbStep);
      _expectClose(
        decoded.spectrumPeak,
        source.spectrumPeak,
        0.5 / Quantise.dbStep,
      );
      _expectClose(decoded.spectrumPan, source.spectrumPan, 0.5 / 32767);
      // Only the part this measurement filled — over a wire the list is
      // allocated at the protocol's maximum. See `MeterSource.scopeFrames`.
      expect(decoded.scopeFrames, source.scopeFrames);
      _expectClose(
        decoded.scope.sublist(0, decoded.scopeFrames * 2),
        source.scope,
        0.5 / Quantise.sampleScale,
      );
      _expectClose(decoded.histogram, source.histogram, 0.5 / 0xFFFE);
    });

    test('a quantised array keeps NaN distinct from every real reading', () {
      // The rule the protocol is built on, at the one place version 4 could
      // have broken it: fixed point has no NaN of its own. A band that read as
      // the floor instead would draw a spectrum flat along the bottom, which is
      // a picture of silence — and silence is a measurement nobody took.
      final source = _FakeSource();
      source.spectrum[0] = double.nan;
      source.spectrum[1] = Quantise.dbOrigin; // the very bottom of the range
      source.spectrum[2] = double.negativeInfinity;
      source.spectrumPan[0] = double.nan;
      source.spectrumPan[1] = -1;
      source.scope[0] = double.nan;
      source.scope[1] = 0;
      source.histogram[0] = double.nan;
      source.histogram[1] = 0;

      final decoded = _roundTrip(source);

      expect(decoded.spectrum[0].isNaN, isTrue);
      expect(decoded.spectrum[1].isNaN, isFalse);
      expect(decoded.spectrum[1], closeTo(Quantise.dbOrigin, 0.01));
      // Digital silence clamps to the bottom of the encoding rather than
      // becoming "not measured"; it *was* measured, and it was silent.
      expect(decoded.spectrum[2].isNaN, isFalse);

      expect(decoded.spectrumPan[0].isNaN, isTrue);
      expect(decoded.spectrumPan[1], closeTo(-1, 1e-4));

      expect(decoded.scope[0].isNaN, isTrue);
      expect(decoded.scope[1], 0);

      expect(decoded.histogram[0].isNaN, isTrue);
      expect(decoded.histogram[1], 0);
    });

    test('a sample past full scale is carried, not folded to the rim', () {
      // A float file may legitimately exceed full scale. Q1.14 has headroom to
      // +1.9999 for that reason — a goniometer that wrapped an intersample peak
      // back inside the circle would draw a limiter that is not there.
      final source = _FakeSource();
      source.scope[0] = 1.5;
      source.scope[1] = -1.5;

      final decoded = _roundTrip(source);

      expect(decoded.scope[0], closeTo(1.5, 1e-4));
      expect(decoded.scope[1], closeTo(-1.5, 1e-4));
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
      final bytes = frame.wire;
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
        ..add(first.wire)
        ..add(second.wire);

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
        ..add(snapshot.wire);

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
        ..add(interrupted.wire.sublist(0, 6000))
        ..reset()
        ..add(fresh.wire);

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
      final reader = FrameReader()..add(frame.wire);

      expect(reader.moveNext(), isTrue);
      reader.reset();

      reader.add(frame.wire.sublist(0, 100));
      expect(reader.moveNext(), isFalse);
      reader.add(frame.wire.sublist(100));
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
      expect(decoded.incompatibility, contains('7652'));
    });

    test('the legacy snapshot size is accepted, and only that one', () {
      WireHello sized(int bytes) => _decodeHello(
        WireHello(
          snapshotPayloadBytes: bytes,
          abiVersion: 3,
          maxChannels: MeterShape.maxChannels,
          spectrumBands: MeterShape.spectrumBands,
          scopePoints: MeterShape.scopePoints,
          histogramBins: MeterShape.histogramBins,
          producerName: 'a plugin that predates version 4',
        ),
      );

      // The promise `WireFrame.minimumVersion` makes: a plugin installed before
      // the app was upgraded still draws. It announces the version 1-3 size.
      expect(sized(SnapshotWireLegacy.payloadBytes).incompatibility, isNull);
      expect(sized(SnapshotWire.payloadBytes).incompatibility, isNull);

      // Anything between them is a table nobody here has ever written, and
      // guessing at it is how a meter draws a confident wrong number.
      expect(sized(12000).incompatibility, isNotNull);
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
  int scopeFrames = MeterShape.scopePoints;

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  @override
  bool refresh() => true;
}

void _lufsModeTests() {
  group('0x0020 SET_LUFS_MODE', () {
    LufsModeRequest? roundTrip(LufsTimeMode mode, {LufsRegion? region}) {
      final frame = LufsModeCodec.encodeFrame(mode, region: region);
      final reader = FrameReader()..add(frame);
      expect(reader.moveNext(), isTrue);
      expect(reader.type, WireFrameType.setLufsMode);
      expect(reader.version, WireFrame.protocolVersion);
      return LufsModeCodec.decode(reader.payload);
    }

    test('the payload is the 24 bytes docs/WIRE.md freezes', () {
      final frame = LufsModeCodec.encodeFrame(LufsTimeMode.continuous);
      expect(frame.length, WireFrame.headerBytes + LufsModeCodec.payloadBytes);
      expect(LufsModeCodec.payloadBytes, 24);
    });

    test('the wire value of a mode is its declaration index', () {
      // The coupling docs/WIRE.md relies on. If somebody reorders the enum this
      // fails here rather than in a plugin measuring the wrong window.
      expect(LufsTimeMode.continuous.wireValue, 0);
      expect(LufsTimeMode.system.wireValue, 1);
      expect(LufsTimeMode.elapsed.wireValue, 2);
      expect(LufsTimeMode.timecode.wireValue, 3);
    });

    test('every mode without a region survives the trip', () {
      for (final mode in <LufsTimeMode>[
        LufsTimeMode.continuous,
        LufsTimeMode.system,
        LufsTimeMode.elapsed,
      ]) {
        final decoded = roundTrip(mode);
        expect(decoded, isNotNull, reason: mode.id);
        expect(decoded!.mode, mode);
        expect(decoded.region, isNull);
      }
    });

    test('timecode carries its region', () {
      final decoded = roundTrip(
        LufsTimeMode.timecode,
        region: const LufsRegion(60.0, 210.5),
      );
      expect(decoded, isNotNull);
      expect(decoded!.mode, LufsTimeMode.timecode);
      expect(decoded.region, const LufsRegion(60.0, 210.5));
    });

    test('timecode without a region is refused rather than defaulted', () {
      // The producer must keep the mode it had. A default would measure a
      // stretch of timeline nobody chose, and an integrated reading over the
      // wrong window is wrong with nothing on screen to say so.
      expect(roundTrip(LufsTimeMode.timecode), isNull);
    });

    test('an empty or reversed region is refused', () {
      expect(
        roundTrip(LufsTimeMode.timecode, region: const LufsRegion(30.0, 30.0)),
        isNull,
      );
      expect(
        roundTrip(LufsTimeMode.timecode, region: const LufsRegion(90.0, 30.0)),
        isNull,
      );
    });

    test('a mode from a newer build is refused, not clamped', () {
      final payload = ByteData(LufsModeCodec.payloadBytes)
        ..setUint32(0, 99, Endian.little);
      expect(LufsModeCodec.decode(payload), isNull);
    });

    test('a short payload is refused rather than read past', () {
      expect(LufsModeCodec.decode(ByteData(8)), isNull);
    });

    test('a resend of the same request is recognised as no change', () {
      // What stops a careless resend silently restarting somebody's
      // measurement.
      const a = LufsModeRequest(LufsTimeMode.elapsed, null);
      const b = LufsModeRequest(LufsTimeMode.elapsed, null);
      expect(a.sameAs(b), isTrue);

      const region = LufsModeRequest(
        LufsTimeMode.timecode,
        LufsRegion(0.0, 10.0),
      );
      const moved = LufsModeRequest(
        LufsTimeMode.timecode,
        LufsRegion(0.0, 20.0),
      );
      expect(region.sameAs(moved), isFalse);
    });
  });
}

/// Asserts two arrays agree to within [tolerance], element for element.
///
/// Written out rather than `pairwiseCompare` so that a failure names the index
/// — an array of 2,048 that differs at one place is otherwise reported as two
/// walls of numbers.
void _expectClose(
  List<double> actual,
  List<double> expected,
  double tolerance,
) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i], closeTo(expected[i], tolerance), reason: 'element $i');
  }
}
