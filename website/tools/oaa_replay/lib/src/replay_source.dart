// SPDX-License-Identifier: GPL-3.0-or-later

/// A [MeterSource] that replays what the engine measured.
library;

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

import 'format.dart';
import 'recording.dart';

/// The fourth implementation of [MeterSource].
///
/// The first is the engine, by FFI. The second decodes a socket for a tablet
/// that has no engine in it. The third invented a programme, for a browser that
/// could have neither. This one is the third one's replacement: the readings
/// are the engine's own, taken from a real track by `oaa_record`, and replayed
/// against the clock of whatever is playing that track.
///
/// The modules cannot tell any of the four apart, which is the entire argument
/// for the interface — and it is worth noticing that this is the implementation
/// that argument was *for*. Nothing in `lib/src/modules/` changed to make a
/// website show real measurements of real music.
///
/// ---------------------------------------------------------------------------
/// Where the time comes from
///
/// [positionSeconds] is a callback rather than a clock this owns, because the
/// two callers want different things and neither wants a stopwatch. The live
/// demo passes the playhead of the audio element, so the meters and the music
/// are the same instant by construction rather than by two timers agreeing. The
/// renderers pass a frame counter, because a screenshot has to come out the
/// same every time it is taken.
///
/// ---------------------------------------------------------------------------
/// The scope is not in the recording
///
/// It is the audio, unprocessed, and storing it would have doubled the file to
/// send a browser a second copy of what it is already playing. [attachPcm]
/// hands over the decoded track instead and the window is read straight out of
/// it. That is not an approximation of what the engine's scope holds; it is the
/// same samples by definition.
///
/// **It is a window and not a block, and that is what a reader is owed.**
/// [MeterSource.scope] holds up to [MeterShape.maxScopeFrames] pairs — four
/// analysis blocks — because a consumer works out what is new from
/// [MeterSource.elapsedSeconds] and takes that many of the newest pairs; what
/// time says arrived and the buffer does not hold is audio that was measured
/// and lost, and the oscilloscope draws it as blank columns rather than
/// inventing it. This published one [MeterShape.scopePoints] block per
/// measurement while the recording advances at its own cadence, so at 20 fps
/// and 44.1 kHz every frame claimed 2,205 samples and offered 1,024: the
/// website's oscilloscope drew a comb, in bursts with a gap between every pair,
/// on audio that had no gaps in it. Nothing here is a real-time producer with a
/// block size — the track is sitting in memory — so the window is simply as
/// wide as the contract allows and covers any cadence down to 11 fps.
class ReplaySource implements MeterSource {
  ReplaySource(
    this.recording, {
    required this.positionSeconds,
    this.loop = true,
  }) : _spectrum = Float32List(MeterShape.spectrumBands),
       _spectrumPeak = Float32List(MeterShape.spectrumBands),
       _spectrumPan = Float32List(MeterShape.spectrumBands),
       _histogram = Float32List(MeterShape.histogramBins),
       _scope = Float32List(MeterShape.maxScopeFrames * 2),
       peak = Float32List(MeterShape.maxChannels),
       rms = Float32List(MeterShape.maxChannels),
       vu = Float32List(MeterShape.maxChannels),
       clip = Uint32List(MeterShape.maxChannels) {
    // Nothing is measured until the first refresh, and "nothing measured" is
    // NaN rather than zero — the one rule this project will not bend.
    peak.fillRange(0, peak.length, double.nan);
    rms.fillRange(0, rms.length, double.nan);
    vu.fillRange(0, vu.length, double.nan);
    _spectrum.fillRange(0, _spectrum.length, double.nan);
    _spectrumPeak.fillRange(0, _spectrumPeak.length, double.nan);
    _spectrumPan.fillRange(0, _spectrumPan.length, double.nan);
  }

  final Recording recording;

  /// Where in the programme to read, in seconds. Called once per [refresh].
  final double Function() positionSeconds;

  /// Whether a position past the end wraps to the start. The demo loops; a
  /// screenshot does not, and freezes on the last frame instead.
  final bool loop;

  final Float32List _spectrum;
  final Float32List _spectrumPeak;
  final Float32List _spectrumPan;
  final Float32List _histogram;
  final Float32List _scope;

  @override
  final Float32List peak;
  @override
  final Float32List rms;
  @override
  final Float32List vu;
  @override
  final Uint32List clip;

  int _frame = -1;
  int _generation = 0;
  double _elapsed = 0.0;

  // The decoded track, if a caller has one. See attachPcm.
  Float32List? _pcm;
  int _pcmChannels = 2;
  int _pcmRate = 48000;
  int _scopeFrames = 0;

  /// Hand over the decoded audio, so the oscilloscope and the phase scope have
  /// a waveform to draw.
  ///
  /// [interleaved] is the whole excerpt, cut by the loop that measured it, so
  /// its first sample is the recording's first frame. [sampleRate] is the rate
  /// it was *decoded* at, which is the browser's business rather than the
  /// track's — see `_fillScope` for what happens when the two differ.
  void attachPcm(
    Float32List interleaved, {
    required int sampleRate,
    required int channels,
  }) {
    _pcm = interleaved;
    _pcmRate = sampleRate;
    _pcmChannels = channels;
  }

  @override
  bool refresh() {
    var position = positionSeconds();
    final length = recording.seconds;
    if (loop && length > 0) {
      position = position % length;
    }

    final frame = recording.frameAt(position);
    _elapsed = position;

    // The audio window moves continuously even when the measurement frame has
    // not changed, so the scope is refilled on every call while the numbers are
    // gathered only when there is a new frame to gather.
    final movedPcm = _fillScope(position);

    if (frame == _frame) return movedPcm;
    _frame = frame;
    _generation++;
    _gather(frame);
    return true;
  }

