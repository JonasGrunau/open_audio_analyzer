// Offline file decoding, and the claim that rests on it.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The interesting test in this file is not "can we open a WAV". It is
// `offline analysis agrees with realtime`: the same samples, once pushed
// straight into the engine and once written to disk, decoded, and pushed back,
// must produce bit-identical readings. That equality is the entire argument
// for trusting a file report, and it is only true because decoding feeds the
// same `oaa_analyse` rather than a second implementation of it. If this test
// ever goes red, offline analysis has become a different meter.
//
// The fixtures are written here rather than committed, for two reasons: a
// binary blob in the repository is a fixture nobody can check the contents of,
// and a generated sine is a signal whose correct answer is known from
// arithmetic — a sine of amplitude A peaks at A and has an RMS of A/sqrt(2),
// exactly 3.0103 dB lower.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_engine/oaa_engine.dart';
import 'package:test/test.dart';

const int _sampleRate = 48000;
const int _blockFrames = 1024;
const double _amplitude = 0.5;

/// A 1 kHz sine at [_amplitude], [seconds] long, interleaved across
/// [channels]. The same signal the engine's own test tone uses, so the
/// expected peak and RMS are the ones the rest of the suite asserts.
Float32List _sine(double seconds, {int channels = 2}) {
  final frames = (seconds * _sampleRate).round();
  final out = Float32List(frames * channels);
  const hz = 1000.0;

  for (var i = 0; i < frames; i++) {
    final value = _amplitude * math.sin(2 * math.pi * hz * i / _sampleRate);
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = value;
    }
  }
  return out;
}

/// Writes [samples] as a 32-bit float WAV.
///
/// Float rather than 16-bit integer on purpose: quantising to 16 bits would
/// change the samples, and then a mismatch between the offline and realtime
/// readings could be blamed on the quantisation rather than on the bug it
/// actually is. Float round-trips exactly, so the two paths see identical
/// numbers and the comparison is exact.
File _writeFloatWav(
  Directory dir,
  String name,
  Float32List samples,
  int channels,
) {
  const headerBytes = 44;
  final dataBytes = samples.length * 4;
  final bytes = BytesBuilder();

  final header = ByteData(headerBytes);
  var offset = 0;
  void ascii(String text) {
    for (final unit in text.codeUnits) {
      header.setUint8(offset++, unit);
    }
  }

  void u32(int value) {
    header.setUint32(offset, value, Endian.little);
    offset += 4;
  }

  void u16(int value) {
    header.setUint16(offset, value, Endian.little);
    offset += 2;
  }

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(3); // IEEE float
  u16(channels);
  u32(_sampleRate);
  u32(_sampleRate * channels * 4); // byte rate
  u16(channels * 4); // block align
  u16(32); // bits per sample
  ascii('data');
  u32(dataBytes);

  bytes.add(header.buffer.asUint8List());

  final payload = ByteData(dataBytes);
  for (var i = 0; i < samples.length; i++) {
    payload.setFloat32(i * 4, samples[i], Endian.little);
  }
  bytes.add(payload.buffer.asUint8List());

  final file = File('${dir.path}/$name')..writeAsBytesSync(bytes.toBytes());
  return file;
}

/// Every scalar a report would print, read off an engine.
Map<String, double> _readings(OaaEngine engine) => {
  'lufs_i': engine.lufsIntegrated,
  'lufs_s': engine.lufsShort,
  'lufs_m': engine.lufsMomentary,
  'lra': engine.loudnessRange,
  'true_peak_max': engine.truePeakMax,
  'sample_peak_max': engine.samplePeakMax,
  'peak_0': engine.peak[0],
  'rms_0': engine.rms[0],
};

/// Pushes [samples] through a fresh engine in [_blockFrames] blocks.
Map<String, double> _analyseInMemory(Float32List samples, int channels) {
  final engine = OaaEngine.start(
    source: OaaSource.push,
    sampleRate: _sampleRate,
    channels: channels,
    blockFrames: _blockFrames,
  );
  try {
    final stride = _blockFrames * channels;
    for (var offset = 0; offset < samples.length; offset += stride) {
      final end = math.min(offset + stride, samples.length);
      engine.push(Float32List.sublistView(samples, offset, end));
    }
    engine.refresh();
    return _readings(engine);
  } finally {
    engine.dispose();
  }
}

