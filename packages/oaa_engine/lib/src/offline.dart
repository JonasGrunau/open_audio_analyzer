/// Measuring a whole file.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// Decode a block, push it, read the snapshot, repeat. That loop is the whole
/// of offline analysis, and it lives here rather than in the app or the CLI
/// because both of them need it and neither can import the other.
///
/// ---------------------------------------------------------------------------
/// Why this returns numbers rather than a report
///
/// [OfflineResult] is deliberately plain: rates, counts and doubles, with no
/// notion of a delivery target, a formatted string or a pass mark. Turning
/// measurements into a report — deciding that −13.2 LUFS misses a −14 target,
/// choosing how many decimals to print — is domain work, and domain work lives
/// in `oaa_core`, which must never import `dart:ffi`. Keeping the split here
/// means the tablet display and the plugin can render a report from numbers
/// that arrived over a socket, with no engine anywhere in the process.
///
/// ---------------------------------------------------------------------------
/// Why the maxima are accumulated instead of read at the end
///
/// The snapshot mixes two kinds of quantity. Integrated loudness, LRA and the
/// "max since reset" peaks integrate over the whole run, so reading them once
/// at the end is correct. Momentary and short-term loudness, correlation and
/// RMS describe *this instant*, so at the end of a file they describe the
/// final block — usually the fade-out, or silence. A report that printed those
/// would be reporting the last second of the programme and calling it the
/// programme. They have to be watched on the way past, which is what the loop
/// below does.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../oaa_engine.dart';

/// A cancel flag that can be read from another isolate.
///
/// [analyseFile] runs on whichever isolate calls it, and in the app that is a
/// worker so the meters keep painting. Stopping that worker is harder than it
/// looks: killing the isolate leaks the native engine and the open decoder it
/// was holding, and a message cannot reach an isolate that is busy in a decode
/// loop and never yields to its event queue.
///
/// So the flag lives in native memory. Both isolates are in one process, so
/// [address] is valid in both — pass it across, rebuild the token there with
/// [OaaCancelToken.fromAddress], and the worker sees a [cancel] the instant it
/// checks between blocks. It then unwinds through its own `finally` and closes
/// the engine and the file on the way out, which is the whole point.
///
/// The owner calls [dispose]; a token rebuilt from an address must not.
class OaaCancelToken {
  OaaCancelToken() : _flag = calloc<Int32>(), _owned = true;

  /// Rebuilds a token from another isolate's [address]. Does not own the
  /// memory, so [dispose] on this one is a no-op.
  OaaCancelToken.fromAddress(int address)
    : _flag = Pointer<Int32>.fromAddress(address),
      _owned = false;

  final Pointer<Int32> _flag;
  final bool _owned;

  /// Pass this to another isolate.
  int get address => _flag.address;

  bool get isCancelled => _flag.value != 0;

  void cancel() => _flag.value = 1;

  void dispose() {
    if (_owned) calloc.free(_flag);
  }
}

/// One sample of the measurements that move, taken at a fixed cadence.
///
/// This is what a report graph is drawn from and what the CSV export writes a
/// row per. The cadence is signal time, not wall-clock time: an offline run
/// analyses far faster than realtime, and a timeline indexed by how long the
/// analysis took would describe the computer rather than the audio.
class OfflineTimelinePoint {
  const OfflineTimelinePoint({
    required this.seconds,
    required this.momentary,
    required this.shortTerm,
    required this.truePeak,
  });

  /// Position in the programme, in seconds.
  final double seconds;

  /// LUFS-M at this point. NaN until 400 ms of signal exists.
  final double momentary;

  /// LUFS-S at this point. NaN until 3 s of signal exists.
  final double shortTerm;

  /// dBTP over the engine's sliding true-peak window.
  final double truePeak;
}

/// Everything a run of the analyser measured.
class OfflineResult {
  const OfflineResult({
    required this.sampleRate,
    required this.channels,
    required this.frames,
    required this.durationSeconds,
    required this.formatLabel,
    required this.bitsPerSample,
    required this.lufsIntegrated,
    required this.loudnessRange,
    required this.loudnessRangeLow,
    required this.loudnessRangeHigh,
    required this.loudnessRangeGate,
    required this.truePeakMax,
    required this.samplePeakMax,
    required this.momentaryMax,
    required this.shortTermMax,
    required this.shortTermMin,
    required this.correlationMin,
    required this.correlationMax,
    required this.correlationMean,
    required this.channelPeakMax,
    required this.timeline,
  });

  final int sampleRate;
  final int channels;
  final int frames;
  final double durationSeconds;

  /// The container, as `WAV`, `FLAC`, `MP3` and so on.
  final String formatLabel;

  /// Source bit depth, or 0 for a lossy format.
  final int bitsPerSample;

