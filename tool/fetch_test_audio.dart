// tool/fetch_test_audio.dart — the music this repository tests against.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ---------------------------------------------------------------------------
// Why a script rather than a checked-in file
//
// Every measurement in Open Audio Analyzer is held against a signal whose
// answer is known in advance: a sine of amplitude A peaks at A, the EBU
// conformance vectors read what R128 says they read. Those are the tests, and
// they are the right tests.
//
// None of them tell you what the application looks like with music in it. The
// spectrogram, the stereo cloud, the histogram and the loudness range only
// become judgeable on real material — a tone produces a single bright line and
// a cloud that is a dot, which is correct and tells you nothing. `CLAUDE.md`
// says to run the app and look at a module before calling it finished; this is
// what you look at it with.
//
// The file itself is not committed. It is 33 MB of somebody else's music, and a
// repository that carries it pays for it in every clone forever to record a URL
// we can record in one line.
//
// ---------------------------------------------------------------------------
// What it fetches, and why this track
//
// Two tracks from "Citizens of the Empire" (2010) by Citizens Of The Empire,
// post-rock, released under **CC BY 3.0** — attribution only, no
// non-commercial and no share-alike clause. That matters twice over: anyone who
// clones this repository can use it whatever they are doing, and a screencast
// or a bug report containing it does not inherit a licence. It rules out most
// of the freely-downloadable catalogue, which is BY-NC, BY-ND or BY-SA.
//
// The material was chosen by measuring candidates rather than by reading track
// titles. `oaa` on the default track reports:
//
//   LUFS-I -8.6     a loud modern master, so a -14 LUFS target fails and the
//                   delivery verdict has something to say
//   LRA    10.3 LU  real dynamic range rather than a squashed one
//   TP Max -0.0 dBTP against a sample peak of -0.2 dBFS — the true peak is
//                   *above* the sample peak, which is the one case 4x
//                   oversampling exists for and one a tone cannot produce
//   corr   0.76, ranging -0.11 to 1.00 — the stereo field actually moves, so
//                   the phase scope and the stereo cloud have something to draw
//
// A sine gives none of that: correlation pinned at 1.00, one spectrum bin, an
// LRA of zero, and a true peak that never exceeds the sample peak.
//
// `--all` adds track 6 from the same album — quieter at -10.0 LUFS and more
// dynamic at 12.9 LU. One attribution covers both.
//
// ---------------------------------------------------------------------------
// Why Wikimedia and not the Internet Archive
//
// The first version fetched a CC BY track from archive.org. Its URLs are about
// the most stable on the web and its metadata API hands out per-file checksums,
// which is most of what this script wants. What it could not do was serve the
// bytes: the storage node holding that item answered 503 or timed out for hours
// on end — in this script, in curl, and in a browser — while the rest of the
// site stayed up, and at its best it managed 0.18 MB/s.
//
// `upload.wikimedia.org` served the same size of file at 2.3-3.7 MB/s first
// try, its URLs are content-addressed and permanent, and the Commons API gives
// licence, size and SHA-1 for every file — so the manifest below was generated
// from the authority rather than transcribed by hand.
//
// ---------------------------------------------------------------------------
// No dependencies
//
// `dart:io` and nothing else, for the same reason `tool/docs.dart` has none:
// this has to work from a bare Dart SDK, before `pub get`, on a machine with no
// Flutter. That is also why the download is verified by exact byte count and
// magic number rather than by a hash — the SDK ships no SHA-1, and adding
// `package:crypto` to reach one would cost more than it buys. The expected
// digest is printed so it can be checked by hand; a truncated or resumed-wrong
// download fails the length check, which is the failure that actually happens.
//
//   dart run tool/fetch_test_audio.dart
//   dart run tool/fetch_test_audio.dart --all --out=/tmp/audio

import 'dart:io';

/// One downloadable file, with everything needed to verify it.
class Track {
  const Track({
    required this.localName,
    required this.url,
    required this.pageUrl,
    required this.bytes,
    required this.sha1,
    required this.seconds,
    required this.title,
    required this.extra,
  });

  /// Deliberately not the remote name. Commons stores these with the whole
  /// track title in the filename, and this repository has already shipped one
  /// release bug caused by a filename with spaces in it going through a shell.
  final String localName;

  /// The full download URL. Commons shards by a hash of the name rather than
  /// keeping an item directory, so there is no base path to share.
  final String url;

  /// The Commons file page, which is where the licence is actually stated.
  final String pageUrl;

  final int bytes;
  final String sha1;
  final double seconds;
  final String title;

  /// Not fetched by default. See `--all`.
  final bool extra;
}

const String _artist = 'Citizens Of The Empire';
const String _album = 'Citizens of the Empire';
const String _licence = 'CC BY 3.0 — https://creativecommons.org/licenses/by/3.0';
const String _credit = 'https://citizensoftheempire.bandcamp.com/';