  void _gather(int frame) {
    recording.readSpectrum(_spectrum, frame);
    recording.readSpectrumPeak(_spectrumPeak, frame);
    recording.readSpectrumPan(_spectrumPan, frame);
    recording.readHistogram(_histogram, frame);

    final channels = recording.header.channels;
    for (var c = 0; c < peak.length; c++) {
      if (c < channels) {
        peak[c] = recording.channel(channelPeakPlane, c, frame);
        rms[c] = recording.channel(channelRmsPlane, c, frame);
        vu[c] = recording.channel(channelVuPlane, c, frame);
        clip[c] = recording.clipAt(c, frame);
      } else {
        // Past the file's channel count is not silence, it is nothing.
        peak[c] = double.nan;
        rms[c] = double.nan;
        vu[c] = double.nan;
        clip[c] = 0;
      }
    }
  }

  /// Fill the window with the newest stereo pairs ending at [position], oldest
  /// first, and say how many of them hold audio.
  ///
  /// Short only at the very start of the programme, where there is not yet a
  /// window's worth behind the playhead. Those pairs are absent rather than
  /// zero: silence is a reading and this is the lack of one, and a reader
  /// counts back from the newest pair, so writing zeros in front of the audio
  /// would put a flat line at the *old* end of the very first trace.
  bool _fillScope(double position) {
    final pcm = _pcm;
    if (pcm == null) {
      _scopeFrames = 0;
      return false;
    }

    // A step through the decoded audio per frame the reader is owed. The two
    // rates are the same whenever the caller decoded at the recording's — both
    // web targets ask their AudioContext for exactly that — and where a browser
    // refuses the request, stepping proportionally keeps the window in the time
    // base the reader measures it against: `elapsedSeconds` is the recording's
    // clock, and a window of 48 kHz samples handed to a consumer counting at
    // 44.1 kHz is nine per cent of the waveform quietly dropped every frame.
    final step = _pcmRate / sampleRate;

    final totalFrames = pcm.length ~/ _pcmChannels;
    final end = (position * _pcmRate).round().clamp(0, totalFrames);
    final available = (end / step).floor();
    final have = available < MeterShape.maxScopeFrames
        ? available
        : MeterShape.maxScopeFrames;

    final right = _pcmChannels > 1 ? 1 : 0;
    for (var i = 0; i < have; i++) {
      final frame = end - ((have - i) * step).round();
      final base = (frame < 0 ? 0 : frame) * _pcmChannels;
      _scope[i * 2] = pcm[base];
      _scope[i * 2 + 1] = pcm[base + right];
    }
    _scopeFrames = have;
    return have > 0;
  }

  // --- What the signal is ---------------------------------------------------

  @override
  int get generation => _generation;

  @override
  int get sampleRate => recording.header.sampleRate;

  @override
  int get channels => recording.header.channels;

  @override
  double get elapsedSeconds => _elapsed;

  @override
  bool get isRunning => true;

  /// No DAW behind a recording, and no pretending otherwise: a tempo of 0.0
  /// looks exactly like a real one, so the oscilloscope's tempo sync is told
  /// there is nothing to sync to.
  @override
  Transport get transport => Transport.none;

  // --- Whether the numbers can be trusted -----------------------------------

  @override
  int get droppedFrames => 0;

  @override
  bool get hasOverrun => false;

  @override
  bool get hasLoudness => true;

  @override
  bool get hasSpectrum => recording.header.has(RecordingParts.spectrum);

  // --- The readings ---------------------------------------------------------

  double _at(Scalar which) =>
      _frame < 0 ? double.nan : recording.scalar(which, _frame);

  @override
  double get lufsMomentary => _at(Scalar.lufsMomentary);
  @override
  double get lufsShort => _at(Scalar.lufsShort);
  @override
  double get lufsIntegrated => _at(Scalar.lufsIntegrated);
  @override
  double get loudnessRange => _at(Scalar.loudnessRange);
  @override
  double get loudnessRangeLow => _at(Scalar.loudnessRangeLow);
  @override
  double get loudnessRangeHigh => _at(Scalar.loudnessRangeHigh);
  @override
  double get loudnessRangeGate => _at(Scalar.loudnessRangeGate);
  @override
  double get truePeak => _at(Scalar.truePeak);
  @override
  double get truePeakMax => _at(Scalar.truePeakMax);
  @override
  double get samplePeakMax => _at(Scalar.samplePeakMax);
  @override
  double get crestFactor => _at(Scalar.crestFactor);
  @override
  double get odrIntegrated => _at(Scalar.odrIntegrated);
  @override
  double get odrShort => _at(Scalar.odrShort);
  @override
  double get correlation => _at(Scalar.correlation);
  @override
  double get balance => _at(Scalar.balance);

  @override
  Float32List get spectrum => _spectrum;
  @override
  Float32List get spectrumPeak => _spectrumPeak;
  @override
  Float32List get spectrumPan => _spectrumPan;

  /// A recording carries the combined bands and nothing else, so every other
  /// source is unavailable here — NaN, which a module draws as no
  /// measurement. The demo never asks: its modules open on
  /// [SpectrumSource.all].
  @override
  Float32List spectrumOf(SpectrumSource source) =>
      source == SpectrumSource.all ? _spectrum : _unavailable;

  @override
  Float32List spectrumPeakOf(SpectrumSource source) =>
      source == SpectrumSource.all ? _spectrumPeak : _unavailable;

  static final Float32List _unavailable = Float32List(MeterShape.spectrumBands)
    ..fillRange(0, MeterShape.spectrumBands, double.nan);
  @override
  Float32List get scope => _scope;
  @override
  int get scopeFrames => _scopeFrames;
  @override
  Float32List get histogram => _histogram;
}