  // --- Integrating, read once at the end ------------------------------------

  final double lufsIntegrated;
  final double loudnessRange;
  final double loudnessRangeLow;
  final double loudnessRangeHigh;
  final double loudnessRangeGate;
  final double truePeakMax;
  final double samplePeakMax;

  // --- Watched on the way past ----------------------------------------------

  /// Highest LUFS-M seen. NaN for a programme shorter than 400 ms.
  final double momentaryMax;

  /// Highest LUFS-S seen. NaN for a programme shorter than 3 s.
  final double shortTermMax;

  /// Lowest LUFS-S seen, which together with [shortTermMax] brackets the
  /// programme. Not the same as LRA: this is the raw span, ungated, so a
  /// single quiet moment moves it and LRA is the number to quote.
  final double shortTermMin;

  final double correlationMin;
  final double correlationMax;

  /// Mean correlation across the programme, equally weighted per block.
  /// Silence is included, which is worth knowing when reading it: a track with
  /// a long silent tail reports a mean pulled toward whatever silence
  /// correlates to rather than toward the music.
  final double correlationMean;

  /// Highest peak seen on each channel, dBFS. Length is [channels].
  final List<double> channelPeakMax;

  final List<OfflineTimelinePoint> timeline;

  /// Peak to loudness ratio: how much headroom the programme has above its own
  /// integrated loudness. Derived rather than stored, because it is exactly
  /// this subtraction and a stored copy could disagree with it.
  double get peakToLoudnessRatio => truePeakMax - lufsIntegrated;

  /// `DR-I` as Open Audio Analyzer defines it in docs/METRICS.md — true peak
  /// max minus integrated loudness. Not Decibel's proprietary "TrueDyn", and
  /// not claimed to match it.
  double get dynamicRangeIntegrated => truePeakMax - lufsIntegrated;
}

/// Progress during a run: [seconds] of [totalSeconds] analysed.
///
/// [totalSeconds] is 0 when the file's length could not be determined, which a
/// progress bar should render as indeterminate rather than as complete.
typedef OfflineProgress = void Function(double seconds, double totalSeconds);