const String _commons = 'https://upload.wikimedia.org/wikipedia/commons/';
const String _commonsPage = 'https://commons.wikimedia.org/wiki/File:';

const List<Track> _tracks = <Track>[
  Track(
    localName: 'citizens-apathy.flac',
    url:
        '${_commons}f/fb/Citizens_Of_The_Empire_-_03_Apathy_And_Resignation_'
        'Are_The_Sources_Of_Our_Misfortune.flac',
    pageUrl:
        '${_commonsPage}Citizens_Of_The_Empire_-_03_Apathy_And_Resignation_'
        'Are_The_Sources_Of_Our_Misfortune.flac',
    bytes: 36267561,
    sha1: '9e99a52983845e753fc0f3bad10165c1385e9838',
    seconds: 322.4,
    title: 'Apathy And Resignation Are The Sources Of Our Misfortune',
    extra: false,
  ),
  Track(
    localName: 'citizens-everything.flac',
    url:
        '${_commons}6/6a/Citizens_Of_The_Empire_-_06_Everything_We_Possess_'
        'Will_In_Turn_Possess_Us.flac',
    pageUrl:
        '${_commonsPage}Citizens_Of_The_Empire_-_06_Everything_We_Possess_'
        'Will_In_Turn_Possess_Us.flac',
    bytes: 39393487,
    sha1: 'f7facd8cd8b206e1aa563310ce35b71b3885b12a',
    seconds: 412.2,
    title: 'Everything We Possess Will In Turn Possess Us',
    extra: true,
  ),
];

/// FLAC's four-byte signature. Checked because the one failure mode a length
/// check misses is a server returning an error page of exactly the right size,
/// and because it costs four bytes to rule out.
const List<int> _flacMagic = <int>[0x66, 0x4C, 0x61, 0x43]; // "fLaC"

// Sets `exitCode` rather than returning one. A `Future<int> main()` compiles
// and the value is discarded, so `dart run tool/fetch_test_audio.dart` exited 0
// after a failed download — a CI step guarding on this script's status would
// have reported success for as long as it existed.
Future<void> main(List<String> arguments) async {
  var outPath = 'test_audio';
  var wantAll = false;
  var force = false;

  for (final argument in arguments) {
    if (argument == '--all') {
      wantAll = true;
    } else if (argument == '--force') {
      force = true;
    } else if (argument == '--list') {
      _printManifest();
      return;
    } else if (argument.startsWith('--out=')) {
      outPath = argument.substring('--out='.length);
    } else if (argument == '--help' || argument == '-h') {
      _printUsage();
      return;
    } else {
      stderr.writeln('fetch_test_audio: unrecognised argument: $argument');
      _printUsage();
      exitCode = 2;
      return;
    }
  }

  final out = Directory(outPath);
  await out.create(recursive: true);

  final wanted = _tracks.where((t) => wantAll || !t.extra).toList();

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    // Named so that the archive's logs say who this is. A tool that fetches
    // 33 MB anonymously is indistinguishable from a scraper.
    ..userAgent = 'open-audio-analyzer/fetch-test-audio';

  var failures = 0;
  try {
    for (final track in wanted) {
      final file = File(
        '${out.path}${Platform.pathSeparator}${track.localName}',
      );

      if (!force && await _isComplete(file, track)) {
        stdout.writeln('have  ${track.localName}  (${_mb(track.bytes)})');
        continue;
      }

      if (!await _download(client, track, file)) {
        failures++;
      }
    }
  } finally {
    client.close(force: true);
  }

  // Only what is actually on disk. An attribution file naming a track the
  // download never produced is a file that lies about what these bytes are.
  final present = <Track>[];
  for (final track in wanted) {
    final file = File('${out.path}${Platform.pathSeparator}${track.localName}');
    if (await file.exists()) present.add(track);
  }
  if (present.isNotEmpty) await _writeAttribution(out, present);

  if (failures > 0) {
    stderr.writeln(
      '\nfetch_test_audio: $failures of ${wanted.length} download(s) failed. '
      'The archive answers 503 when the node it redirects to is busy; running '
      'this again usually lands on a different one, and a partial file is '
      'resumed rather than restarted.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '\nIn ${out.path}. Attribution is in ATTRIBUTION.md beside '
    'the audio — the licence requires it if you publish anything made with '
    'these files.',
  );
}

/// True when [file] is byte-for-byte the length the manifest expects and starts
/// with FLAC's signature.
///
/// Length alone would accept a file that was resumed from a stale partial
/// download of a different track; the signature alone would accept a truncated
/// one. Together they are enough for material whose real integrity check is
/// that the decoder opens it.
Future<bool> _isComplete(File file, Track track) async {
  if (!await file.exists()) return false;
  if (await file.length() != track.bytes) return false;

  final handle = await file.open();
  try {
    final head = await handle.read(4);
    for (var i = 0; i < _flacMagic.length; i++) {
      if (head[i] != _flacMagic[i]) return false;
    }
  } finally {
    await handle.close();
  }

  return true;
}

/// Fetches [track] into [file], resuming a partial file rather than restarting
/// it.
///
/// Resume is not a nicety here. The archive's nodes are frequently slow — a
/// 33 MB file can take minutes — and a connection that drops at 90% on a tool
/// with no resume is a tool that never finishes on a bad line.
Future<bool> _download(HttpClient client, Track track, File file) async {
  const attempts = 4;

  for (var attempt = 1; attempt <= attempts; attempt++) {
    if (attempt > 1) {
      // The archive answers 503 when the node it redirected to is loaded, and
      // retrying straight away asks the same node again. Backing off gives it
      // time and makes a second, different redirect likely.
      final pause = Duration(seconds: 1 << attempt);
      stdout.writeln('      waiting ${pause.inSeconds}s, then retrying');
      await Future<void>.delayed(pause);
    }

    var have = await file.exists() ? await file.length() : 0;

    if (have > track.bytes) {
      // Longer than it should be: this is not a partial copy of this track.
      await file.delete();
      have = 0;
    }

    if (have == track.bytes) break;

    final label = have > 0 ? 'resume' : 'get   ';
    stdout.writeln(
      '$label ${track.localName}  '
      '(${_mb(have)} of ${_mb(track.bytes)})',
    );

    try {
      final request = await client.getUrl(
        Uri.parse(_base + _encode(track.remoteName)),
      );
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }

      final response = await request.close();

      // 206 for a resumed range, 200 for a whole file. A 200 in answer to a
      // Range request means the server ignored it, so the bytes that arrive
      // start at zero and appending them would corrupt the file.
      if (response.statusCode == HttpStatus.ok && have > 0) {
        await file.delete();
        have = 0;
      } else if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        stderr.writeln(
          '      HTTP ${response.statusCode} — attempt $attempt of $attempts',
        );
        await response.drain<void>();
        continue;
      }

      final sink = file.openWrite(
        mode: have > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    } on Object catch (error) {
      stderr.writeln('      $error — attempt $attempt of $attempts');
      continue;
    }

    if (await _isComplete(file, track)) {
      stdout.writeln(
        'ok    ${track.localName}  ${track.seconds.round()} s  '
        'sha1 ${track.sha1}',
      );
      return true;
    }

    stderr.writeln('      incomplete after attempt $attempt of $attempts');
  }

  final got = await file.exists() ? await file.length() : 0;
  stderr.writeln(
    'failed ${track.localName}: got ${_mb(got)}, '
    'expected ${_mb(track.bytes)}.',
  );
  return false;
}

