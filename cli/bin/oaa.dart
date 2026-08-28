// The `oaa` command-line analyser.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This exists so that a loudness check can be a step in a release pipeline
// rather than something a human remembers to do. It runs the same engine the
// app does, over the same decoder, so `oaa analyze master.wav` and dropping
// master.wav on the app produce the same numbers — and if they ever do not,
// that is a bug in exactly one shared code path rather than a difference of
// opinion between two implementations.
//
// The exit code is the point of the whole thing. With `--target`, a file that
// misses its delivery spec exits non-zero, which is what lets a build fail on
// a master that is 2 LU too loud instead of shipping it.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';

/// What `oaa` reports back to the shell.
///
/// Three outcomes rather than the usual two, because "the file failed its
/// delivery target" and "the file could not be read" are different problems
/// and a pipeline should be able to tell them apart.
abstract final class ExitCode {
  /// Analysed, and compliant if a target was given.
  static const int ok = 0;

  /// Bad arguments, unreadable file, unsupported format.
  static const int error = 1;

  /// Analysed successfully, but missed the delivery target.
  static const int nonCompliant = 2;
}

const String _version = 'Open Audio Analyzer 0.11.0';

Future<void> main(List<String> arguments) async {
  final parser = _buildParser();

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('oaa: ${error.message}');
    stderr.writeln();
    stderr.writeln(_usage(parser));
    exit(ExitCode.error);
  }

  if (args.flag('help')) {
    stdout.writeln(_usage(parser));
    return;
  }

  if (args.flag('version')) {
    stdout.writeln('$_version (engine ${OaaEngine.versionString})');
    return;
  }

  if (args.flag('list-targets')) {
    _listTargets(_targets(args.option('config-dir')));
    return;
  }

  final paths = args.rest;
  if (paths.isEmpty) {
    stderr.writeln('oaa: no input files');
    stderr.writeln();
    stderr.writeln(_usage(parser));
    exit(ExitCode.error);
  }

  final ReportFormat format;
  try {
    format = _formatFrom(args.option('format')!);
  } on ArgumentError catch (error) {
    stderr.writeln('oaa: ${error.message}');
    exit(ExitCode.error);
  }

  // The built-ins with the user's own files over them. The app has always done
  // this; the CLI knew only the built-ins, so a corrected `atsc-a85.json` gave
  // one verdict in the window and another from the exit code a pipeline reads.
  final targets = _targets(args.option('config-dir'));

  Calibration? target;
  final targetId = args.option('target');
  if (targetId != null) {
    target = _byId(targets, targetId);
    if (target == null) {
      stderr.writeln('oaa: unknown target "$targetId"');
      stderr.writeln('oaa: run `oaa --list-targets` to see them');
      exit(ExitCode.error);
    }
  }

  // CSV is one timeline, and a file column bolted on so that several could
  // share a table would make the common case worse to serve a case nobody
  // asked for. Say so rather than silently writing only the last one.
  if (format == ReportFormat.csv && paths.length > 1) {
    stderr.writeln(
      'oaa: --format csv writes one timeline, so it takes one file '
      '(${paths.length} given)',
    );
    exit(ExitCode.error);
  }

  final outputPath = args.option('output');
  if (outputPath != null && paths.length > 1) {
    stderr.writeln('oaa: --output takes one file (${paths.length} given)');
    exit(ExitCode.error);
  }

  final int timelineMs;
  final intervalText = args.option('timeline-interval')!;
  final parsedInterval = int.tryParse(intervalText);
  if (parsedInterval == null || parsedInterval <= 0) {
    stderr.writeln(
      'oaa: --timeline-interval must be a positive number of '
      'milliseconds, got "$intervalText"',
    );
    exit(ExitCode.error);
  }
  timelineMs = parsedInterval;

  // Progress goes to stderr and the reporter itself declines when stderr is
  // not a terminal, so this only has to honour an explicit --quiet.
  final quiet = args.flag('quiet');
  final wantTimeline = args.flag('timeline');

  var worstExit = ExitCode.ok;
  final rendered = <String>[];

  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('oaa: no such file: $path');
      worstExit = ExitCode.error;
      continue;
    }

    final OfflineResult result;
    try {
      result = analyseFile(
        path,
        timelineInterval: Duration(milliseconds: timelineMs),
        onProgress: quiet ? null : _progressReporter(path),
      );
    } on OaaFileException catch (error) {
      stderr.writeln('oaa: ${error.message}: $path');
      worstExit = ExitCode.error;
      continue;
    } on OaaEngineException catch (error) {
      stderr.writeln('oaa: ${error.message}');
      worstExit = ExitCode.error;
      continue;
    }

    if (!quiet) stderr.writeln();

    final report = _toReport(
      result,
      path: path,
      target: target,
      includeTimeline: wantTimeline || format == ReportFormat.csv,
    );

    rendered.add(exportReport(report, format));

    if (target != null && !report.isCompliant && worstExit == ExitCode.ok) {
      worstExit = ExitCode.nonCompliant;
    }
  }

  if (rendered.isEmpty) exit(worstExit);

  final body = rendered.join('\n');

  if (outputPath != null) {
    File(outputPath).writeAsStringSync(body);
    stderr.writeln('oaa: wrote $outputPath');
  } else {
    stdout.write(body);
  }

  exit(worstExit);
}