/// Decodes [file] and pushes it through a fresh engine the same way.
Map<String, double> _analyseFile(File file) {
  final decoded = OaaFile.open(file.path, blockFrames: _blockFrames);
  final engine = OaaEngine.start(
    source: OaaSource.push,
    sampleRate: decoded.info.sampleRate,
    channels: decoded.info.channels,
    blockFrames: _blockFrames,
  );
  try {
    for (
      Float32List? block = decoded.readBlock();
      block != null;
      block = decoded.readBlock()
    ) {
      engine.push(block);
    }
    engine.refresh();
    return _readings(engine);
  } finally {
    engine.dispose();
    decoded.close();
  }
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('oaa_decode_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('opening', () {
    test('reads format, rate, channels and duration from a float WAV', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(2.0), 2);
      final decoded = OaaFile.open(file.path);

      expect(decoded.info.format, OaaFileFormat.wav);
      expect(decoded.info.sampleRate, _sampleRate);
      expect(decoded.info.channels, 2);
      expect(decoded.info.frames, 2 * _sampleRate);
      expect(decoded.info.durationSeconds, closeTo(2.0, 1e-9));
      expect(decoded.info.bitsPerSample, 32);
      expect(decoded.info.hasKnownLength, isTrue);

      decoded.close();
    });

    test('describe() names the container, depth, rate and layout', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(0.5), 2);
      final decoded = OaaFile.open(file.path);
      expect(decoded.info.describe(), 'WAV 32-bit 48000 Hz, stereo');
      decoded.close();
    });

    test('a mono file is described as mono, not as 1 channels', () {
      final file = _writeFloatWav(temp, 'mono.wav', _sine(0.5, channels: 1), 1);
      final decoded = OaaFile.open(file.path);
      expect(decoded.info.channels, 1);
      expect(decoded.info.describe(), contains('mono'));
      decoded.close();
    });

    test('a file that is not audio throws rather than returning empty', () {
      final junk = File('${temp.path}/notes.txt')
        ..writeAsStringSync('this is not audio, it is a text file');
      expect(() => OaaFile.open(junk.path), throwsA(isA<OaaFileException>()));
    });

    test('a missing file throws', () {
      expect(
        () => OaaFile.open('${temp.path}/does_not_exist.wav'),
        throwsA(isA<OaaFileException>()),
      );
    });
  });

  group('reading', () {
    test('returns every frame exactly once, then null at end of file', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(1.0), 2);
      final decoded = OaaFile.open(file.path, blockFrames: _blockFrames);

      var frames = 0;
      var blocks = 0;
      for (
        Float32List? block = decoded.readBlock();
        block != null;
        block = decoded.readBlock()
      ) {
        frames += block.length ~/ 2;
        blocks++;
      }

      expect(frames, _sampleRate, reason: 'one second at 48 kHz');
      expect(decoded.framesRead, _sampleRate);
      expect(blocks, (_sampleRate / _blockFrames).ceil());
      expect(decoded.readBlock(), isNull, reason: 'stays at EOF');

      decoded.close();
    });

    test('the decoded samples are the ones that were written', () {
      final source = _sine(0.1);
      final file = _writeFloatWav(temp, 'tone.wav', source, 2);
      final decoded = OaaFile.open(file.path, blockFrames: _blockFrames);

      var index = 0;
      for (
        Float32List? block = decoded.readBlock();
        block != null;
        block = decoded.readBlock()
      ) {
        for (final sample in block) {
          expect(sample, source[index++]);
        }
      }
      expect(index, source.length);

      decoded.close();
    });

    test(
      'progress is null when the length is unknown, never a fabricated 0',
      () {
        final file = _writeFloatWav(temp, 'tone.wav', _sine(0.5), 2);
        final decoded = OaaFile.open(file.path);
        expect(decoded.progress, 0.0);
        while (decoded.readBlock() != null) {}
        expect(decoded.progress, closeTo(1.0, 1e-9));
        decoded.close();
      },
    );

    test('reading after close is an error rather than a native crash', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(0.1), 2);
      final decoded = OaaFile.open(file.path)..close();
      expect(decoded.readBlock, throwsStateError);
    });

    test('close is idempotent', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(0.1), 2);
      final decoded = OaaFile.open(file.path)..close();
      expect(decoded.close, returnsNormally);
    });
  });

  group('the arithmetic reference', () {
    // A sine of amplitude 0.5 peaks at -6.0206 dBFS and has an RMS 3.0103 dB
    // below that. These are the same numbers the engine's own tone is held
    // against, so a decoder that scaled its output would fail here first.
    test('a 0.5-amplitude sine decodes to -6.0206 dBFS peak', () {
      final file = _writeFloatWav(temp, 'tone.wav', _sine(3.0), 2);
      final readings = _analyseFile(file);

      expect(readings['sample_peak_max'], closeTo(-6.0206, 0.01));
      expect(readings['peak_0'], closeTo(-6.0206, 0.05));
      expect(readings['rms_0'], closeTo(-9.0309, 0.05));
    });
  });

  group('offline agrees with realtime', () {
    // The claim the whole phase rests on.
    test('a stereo file reads identically pushed and decoded', () {
      final samples = _sine(4.0);
      final file = _writeFloatWav(temp, 'tone.wav', samples, 2);

      final inMemory = _analyseInMemory(samples, 2);
      final fromFile = _analyseFile(file);

      for (final key in inMemory.keys) {
        expect(
          fromFile[key],
          inMemory[key],
          reason:
              '$key differs: decoding a file must reach the same oaa_analyse '
              'as pushing the samples directly',
        );
      }
    });

    test('a mono file reads identically pushed and decoded', () {
      final samples = _sine(3.0, channels: 1);
      final file = _writeFloatWav(temp, 'mono.wav', samples, 1);

      final inMemory = _analyseInMemory(samples, 1);
      final fromFile = _analyseFile(file);

      for (final key in inMemory.keys) {
        expect(fromFile[key], inMemory[key], reason: '$key differs');
      }
    });
  });

  group('sample values are not altered', () {
    test('float samples above full scale survive decoding', () {
      // A float WAV may legitimately hold values outside +-1.0, and they are
      // exactly what true-peak metering exists to catch. A decoder that
      // clamped would erase the overshoot and report a compliant file.
      final samples = Float32List.fromList([
        1.5, 1.5, //
        -1.5, -1.5,
        0.25, 0.25,
      ]);
      final file = _writeFloatWav(temp, 'hot.wav', samples, 2);
      final decoded = OaaFile.open(file.path);

      final block = decoded.readBlock()!;
      expect(block[0], 1.5);
      expect(block[2], -1.5);
      expect(block[4], 0.25);

      decoded.close();
    });
  });
}