/// Percent-encodes a path segment. `Uri.encodeComponent` would also escape the
/// slashes, which there are none of, but being explicit about what is being
/// encoded is worth the sentence.
String _encode(String segment) => Uri.encodeComponent(segment);

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Writes the attribution beside the audio.
///
/// The files are gitignored, so nothing in the repository records where they
/// came from. CC BY requires attribution from anyone who redistributes or
/// publishes work made with them — a screenshot in an issue, a demo video —
/// and the obligation has to travel with the file rather than living in a
/// script somebody ran once.
Future<void> _writeAttribution(Directory out, List<Track> tracks) async {
  final lines = <String>[
    '# Test audio — attribution',
    '',
    'Downloaded by `tool/fetch_test_audio.dart`. Not part of Open Audio',
    'Analyzer and not covered by its licence.',
    '',
    '| File | Track | Artist | Album |',
    '|------|-------|--------|-------|',
    for (final track in tracks)
      '| `${track.localName}` | ${track.title} | $_artist | $_album |',
    '',
    '- Licence: $_licence',
    '- Source: $_source',
    '',
    'CC BY requires credit if you publish anything that includes this audio —',
    'a demo recording, a screencast, a bug report with sound. Credit',
    '"$_artist — ${_tracks.first.title} (CC BY 3.0)" and link the source.',
    '',
  ];

  await File(
    '${out.path}${Platform.pathSeparator}ATTRIBUTION.md',
  ).writeAsString(lines.join('\n'));
}

void _printManifest() {
  stdout.writeln('$_artist — $_album');
  stdout.writeln('  $_licence');
  stdout.writeln('  $_source');
  stdout.writeln('');
  for (final track in _tracks) {
    stdout.writeln(
      '  ${track.localName.padRight(16)} '
      '${_mb(track.bytes).padLeft(9)}  ${track.seconds.round()} s  '
      '${track.extra ? "--all only" : "default"}',
    );
    stdout.writeln('    sha1 ${track.sha1}');
  }
}

void _printUsage() {
  stdout.writeln('''
Downloads the Creative Commons test music this repository is exercised with.

  dart run tool/fetch_test_audio.dart [options]

  --out=<dir>   Where to put it. Default test_audio, which is gitignored.
  --all         Also fetch the longer, more dynamic second track.
  --force       Re-download even if the file is already complete.
  --list        Print the manifest and licence, download nothing.
''');
}