/// Turns an [OfflineResult] into the domain object the exports understand.
///
/// The two are deliberately separate types: `oaa_engine` measures and knows
/// nothing about delivery targets, `oaa_core` interprets and knows nothing
/// about `dart:ffi`. This function is the seam, and it is the only place in
/// the CLI where both are in scope.
AnalysisReport _toReport(
  OfflineResult result, {
  required String path,
  required Calibration? target,
  required bool includeTimeline,
}) {
  return AnalysisReport(
    fileName: path.split(Platform.pathSeparator).last,
    filePath: File(path).absolute.path,
    formatLabel: result.formatLabel,
    sampleRate: result.sampleRate,
    channels: result.channels,
    bitsPerSample: result.bitsPerSample,
    durationSeconds: result.durationSeconds,
    generatedAt: DateTime.now(),
    lufsIntegrated: result.lufsIntegrated,
    loudnessRange: result.loudnessRange,
    loudnessRangeLow: result.loudnessRangeLow,
    loudnessRangeHigh: result.loudnessRangeHigh,
    truePeakMax: result.truePeakMax,
    samplePeakMax: result.samplePeakMax,
    momentaryMax: result.momentaryMax,
    shortTermMax: result.shortTermMax,
    shortTermMin: result.shortTermMin,
    odrShortMin: result.odrShortMin,
    correlationMin: result.correlationMin,
    correlationMax: result.correlationMax,
    correlationMean: result.correlationMean,
    channelPeakMax: result.channelPeakMax,
    calibration: target,
    timeline: includeTimeline
        ? [
            for (final point in result.timeline)
              ReportTimelinePoint(
                seconds: point.seconds,
                momentary: point.momentary,
                shortTerm: point.shortTerm,
                truePeak: point.truePeak,
              ),
          ]
        : const [],
    toolVersion: _version,
  );
}

/// Progress on stderr, so that stdout stays a clean pipe.
///
/// Rewritten in place with a carriage return rather than scrolled, and only
/// when stderr is a terminal — redirected into a log file, a progress bar is
/// thousands of lines of noise around the one line that mattered.
OfflineProgress? _progressReporter(String path) {
  if (stdioType(stderr) != StdioType.terminal) return null;

  final name = path.split(Platform.pathSeparator).last;
  return (seconds, totalSeconds) {
    if (totalSeconds > 0) {
      final percent = (seconds / totalSeconds * 100).clamp(0, 100).round();
      stderr.write('\r  analysing $name  $percent%   ');
    } else {
      stderr.write('\r  analysing $name  ${formatDuration(seconds)}   ');
    }
  };
}

/// Every delivery target available here: the built-ins, with the user's own
/// files laid over them by id.
///
/// Reads the same directory the app writes, resolved by the same rules — see
/// `resolveConfigRoot` in `oaa_core`, which is why that function lives there
/// rather than in the app. A file that will not parse is skipped with a word to
/// stderr rather than taken as an empty library: an unreadable target must not
/// silently become "no such target", because the next thing that happens is an
/// exit code somebody trusts.
///
/// [override] is `--config-dir`, which beats the environment, which beats the
/// platform's convention.
List<Calibration> _targets(String? override) {
  final root = resolveConfigRoot(
    operatingSystem: Platform.operatingSystem,
    environment: Platform.environment,
    override: override,
    temporaryDirectory: Directory.systemTemp.path,
  );
  if (root == null) return BuiltInCalibrations.all;

  final directory = Directory(
    '$root${Platform.pathSeparator}${ConfigDir.calibrations}',
  );
  if (!directory.existsSync()) return BuiltInCalibrations.all;

  final user = <Calibration>[];
  try {
    final entries = directory.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final entry in entries) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(entry.readAsStringSync());
        if (decoded is! Map) throw const FormatException('not a JSON object');
        user.add(Calibration.fromJson(decoded.cast<String, Object?>()));
      } on Object catch (error) {
        stderr.writeln('oaa: ignoring ${entry.path}: $error');
      }
    }
  } on FileSystemException catch (error) {
    stderr.writeln('oaa: could not read ${directory.path}: ${error.message}');
  }

  return mergeCalibrations(BuiltInCalibrations.all, user);
}