/// Analyses an audio file end to end.
///
/// Runs the same `oaa_analyse` a capture device drives, at whatever speed the
/// CPU manages, over blocks decoded from [path]. The engine is created to match
/// the file — nothing resamples and nothing remixes, because resampling in
/// front of a measurement changes the measurement.
///
/// [onProgress] is called at most once per [timelineInterval] of signal, so a
/// caller can drive a progress bar without being handed a callback per block.
/// [shouldCancel] is polled at the same cadence; returning true stops the run
/// and throws [OfflineCancelled].
///
/// This blocks the calling thread for the whole file. In the app it belongs on
/// an isolate; a minute of audio is a fraction of a second of work, but an hour
/// is not, and a UI that stops painting is a UI whose meters have stopped.
OfflineResult analyseFile(
  String path, {
  int blockFrames = 1024,
  Duration timelineInterval = const Duration(milliseconds: 100),
  OfflineProgress? onProgress,
  bool Function()? shouldCancel,
}) {
  final file = OaaFile.open(path, blockFrames: blockFrames);

  if (file.info.channels > kOaaMaxChannels) {
    final channels = file.info.channels;
    file.close();
    throw OaaFileException(
      'the engine carries at most $kOaaMaxChannels channels (7.1) and this '
      'file has $channels',
      path,
    );
  }

  // The engine is started inside a guard, because it can refuse: a stale native
  // library fails the ABI check, and a file can name a rate the engine will not
  // take. Without this the open decoder and its native read buffer were lost on
  // exactly those paths — the ones a caller is most likely to hit repeatedly,
  // since neither is transient.
  final OaaEngine engine;
  try {
    engine = OaaEngine.start(
      source: OaaSource.push,
      sampleRate: file.info.sampleRate,
      channels: file.info.channels,
      blockFrames: blockFrames,
    );
  } on Object {
    file.close();
    rethrow;
  }

  try {
    return _run(
      file,
      engine,
      timelineInterval: timelineInterval,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  } finally {
    engine.dispose();
    file.close();
  }
}

/// Thrown when [analyseFile]'s `shouldCancel` asked it to stop.
class OfflineCancelled implements Exception {
  const OfflineCancelled();

  @override
  String toString() => 'OfflineCancelled: analysis was cancelled';
}

OfflineResult _run(
  OaaFile file,
  OaaEngine engine, {
  required Duration timelineInterval,
  OfflineProgress? onProgress,
  bool Function()? shouldCancel,
}) {
  final channels = file.info.channels;
  final sampleRate = file.info.sampleRate;
  final intervalSeconds = timelineInterval.inMicroseconds / 1e6;

  final timeline = <OfflineTimelinePoint>[];
  final channelPeakMax = List<double>.filled(channels, double.negativeInfinity);

  var momentaryMax = double.nan;
  var shortTermMax = double.nan;
  var shortTermMin = double.nan;
  var correlationMin = double.nan;
  var correlationMax = double.nan;
  var correlationSum = 0.0;
  var correlationCount = 0;

  var framesDone = 0;
  var nextSample = 0.0;

  // NaN loses every comparison, so `max(nan, x)` is not `x` and the running
  // maxima have to be seeded by the first real reading rather than by a
  // sentinel. Doing this with a helper rather than inline is what keeps a NaN
  // from silently becoming the answer — which for a loudness reading would be
  // an em dash on a report about a file that was measured perfectly well.
  double runningMax(double current, double value) {
    if (value.isNaN) return current;
    if (current.isNaN) return value;
    return math.max(current, value);
  }

  double runningMin(double current, double value) {
    if (value.isNaN) return current;
    if (current.isNaN) return value;
    return math.min(current, value);
  }

  // The engine advances momentary and short-term loudness every 10 ms. The
  // maxima below are whatever this loop looked at, so pushing a whole decoded
  // block and reading once would step over readings — and Max M would depend on
  // the size of the buffer the decoder happened to hand back, which is not a
  // property of the audio. EBU Tech 3341 test 13 measures exactly that: a
  // 400 ms tone offset by 20 ms, whose only correct momentary reading exists
  // for one sub-block. So the loop pushes a sub-block at a time and looks in
  // between. The views cost nothing; `push` copies into a buffer it already owns.
  final subBlockFrames = math.max(1, sampleRate ~/ 100);

  for (var block = file.readBlock(); block != null; block = file.readBlock()) {
    final framesInBlock = block.length ~/ channels;

    for (var pushed = 0; pushed < framesInBlock; pushed += subBlockFrames) {
      final frames = math.min(subBlockFrames, framesInBlock - pushed);
      engine.push(
        Float32List.sublistView(
          block,
          pushed * channels,
          (pushed + frames) * channels,
        ),
      );

      momentaryMax = runningMax(momentaryMax, engine.lufsMomentary);
      shortTermMax = runningMax(shortTermMax, engine.lufsShort);
      shortTermMin = runningMin(shortTermMin, engine.lufsShort);
    }

    framesDone += framesInBlock;
    final seconds = framesDone / sampleRate;

    // Correlation and the per-channel peaks stay on the decoded block, which is
    // what they have always been sampled at. The peaks are maxima and cannot
    // move; the correlation mean is weighted per sample taken, and re-weighting
    // it ten times finer would change a published number to no end.
    final correlation = engine.correlation;
    if (!correlation.isNaN) {
      correlationMin = runningMin(correlationMin, correlation);
      correlationMax = runningMax(correlationMax, correlation);
      correlationSum += correlation;
      correlationCount++;
    }

    for (var c = 0; c < channels; c++) {
      final peak = engine.peak[c];
      if (!peak.isNaN && peak > channelPeakMax[c]) channelPeakMax[c] = peak;
    }

    if (seconds >= nextSample) {
      timeline.add(
        OfflineTimelinePoint(
          seconds: seconds,
          momentary: engine.lufsMomentary,
          shortTerm: engine.lufsShort,
          truePeak: engine.truePeak,
        ),
      );
      nextSample += intervalSeconds;

      onProgress?.call(seconds, file.info.durationSeconds);
      if (shouldCancel != null && shouldCancel()) {
        throw const OfflineCancelled();
      }
    }
  }

  engine.refresh();
  onProgress?.call(framesDone / sampleRate, file.info.durationSeconds);

  return OfflineResult(
    sampleRate: sampleRate,
    channels: channels,
    frames: framesDone,
    durationSeconds: framesDone / sampleRate,
    formatLabel: file.info.format.label,
    bitsPerSample: file.info.bitsPerSample,
    lufsIntegrated: engine.lufsIntegrated,
    loudnessRange: engine.loudnessRange,
    loudnessRangeLow: engine.loudnessRangeLow,
    loudnessRangeHigh: engine.loudnessRangeHigh,
    loudnessRangeGate: engine.loudnessRangeGate,
    truePeakMax: engine.truePeakMax,
    samplePeakMax: engine.samplePeakMax,
    momentaryMax: momentaryMax,
    shortTermMax: shortTermMax,
    shortTermMin: shortTermMin,
    correlationMin: correlationMin,
    correlationMax: correlationMax,
    correlationMean: correlationCount == 0
        ? double.nan
        : correlationSum / correlationCount,
    channelPeakMax: List<double>.unmodifiable(
      channelPeakMax.map((p) => p == double.negativeInfinity ? double.nan : p),
    ),
    timeline: List<OfflineTimelinePoint>.unmodifiable(timeline),
  );
}
