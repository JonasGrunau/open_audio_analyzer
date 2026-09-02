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

// The output is decoded as UTF-8 because that is what the CLI writes.
// Process.run's default is systemEncoding, which on Windows is the ANSI code
// page — every non-ASCII character then reads back as mojibake, and an
// assertion on a target line's '≥' fails on exactly one platform while the
// tool itself is fine.
ProcessResult _run(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['run', _entryPoint, ...args],
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

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
      // The one built-in with a dynamics floor, listed like any other limit.
      expect(result.stdout, contains('dynamic-master'));
      expect(result.stdout, contains('PSR ≥ 8.0 LU'));
    });

    // --- The user's own delivery targets ---------------------------------
    //
    // The CLI knew only the six built-ins, while the app merged the user's
    // `calibrations/` files over them by id. So a corrected `atsc-a85.json`
    // gave one verdict in the window and another from the exit code a release
    // pipeline reads — from the same file, about the same master. These use
    // `--config-dir` rather than the real configuration directory, so the
    // suite never depends on what the developer happens to have saved.

    /// Writes a delivery target into a config directory the CLI will read.
    Directory configWith(String fileName, Map<String, Object?> json) {
      final root = Directory('${_temp.path}/config-${json['id']}')
        ..createSync(recursive: true);
      Directory('${root.path}/calibrations').createSync();
      File(
        '${root.path}/calibrations/$fileName',
      ).writeAsStringSync(jsonEncode(json));
      return root;
    }

    test('a target the user wrote is offered', () {
      final config = configWith('house.json', {
        'id': 'house',
        'name': 'House standard',
        'lufs_target': -18.0,
        'true_peak_max': -3.0,
      });

      final result = _run(['--config-dir', config.path, '--list-targets']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('house'));
      expect(result.stdout, contains('House standard'));
      // Still with the built-ins beside it, not instead of them.
      expect(result.stdout, contains('streaming-14'));
    });

    test('a user file replaces the built-in of the same id', () {
      // The whole point of the merge: our reading of a published spec is
      // correctable without a release, and the correction has to reach the
      // exit code as well as the window.
      final config = configWith('ebu.json', {
        'id': 'ebu-r128',
        'name': 'EBU R 128, corrected',
        'lufs_target': -23.0,
        'lufs_tolerance': 0.1,
        'true_peak_max': -1.0,
      });

      final result = _run(['--config-dir', config.path, '--list-targets']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('EBU R 128, corrected'));
      expect(result.stdout, contains('±0.1 LUFS'));
      expect(result.stdout, isNot(contains('EBU R 128 (broadcast)')));
    });

    test('a user target decides the exit code', () {
      // The tone is around -14 LUFS, so it passes streaming-14 and misses a
      // target set well below it. If the CLI were still reading only the
      // built-ins this would exit 1 — unknown target — rather than 2.
      final file = _writeWav('house.wav', 0.1993, 4.0);
      final config = configWith('strict.json', {
        'id': 'strict',
        'name': 'Strict house target',
        'lufs_target': -30.0,
        'lufs_tolerance': 0.5,
        'true_peak_max': -1.0,
      });

      final result = _run([
        '-q',
        '--config-dir',
        config.path,
        '--target',
        'strict',
        file.path,
      ]);
      expect(result.exitCode, 2, reason: 'stderr: ${result.stderr}');
    });

    test('a target file that will not parse is skipped, not fatal', () {
      final root = Directory('${_temp.path}/config-broken')
        ..createSync(recursive: true);
      Directory('${root.path}/calibrations').createSync();
      File(
        '${root.path}/calibrations/broken.json',
      ).writeAsStringSync('{ not json');

      final result = _run(['--config-dir', root.path, '--list-targets']);

      // One unreadable file must not turn the library into "no targets" — the
      // next thing that happens is an exit code somebody trusts.
      expect(result.exitCode, 0);
      expect(result.stdout, contains('streaming-14'));
      expect(result.stderr, contains('ignoring'));
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

    test('a dynamics floor is a fourth check, and it can fail the build', () {
      // A steady 1 kHz sine has an ODR-I of exactly 0 LU — its true peak and its
      // loudness are the same number (see the engine's conformance suite), so
      // it is the most compressed programme there is. A floor the platform
      // built-ins do not set is what makes this a fourth line rather than a
      // third one moving: the same file passes the same numbers without it.
      final root = Directory('${_temp.path}/config-floor')
        ..createSync(recursive: true);
      Directory('${root.path}/calibrations').createSync();
      File('${root.path}/calibrations/house.json').writeAsStringSync(
        jsonEncode({
          'id': 'house-dynamic',
          'name': 'House, dynamic',
          'lufs_target': -14.0,
          'true_peak_max': -1.0,
          'odr_i_min': 8.0,
        }),
      );
      final file = _writeWav('squashed.wav', 0.1993, 8.0);

      final listed = _run(['--config-dir', root.path, '--list-targets']);
      expect(listed.stdout, contains('PLR ≥ 8.0 LU'));

      final result = _run([
        '-q',
        '--config-dir',
        root.path,
        '--target',
        'house-dynamic',
        file.path,
      ]);
      expect(result.exitCode, 2);
      expect(result.stdout, contains('PLR'));
      expect(result.stdout, isNot(contains('ODR-I')));
      // The Annex A band word, printed after the reading in the text report:
      // 0 LU is the flattest band there is.
      expect(result.stdout, contains('(flat)'));
      expect(result.stdout, contains('VERDICT: FAIL'));

      // The same run under the specification's own names: the same numbers,
      // the same verdict, and only the labels move. The app has the same
      // switch in its settings; the CLI reads no settings file, so it is a
      // flag here.
      final odr = _run([
        '-q',
        '--names',
        'odr',
        '--config-dir',
        root.path,
        '--target',
        'house-dynamic',
        file.path,
      ]);
      expect(odr.exitCode, 2);
      expect(odr.stdout, contains('ODR-I'));
      expect(odr.stdout, isNot(contains('PLR')));
      expect(odr.stdout, contains('(flat)'));
      expect(
        _run([
          '--names',
          'odr',
          '--config-dir',
          root.path,
          '--list-targets',
        ]).stdout,
        contains('ODR-I ≥ 8.0 LU'),
      );
      expect(_run(['--names', 'dr', file.path]).exitCode, 1);
    });

    test(
      'the lowest ODR-S is reported, and an ODR-S floor is checked against it',
      () {
        // The same steady sine: its ODR-S is 0 LU for every one of its three
        // seconds, so the minimum is 0 and a floor of 6 fails it. In the JSON it
        // is `odr_s_min`, and it is a number rather than null — the tone clears
        // the absolute gate, so the ratio was defined throughout.
        final root = Directory('${_temp.path}/config-psr')
          ..createSync(recursive: true);
        Directory('${root.path}/calibrations').createSync();
        File('${root.path}/calibrations/strict.json').writeAsStringSync(
          jsonEncode({
            'id': 'house-strict',
            'name': 'House, strict',
            'lufs_target': -14.0,
            'true_peak_max': -1.0,
            'odr_s_min': 6.0,
          }),
        );
        final file = _writeWav('steady.wav', 0.1993, 8.0);

        final listed = _run(['--config-dir', root.path, '--list-targets']);
        expect(listed.stdout, contains('PSR ≥ 6.0 LU'));

        final json = _run(['-q', '--format', 'json', file.path]);
        final decoded =
            jsonDecode(json.stdout as String) as Map<String, Object?>;
        final measurements = decoded['measurements'] as Map<String, Object?>;
        expect(
          (measurements['odr_s_min'] as num).toDouble(),
          closeTo(0.0, 0.1),
        );

        final result = _run([
          '-q',
          '--config-dir',
          root.path,
          '--target',
          'house-strict',
          file.path,
        ]);
        expect(result.exitCode, 2);
        expect(result.stdout, contains('PSR'));
        expect(result.stdout, contains('VERDICT: FAIL'));
      },
    );

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