Calibration? _byId(List<Calibration> targets, String id) {
  for (final target in targets) {
    if (target.id == id) return target;
  }
  return null;
}

void _listTargets(List<Calibration> targets) {
  stdout.writeln('Delivery targets:');
  stdout.writeln();
  for (final target in targets) {
    stdout.writeln('  ${target.id.padRight(14)}${target.name}');
    final integratedFloor = target.odrIntegratedFloor;
    final shortFloor = target.odrShortFloor;
    stdout.writeln(
      '  ${' '.padRight(14)}'
      '${target.lufsTarget.toStringAsFixed(1)} '
      '±${target.lufsTolerance.toStringAsFixed(1)} LUFS, '
      '≤ ${target.truePeakMax.toStringAsFixed(1)} dBTP, '
      'LRA ≤ ${target.loudnessRangeMax.toStringAsFixed(1)} LU'
      '${integratedFloor == null ? '' : ', ODR-I ≥ ${integratedFloor.toStringAsFixed(1)} LU'}'
      '${shortFloor == null ? '' : ', ODR-S ≥ ${shortFloor.toStringAsFixed(1)} LU'}',
    );
    stdout.writeln();
  }
}

ReportFormat _formatFrom(String name) {
  for (final format in ReportFormat.values) {
    if (format.extension == name) return format;
  }
  throw ArgumentError(
    'unknown format "$name" — expected one of '
    '${ReportFormat.values.map((f) => f.extension).join(', ')}',
  );
}

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'format',
    abbr: 'f',
    help: 'Output format.',
    allowed: ['txt', 'json', 'csv'],
    allowedHelp: {
      'txt': 'Human-readable summary.',
      'json': 'Every measurement and the verdict, for scripts.',
      'csv': 'The loudness timeline, one row per point.',
    },
    defaultsTo: 'txt',
  )
  ..addOption(
    'target',
    abbr: 't',
    help: 'Delivery target to judge against. Exits 2 if the file misses it.',
    valueHelp: 'id',
  )
  ..addOption(
    'output',
    abbr: 'o',
    help: 'Write to a file instead of stdout.',
    valueHelp: 'path',
  )
  ..addOption(
    'config-dir',
    help:
        'Where to read your own delivery targets from. Defaults to the same '
        'directory the app uses.',
    valueHelp: 'path',
  )
  ..addOption(
    'timeline-interval',
    help: 'Milliseconds of signal between timeline points.',
    valueHelp: 'ms',
    defaultsTo: '100',
  )
  ..addFlag(
    'timeline',
    help: 'Include the timeline in JSON output. Always on for CSV.',
    negatable: false,
  )
  ..addFlag('list-targets', help: 'List delivery targets.', negatable: false)
  ..addFlag('quiet', abbr: 'q', help: 'No progress output.', negatable: false)
  ..addFlag('version', help: 'Print the version.', negatable: false)
  ..addFlag('help', abbr: 'h', help: 'Print this help.', negatable: false);

String _usage(ArgParser parser) =>
    '''
$_version — loudness and true-peak analysis

Usage:  oaa [options] <file>...

Measures a file against ITU-R BS.1770-4 and EBU R 128, using the same engine
and the same decoder the Open Audio Analyzer app does. WAV, AIFF, RF64, Wave64, FLAC and MP3.

Options:
${parser.usage}

Exit codes:
  ${ExitCode.ok}  analysed, and compliant if --target was given
  ${ExitCode.error}  bad arguments, or a file that could not be read
  ${ExitCode.nonCompliant}  analysed, but missed the delivery target

Examples:
  oaa master.wav
  oaa --target streaming-14 master.wav
  oaa --format json --timeline master.wav > report.json
  oaa --format csv -o loudness.csv master.wav
''';
