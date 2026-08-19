// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CLI is tested through its actual entry point rather than by calling the
// functions behind it, because the things worth asserting about a command-line
// tool are the things a unit test of its internals cannot see: the exit code,
// which stream each kind of output went to, and whether stdout is still clean
// enough to pipe.
//
// The exit code matters most. `oaa --target` exists so a release pipeline can
// fail a build on a master that misses its delivery spec, and a tool that
// reports non-compliance on stdout while exiting 0 is a tool whose check
// silently never fires.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';

late Directory _temp;
late String _entryPoint;

/// Writes a 24-bit WAV of a 1 kHz sine at [amplitude].
///
/// 24-bit integer rather than float, so the test exercises the conversion path
/// a real master would take rather than the one case that is a straight copy.
File _writeWav(
  String name,
  double amplitude,
  double seconds, {
  int channels = 2,
}) {
  const rate = 48000;
  final frames = (seconds * rate).round();
  final data = BytesBuilder();

  var phase = 0.0;
  final step = 2 * math.pi * 1000.0 / rate;
  for (var i = 0; i < frames; i++) {
    final value = (amplitude * math.sin(phase) * 8388607).round();
    phase = (phase + step) % (2 * math.pi);
    final bytes = Uint8List(3)
      ..[0] = value & 0xFF
      ..[1] = (value >> 8) & 0xFF
      ..[2] = (value >> 16) & 0xFF;
    for (var c = 0; c < channels; c++) {
      data.add(bytes);
    }
  }

  final payload = data.toBytes();
  final byteRate = rate * channels * 3;
  final header = BytesBuilder()
    ..add(ascii.encode('RIFF'))
    ..add(_u32(36 + payload.length))
    ..add(ascii.encode('WAVE'))
    ..add(ascii.encode('fmt '))
    ..add(_u32(16))
    ..add(_u16(1))
    ..add(_u16(channels))
    ..add(_u32(rate))
    ..add(_u32(byteRate))
    ..add(_u16(channels * 3))
    ..add(_u16(24))
    ..add(ascii.encode('data'))
    ..add(_u32(payload.length));

  final file = File('${_temp.path}/$name')
    ..writeAsBytesSync(header.toBytes() + payload);
  return file;
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

ProcessResult _run(List<String> args) =>
    Process.runSync(Platform.resolvedExecutable, ['run', _entryPoint, ...args]);

void main() {
  setUpAll(() {
    _temp = Directory.systemTemp.createTempSync('oaa_cli_test');
    _entryPoint = '${Directory.current.path}/bin/oaa.dart';
  });

  tearDownAll(() => _temp.deleteSync(recursive: true));

  group('usage', () {
    test('--help explains itself and exits 0', () {
      final result = _run(['--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage:'));
      expect(result.stdout, contains('--target'));
      expect(result.stdout, contains('Exit codes:'));
    });

    test('--version names the tool and the engine', () {
      final result = _run(['--version']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Open Audio Analyzer'));
    });

    test('--list-targets lists the built-in delivery targets', () {
      final result = _run(['--list-targets']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('streaming-14'));
      expect(result.stdout, contains('ebu-r128'));
    });

    test('no arguments is an error, and the error goes to stderr', () {
      final result = _run([]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('no input files'));
      expect(result.stdout, isEmpty, reason: 'stdout stays pipeable');
    });

    test('an unknown target is refused rather than ignored', () {
      final file = _writeWav('tone.wav', 0.2, 1.0);
      final result = _run(['--target', 'nonsense', file.path]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('unknown target'));
    });

    test('a missing file is an error, not an empty report', () {
      final result = _run(['${_temp.path}/absent.wav']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('no such file'));
    });

    test('a file that is not audio is refused', () {
      final junk = File('${_temp.path}/notes.txt')
        ..writeAsStringSync('not audio');
      final result = _run([junk.path]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('decode'));
    });
  });

  group('exit codes gate a pipeline', () {
    test('a compliant file exits 0', () {
      // 0.1993 measures -14.0 LUFS, which is the streaming target exactly.
      final file = _writeWav('compliant.wav', 0.1993, 8.0);
      final result = _run(['-q', '--target', 'streaming-14', file.path]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('VERDICT: PASS'));
    });

    test('a file that misses its target exits 2, not 0', () {
      final file = _writeWav('compliant.wav', 0.1993, 8.0);
      final result = _run(['-q', '--target', 'ebu-r128', file.path]);

      expect(
        result.exitCode,
        2,
        reason: 'a build must be able to fail on this',
      );
      expect(result.stdout, contains('VERDICT: FAIL'));
    });

    test('without a target there is no verdict and it exits 0', () {
      final file = _writeWav('tone.wav', 0.1993, 4.0);
      final result = _run(['-q', file.path]);

      expect(result.exitCode, 0);
      expect(result.stdout, isNot(contains('VERDICT')));
    });
  });

  group('formats', () {
    test('json parses, and carries the measurements and the verdict', () {
      final file = _writeWav('tone.wav', 0.1993, 5.0);
      final result = _run([
        '-q',
        '--format',
        'json',
        '--target',
        'streaming-14',
        file.path,
      ]);

      final decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final source = decoded['source']! as Map<String, Object?>;
      expect(source['sample_rate'], 48000);
      expect(source['channels'], 2);
      expect(source['bits_per_sample'], 24);
      expect(source['format'], 'WAV');

      final measurements = decoded['measurements']! as Map<String, Object?>;
      expect(measurements['lufs_i'], closeTo(-14.0, 0.3));

      expect(decoded['compliance'], isA<Map<String, Object?>>());
    });

    test('json omits the timeline unless it is asked for', () {
      final file = _writeWav('tone.wav', 0.1993, 4.0);

      final without =
          jsonDecode(
                _run(['-q', '--format', 'json', file.path]).stdout as String,
              )
              as Map<String, Object?>;
      expect(without.containsKey('timeline'), isFalse);

      final with_ =
          jsonDecode(
                _run(['-q', '--format', 'json', '--timeline', file.path]).stdout
                    as String,
              )
              as Map<String, Object?>;
      expect(with_['timeline'], isA<List<Object?>>());
    });

    test('csv is a header plus one row per timeline point', () {
      final file = _writeWav('tone.wav', 0.1993, 2.0);
      final result = _run(['-q', '--format', 'csv', file.path]);
      final lines = (result.stdout as String).trim().split('\n');

      expect(lines.first, 'seconds,lufs_m,lufs_s,true_peak_dbtp');
      expect(lines.length, greaterThan(15), reason: '2 s at 100 ms steps');
      expect(lines[1], matches(r'^\d+\.\d{3},'));
    });

    test('csv refuses several files rather than writing only the last', () {
      final a = _writeWav('a.wav', 0.2, 1.0);
      final b = _writeWav('b.wav', 0.2, 1.0);
      final result = _run(['-q', '--format', 'csv', a.path, b.path]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('one file'));
    });

    test('--output writes the report to disk and says so on stderr', () {
      final file = _writeWav('tone.wav', 0.1993, 3.0);
      final out = '${_temp.path}/report.txt';
      final result = _run(['-q', '-o', out, file.path]);

      expect(result.exitCode, 0);
      expect(File(out).readAsStringSync(), contains('analysis report'));
      expect(result.stderr, contains('wrote'));
      expect(result.stdout, isEmpty);
    });
  });

  group('measurement', () {
    test('a mono file is analysed as mono, not silently upmixed', () {
      final file = _writeWav('mono.wav', 0.1993, 3.0, channels: 1);
      final result = _run(['-q', '--format', 'json', file.path]);
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;

      final source = decoded['source']! as Map<String, Object?>;
      expect(source['channels'], 1);

      final measurements = decoded['measurements']! as Map<String, Object?>;
      expect(measurements['channel_peak_max'], hasLength(1));
    });

    test('several files each get their own report', () {
      final a = _writeWav('a.wav', 0.1993, 2.0);
      final b = _writeWav('b.wav', 0.05, 2.0);
      final result = _run(['-q', a.path, b.path]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('a.wav'));
      expect(result.stdout, contains('b.wav'));
    });
  });
}
