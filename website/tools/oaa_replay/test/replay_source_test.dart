// SPDX-License-Identifier: GPL-3.0-or-later

/// What a consumer of [ReplaySource] is owed, and gets.
///
/// The recording's numbers are not in here — they are the engine's, taken once
/// by `oaa_record`, and a test that re-asserted them would only be checking
/// that a plane can be read back. What is worth pinning is the *scope*, which
/// is the one thing `ReplaySource` synthesises rather than replays: it is
/// assembled from the decoded audio on every look, and it is handed to a reader
/// that decides what is new by arithmetic on the clock rather than by looking
/// at the buffer.
///
/// That arithmetic is reproduced below in [_ScopeReader], which is the
/// oscilloscope's `ingest` reduced to the two questions this has to answer: how
/// much audio does the clock say arrived, and how much of it is still in the
/// window. When the answers differ the module draws the shortfall as blank
/// columns — correctly; audio that was measured and lost is not a straight
/// line. The website's front page carried a comb for a week because this source
/// published one 1,024-frame block per 50 ms of programme and the clock said
/// 2,205 samples had gone past.
library;

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_replay/oaa_replay.dart';
import 'package:test/test.dart';

void main() {
  group('the scope window', () {
    test('holds every sample the clock says arrived', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      var position = 0.0;
      final source =
          ReplaySource(recording, positionSeconds: () => position, loop: false)
            ..attachPcm(
              _ramp(seconds: 5.0, rate: 44100),
              sampleRate: 44100,
              channels: 2,
            );

      final reader = _ScopeReader();
      // Past the first window, so nothing here is short for want of history.
      for (var frame = 4; frame < 60; frame++) {
        position = frame / recording.header.fps;
        source.refresh();
        reader.read(source);
      }

      expect(reader.missed, 0, reason: 'the window dropped audio it holds');
      expect(reader.discontinuities, isEmpty);
      // The first look only seats the clock, so 55 of the 56 take audio:
      // 2,205 samples each at 44.1 kHz and 20 fps.
      expect(reader.taken, 55 * 2205);
    });

    test('is as wide as the contract allows, not one analysis block', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      var position = 1.0;
      final source =
          ReplaySource(recording, positionSeconds: () => position, loop: false)
            ..attachPcm(
              _ramp(seconds: 5.0, rate: 44100),
              sampleRate: 44100,
              channels: 2,
            );

      source.refresh();
      expect(source.scopeFrames, MeterShape.maxScopeFrames);
      expect(source.scope.length, MeterShape.maxScopeFrames * 2);
      // A 20 fps recording at 44.1 kHz owes 2,205 samples a frame, which one
      // block does not hold and four do. This is the regression: at
      // MeterShape.scopePoints the reader below would be short 1,181 of them.
      expect(source.scopeFrames, greaterThan(44100 ~/ 20));
    });

    test('ends on the sample the playhead is standing on', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      var position = 2.0;
      final source =
          ReplaySource(recording, positionSeconds: () => position, loop: false)
            ..attachPcm(
              _ramp(seconds: 5.0, rate: 44100),
              sampleRate: 44100,
              channels: 2,
            );

      source.refresh();
      final newest = source.scope[(source.scopeFrames - 1) * 2];
      expect(newest, closeTo(2.0 * 44100 - 1, 0.5));
    });

    test('is short at the start rather than padded with silence', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      var position = 0.01;
      final source =
          ReplaySource(recording, positionSeconds: () => position, loop: false)
            ..attachPcm(
              _ramp(seconds: 5.0, rate: 44100),
              sampleRate: 44100,
              channels: 2,
            );

      source.refresh();
      expect(source.scopeFrames, 441);
      // Oldest first, so the audio starts at index 0 — a leading run of zeros
      // would draw a flat line at the old end of the very first trace.
      expect(source.scope[0], closeTo(0.0, 0.5));
      expect(source.scope[440 * 2], closeTo(440.0, 0.5));

      position = 0.0;
      source.refresh();
      expect(source.scopeFrames, 0);
    });

    test('with no audio attached at all, publishes nothing', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      final source = ReplaySource(
        recording,
        positionSeconds: () => 1.0,
        loop: false,
      );
      source.refresh();
      expect(source.scopeFrames, 0);
    });
  });

  group('audio decoded at another rate', () {
    // A browser hands back whatever its AudioContext runs at unless it is asked
    // otherwise, and both web targets do ask. Where the request is refused, the
    // window still has to be in the time base the reader measures it against —
    // `elapsedSeconds` counts in the recording's rate.
    test('is stepped into the recording\'s time base', () {
      final recording = _recording(frames: 100, fps: 20.0, sampleRate: 44100);
      var position = 0.0;
      final source =
          ReplaySource(recording, positionSeconds: () => position, loop: false)
            ..attachPcm(
              _ramp(seconds: 5.0, rate: 48000),
              sampleRate: 48000,
              channels: 2,
            );

      final reader = _ScopeReader();
      for (var frame = 4; frame < 60; frame++) {
        position = frame / recording.header.fps;
        source.refresh();
        reader.read(source);
      }

      expect(reader.missed, 0);
      expect(reader.taken, 55 * 2205);
      // One second of programme is one second of audio, whatever it was
      // decoded at: the newest sample of the window is the one under the
      // playhead, counted at 48 kHz because that is where it came from.
      position = 2.0;
      source.refresh();
      final newest = source.scope[(source.scopeFrames - 1) * 2];
      expect(newest, closeTo(2.0 * 48000 - 1, 60));
    });
  });
}

