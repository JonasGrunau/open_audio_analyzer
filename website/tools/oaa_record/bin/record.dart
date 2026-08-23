// SPDX-License-Identifier: GPL-3.0-or-later
//
// Records the engine measuring a real track, for the website to replay.
//
//   dart run oaa_record --in track.flac --out programme.oaa
//   dart run oaa_record --in track.flac --start 62 --seconds 45 --fps 20
//   dart run oaa_record --in track.flac --out web.oaa --web
//
// ---------------------------------------------------------------------------
// What this is for
//
// The website's demos are the application's own modules — the same painters on
// the same grid, compiled from the same sources — and until now the numbers
// going into them were invented, because `dart:ffi` has no web implementation
// and so a browser cannot hold an engine. Invented numbers look invented: a
// spectrum built out of noise fields is smooth in the wrong places and a
// loudness curve made of sine waves repeats.
//
// So the engine runs here, where it exists, against a real track, and writes
// down what it measured. The browser replays that. The readings on the website
// are then the engine's own readings, on music, and the only thing the web
// build is trusted to do is draw them.
//
// ---------------------------------------------------------------------------
// The loop is the offline analyser's loop, deliberately
//
// `OaaFile` decodes blocks and `OaaEngine.push` measures them, in sub-blocks of
// ten milliseconds. That is copied from `analyseFile` in `oaa_engine`, and not
// for convenience: RMS, crest and the VU ballistics are computed over each
// pushed block, so the block size is part of the reading. Pushing a whole
// decoded buffer at once would give one RMS across a quarter of a second and a
// VU needle that moved four times a second. Matching the realtime block size is
// what makes these the numbers the meters actually show.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_replay/oaa_replay.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options == null) {
    stdout.writeln(_usage);
    exit(64);
  }

  final input = File(options.input);
  if (!input.existsSync()) {
    stderr.writeln('oaa_record: no such file: ${options.input}');
    stderr.writeln(
      '  The track this repository is looked at with is fetched by\n'
      '  `dart run tool/fetch_test_audio.dart`, which writes it to test_audio/.',
    );
    exit(66);
  }

  final file = OaaFile.open(options.input, blockFrames: _blockFrames);
  stdout.writeln('${options.input}');
  stdout.writeln(
    '  ${file.info.describe()}, '
    '${file.info.durationSeconds.toStringAsFixed(1)} s',
  );

  final channels = file.info.channels;
  if (channels > MeterShape.maxChannels) {
    stderr.writeln(
      'oaa_record: $channels channels is more than the engine carries',
    );
    file.close();
    exit(65);
  }

  final engine = OaaEngine.start(
    source: OaaSource.push,
    sampleRate: file.info.sampleRate,
    channels: channels,
    blockFrames: _blockFrames,
  );

  try {
    final recorded = _run(file, engine, options);
    final bytes = recorded.encode();
    File(options.output)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    stdout.writeln(
      '  ${options.output}  '
      '${(bytes.length / 1024).toStringAsFixed(1)} kB, '
      '${recorded.frames} frames at ${options.fps.toStringAsFixed(0)} fps',
    );

    final wavPath = options.wav;
    if (wavPath != null) {
      final wav = recorded.encodeWav();
      if (wav != null) {
        File(wavPath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(wav);
        stdout.writeln(
          '  $wavPath  ${(wav.length / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      }
    }

    recorded.printSummary();
  } finally {
    engine.dispose();
    file.close();
  }
}

/// The engine's realtime block. See the note at the top.
const int _blockFrames = 1024;

// ---------------------------------------------------------------------------

class _Options {
  const _Options({
    required this.input,
    required this.output,
    required this.start,
    required this.seconds,
    required this.fps,
    required this.parts,
    required this.wav,
  });

  final String input;
  final String output;
  final double start;
  final double seconds;
  final double fps;
  final int parts;

  /// Where to write the audio that was measured, if anywhere.
  ///
  /// The browser has to play the same seconds this recording describes, and the
  /// only thing that knows exactly which seconds those are is the loop that
  /// pushed them. Cutting the excerpt anywhere else — by timestamp, in another
  /// tool — is how the meters end up a beat ahead of the music.
  final String? wav;

  static _Options? parse(List<String> arguments) {
    String? input;
    var output = 'programme.oaa';
    var start = 0.0;
    var seconds = 45.0;
    var fps = 20.0;
    var parts = RecordingParts.all;
    String? wav;

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      String? valueFor(String name) {
        if (argument == '--$name' && i + 1 < arguments.length) {
          return arguments[++i];
        }
        if (argument.startsWith('--$name=')) {
          return argument.substring(name.length + 3);
        }
        return null;
      }

      final asInput = valueFor('in');
      if (asInput != null) {
        input = asInput;
        continue;
      }
      final asOutput = valueFor('out');
      if (asOutput != null) {
        output = asOutput;
        continue;
      }
      final asStart = valueFor('start');
      if (asStart != null) {
        start = double.parse(asStart);
        continue;
      }
      final asSeconds = valueFor('seconds');
      if (asSeconds != null) {
        seconds = double.parse(asSeconds);
        continue;
      }
      final asFps = valueFor('fps');
      if (asFps != null) {
        fps = double.parse(asFps);
        continue;
      }
      final asWav = valueFor('wav');
      if (asWav != null) {
        wav = asWav;
        continue;
      }
      if (argument == '--web') {
        // What the eight modules on the website's canvas actually read. The
        // stereo cloud is the only module that draws per-band pan and it is not
        // on that canvas, so shipping 512 more bytes a frame to a browser would
        // be shipping something nothing looks at.
        parts =
            RecordingParts.spectrum |
            RecordingParts.spectrumPeak |
            RecordingParts.histogram |
            RecordingParts.clip;
        continue;
      }
      if (argument == '--help' || argument == '-h') return null;
      stderr.writeln('oaa_record: unknown option $argument');
      return null;
    }

    if (input == null) return null;
    return _Options(
      input: input,
      output: output,
      start: start,
      seconds: seconds,
      fps: fps,
      parts: parts,
      wav: wav,
    );
  }
}

const String _usage = '''
oaa_record — write down what the engine measures, so a browser can replay it

Usage:  dart run oaa_record --in <file> [options]

  --in <path>        The track to measure. Required.
  --out <path>       Where to write the recording. Default programme.oaa
  --start <s>        Seconds into the file to begin. Default 0
  --seconds <s>      How much programme to record. Default 45
  --fps <n>          Recording frames per second of programme. Default 20
  --web              Leave out the arrays the website's canvas never reads.
  --wav <path>       Also write the measured excerpt, as a 16-bit WAV.

The engine measures from --start: the loudness integration and the peak maxima
begin where the recording does, so a recording of a section reads like playing
that section from the top, which is what a listener sees.
''';

// ---------------------------------------------------------------------------

/// The recording as it is built: one growable list per series.
class _Recorded {
  _Recorded({
    required this.channels,
    required this.sampleRate,
    required this.fps,
    required this.startSeconds,
    required this.parts,
  });

  final int channels;
  final int sampleRate;
  final double fps;
  final double startSeconds;
  final int parts;

  final List<Float32List> _scalarFrames = [];
  final List<Float32List> _channelFrames = [];
  final List<Uint16List> _clipFrames = [];
  final List<Uint8List> _spectrumFrames = [];
  final List<Uint8List> _spectrumPeakFrames = [];
  final List<Uint8List> _spectrumPanFrames = [];
  final List<Uint16List> _histogramFrames = [];

  /// The audio that was measured, kept only when `--wav` asked for it.
  BytesBuilder? _audio;

  void collectAudio() => _audio ??= BytesBuilder(copy: false);

  /// One sub-block, exactly as it was pushed.
  void addAudio(Float32List interleaved) {
    final audio = _audio;
    if (audio == null) return;
    // 16-bit, because this is a listening copy rather than a measurement one:
    // the measurement already happened, in float, from the FLAC. The rounding
    // here reaches nobody's meters.
    final out = Int16List(interleaved.length);
    for (var i = 0; i < interleaved.length; i++) {
      final sample = (interleaved[i] * 32767.0).round();
      out[i] = sample < -32768 ? -32768 : (sample > 32767 ? 32767 : sample);
    }
    audio.add(out.buffer.asUint8List(out.offsetInBytes, out.lengthInBytes));
  }

  int get frames => _scalarFrames.length;

  bool has(int part) => parts & part != 0;

  void add(MeterSource source) {
    _scalarFrames.add(
      Float32List.fromList([
        source.lufsMomentary,
        source.lufsShort,
        source.lufsIntegrated,
        source.loudnessRange,
        source.loudnessRangeLow,
        source.loudnessRangeHigh,
        source.loudnessRangeGate,
        source.truePeak,
        source.truePeakMax,
        source.samplePeakMax,
        source.dynamicRangeShort,
        source.dynamicRangeIntegrated,
        source.crestFactor,
        source.peakToLoudnessRatio,
        source.peakToShortTermRatio,
        source.correlation,
        source.balance,
      ]),
    );

    final perChannel = Float32List(channels * 3);
    for (var c = 0; c < channels; c++) {
      perChannel[c] = source.peak[c];
      perChannel[channels + c] = source.rms[c];
      perChannel[channels * 2 + c] = source.vu[c];
    }
    _channelFrames.add(perChannel);

    if (has(RecordingParts.clip)) {
      final clip = Uint16List(channels);
      for (var c = 0; c < channels; c++) {
        clip[c] = math.min(source.clip[c], 0xFFFF);
      }
      _clipFrames.add(clip);
    }

    if (has(RecordingParts.spectrum)) {
      _spectrumFrames.add(_quantiseDb(source.spectrum));
    }
    if (has(RecordingParts.spectrumPeak)) {
      _spectrumPeakFrames.add(_quantiseDb(source.spectrumPeak));
    }
    if (has(RecordingParts.spectrumPan)) {
      // Around 128 rather than signed, so it delta-codes through the same path
      // as the two dB planes and the reader has one loop instead of two.
      final pan = Uint8List(MeterShape.spectrumBands);
      for (var band = 0; band < pan.length; band++) {
        final value = source.spectrumPan[band];
        pan[band] = value.isNaN
            ? 128
            : (128 + (value.clamp(-1.0, 1.0) * 127).round()).clamp(1, 255);
      }
      deltaEncodeBands(pan);
      _spectrumPanFrames.add(pan);
    }
    if (has(RecordingParts.histogram)) {
      final histogram = Uint16List(MeterShape.histogramBins);
      for (var bin = 0; bin < histogram.length; bin++) {
        final value = source.histogram[bin];
        histogram[bin] = value.isNaN
            ? 0
            : (value.clamp(0.0, 1.0) * 65535).round();
      }
      _histogramFrames.add(histogram);
    }
  }

  static Uint8List _quantiseDb(Float32List source) {
    final out = Uint8List(MeterShape.spectrumBands);
    for (var band = 0; band < out.length; band++) {
      out[band] = quantiseDb(source[band]);
    }
    deltaEncodeBands(out);
    return out;
  }

  /// See the note in `format.dart` on the layout, which was measured.
  Uint8List encode() {
    final header = RecordingHeader(
      parts: parts,
      frames: frames,
      fps: fps,
      channels: channels,
      sampleRate: sampleRate,
      startSeconds: startSeconds,
      spectrumBands: MeterShape.spectrumBands,
      histogramBins: MeterShape.histogramBins,
    );

    final builder = BytesBuilder(copy: false);
    builder.add(header.encode());

    void writeFloatPlanes(int series, double Function(int, int) at) {
      final plane = Float32List(series * frames);
      for (var s = 0; s < series; s++) {
        for (var f = 0; f < frames; f++) {
          plane[s * frames + f] = at(s, f);
        }
      }
      builder.add(plane.buffer.asUint8List());
    }

    writeFloatPlanes(Scalar.count, (s, f) => _scalarFrames[f][s]);
    writeFloatPlanes(channels, (c, f) => _channelFrames[f][c]);
    writeFloatPlanes(channels, (c, f) => _channelFrames[f][channels + c]);
    writeFloatPlanes(channels, (c, f) => _channelFrames[f][channels * 2 + c]);

    if (has(RecordingParts.clip)) {
      final plane = Uint16List(channels * frames);
      for (var c = 0; c < channels; c++) {
        for (var f = 0; f < frames; f++) {
          plane[c * frames + f] = _clipFrames[f][c];
        }
      }
      builder.add(plane.buffer.asUint8List());
    }

    // Frame after frame, each already delta-coded across its bands when it was
    // quantised. Nothing to transpose.
    void writeFrames(List<Uint8List> source) {
      for (final frame in source) {
        builder.add(frame);
      }
    }

    if (has(RecordingParts.spectrum)) writeFrames(_spectrumFrames);
    if (has(RecordingParts.spectrumPeak)) writeFrames(_spectrumPeakFrames);
    if (has(RecordingParts.spectrumPan)) writeFrames(_spectrumPanFrames);
    if (has(RecordingParts.histogram)) {
      final plane = Uint16List(MeterShape.histogramBins * frames);
      for (var bin = 0; bin < MeterShape.histogramBins; bin++) {
        for (var f = 0; f < frames; f++) {
          plane[bin * frames + f] = _histogramFrames[f][bin];
        }
      }
      builder.add(plane.buffer.asUint8List());
    }

    return builder.toBytes();
  }

  /// The excerpt as a WAV, or null when none was collected.
  ///
  /// Written by hand because the alternative is a package, and a RIFF header
  /// for interleaved PCM is eleven fields. Not RF64: this is 45 seconds.
  Uint8List? encodeWav() {
    final audio = _audio;
    if (audio == null) return null;
    final samples = audio.toBytes();

    const headerBytes = 44;
    final out = ByteData(headerBytes + samples.length);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        out.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;

    ascii(0, 'RIFF');
    out.setUint32(4, 36 + samples.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    out.setUint32(16, 16, Endian.little); // PCM header length
    out.setUint16(20, 1, Endian.little); // PCM
    out.setUint16(22, channels, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setUint32(28, byteRate, Endian.little);
    out.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    out.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    out.setUint32(40, samples.length, Endian.little);

    final bytes = out.buffer.asUint8List();
    bytes.setRange(headerBytes, headerBytes + samples.length, samples);
    return bytes;
  }

  /// What the recording says about the programme, so a run can be judged
  /// without opening the file in a browser.
  void printSummary() {
    if (frames == 0) return;
    final last = _scalarFrames.last;
    String db(int index) {
      final value = last[index];
      return value.isNaN ? '—' : value.toStringAsFixed(1);
    }

    stdout.writeln(
      '  LUFS-I ${db(Scalar.lufsIntegrated.index)}   '
      'LRA ${db(Scalar.loudnessRange.index)}   '
      'TP max ${db(Scalar.truePeakMax.index)} dBTP   '
      'corr ${db(Scalar.correlation.index)}',
    );
  }
}

// ---------------------------------------------------------------------------

_Recorded _run(OaaFile file, OaaEngine engine, _Options options) {
  final sampleRate = file.info.sampleRate;
  final channels = file.info.channels;

  final recorded = _Recorded(
    channels: channels,
    sampleRate: sampleRate,
    fps: options.fps,
    startSeconds: options.start,
    parts: options.parts,
  );

  // Ten milliseconds, which is how often the engine advances momentary and
  // short-term loudness. See the note at the top.
  final subBlockFrames = math.max(1, sampleRate ~/ 100);
  final skipFrames = (options.start * sampleRate).round();
  final wantFrames = (options.seconds * sampleRate).round();
  final framesPerRecord = sampleRate / options.fps;

  if (options.wav != null) recorded.collectAudio();

  var decoded = 0; // frames read from the file
  var measured = 0; // frames pushed into the engine
  var nextRecord = 0.0;

  for (var block = file.readBlock(); block != null; block = file.readBlock()) {
    final framesInBlock = block.length ~/ channels;

    // Everything before --start is decoded and thrown away rather than
    // measured. Seeking would be faster and would also mean the engine's
    // integration began mid-programme with a discontinuity in front of it.
    if (decoded + framesInBlock <= skipFrames) {
      decoded += framesInBlock;
      continue;
    }

    var offset = 0;
    if (decoded < skipFrames) {
      offset = skipFrames - decoded;
    }
    decoded += framesInBlock;

    for (
      var pushed = offset;
      pushed < framesInBlock;
      pushed += subBlockFrames
    ) {
      final frames = math.min(subBlockFrames, framesInBlock - pushed);
      final samples = Float32List.sublistView(
        block,
        pushed * channels,
        (pushed + frames) * channels,
      );
      engine.push(samples);
      recorded.addAudio(samples);
      measured += frames;

      while (measured >= nextRecord &&
          recorded.frames * framesPerRecord <= wantFrames) {
        recorded.add(engine);
        nextRecord += framesPerRecord;
      }

      if (measured >= wantFrames) return recorded;
    }
  }

  return recorded;
}