// ---------------------------------------------------------------------------

/// The oscilloscope's `ingest`, reduced to the arithmetic this source has to
/// satisfy: what elapsed time says arrived, against what the window holds.
class _ScopeReader {
  double _elapsed = -1.0;

  /// Samples the reader was owed and the window did not hold. Blank columns.
  int missed = 0;

  /// Samples it took.
  int taken = 0;

  /// Every place the audio it took did not join onto the audio before it.
  final List<String> discontinuities = <String>[];

  double _last = double.nan;

  void read(MeterSource source) {
    final published = source.scopeFrames;
    if (published <= 0) return;
    final elapsed = source.elapsedSeconds;
    if (_elapsed < 0 || elapsed < _elapsed) {
      _elapsed = elapsed;
      return;
    }

    final fresh = ((elapsed - _elapsed) * source.sampleRate).round();
    _elapsed = elapsed;
    if (fresh <= 0) return;

    final take = fresh < published ? fresh : published;
    missed += fresh - take;
    taken += take;

    final first = published - take;
    final scope = source.scope;
    // The ramp is the sample index, so a join shows up as a number that is not
    // one more than the one before it. A tolerance of two: a rate conversion
    // steps through the source audio by a fraction and lands on either side.
    for (var i = 0; i < take; i++) {
      final value = scope[(first + i) * 2];
      if (!_last.isNaN && (value - _last - 1.0).abs() > 2.0) {
        discontinuities.add(
          'at ${elapsed.toStringAsFixed(3)} s: $_last then $value',
        );
      }
      _last = value;
    }
  }
}

/// Interleaved stereo whose every sample is its own frame index, so a reader
/// can say exactly which samples it was handed.
Float32List _ramp({required double seconds, required int rate}) {
  final frames = (seconds * rate).round();
  final out = Float32List(frames * 2);
  for (var frame = 0; frame < frames; frame++) {
    out[frame * 2] = frame.toDouble();
    out[frame * 2 + 1] = frame.toDouble();
  }
  return out;
}

/// The smallest file `Recording.parse` accepts: a header carrying no optional
/// plane, then the scalars and the three per-channel series.
///
/// The readings in it are not what is under test — see the note at the top —
/// so they are zero, and the only fields that matter are the cadence and the
/// rate, which are what the scope window is measured against.
Recording _recording({
  required int frames,
  required double fps,
  required int sampleRate,
  int channels = 2,
}) {
  const header = RecordingHeader.bytes;
  final floats = (Scalar.count + channels * 3) * frames;
  final bytes = Uint8List(header + floats * 4);
  bytes.setRange(
    0,
    header,
    RecordingHeader(
      parts: 0,
      frames: frames,
      fps: fps,
      channels: channels,
      sampleRate: sampleRate,
      startSeconds: 0.0,
      spectrumBands: MeterShape.spectrumBands,
      histogramBins: MeterShape.histogramBins,
    ).encode(),
  );
  return Recording.parse(bytes);
}
