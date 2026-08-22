// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

/// A third [MeterSource], alongside `OaaEngine` (native memory) and
/// `WireSnapshot` (a socket), written for one purpose: to give the fourteen
/// modules something worth drawing while a still of each is captured.
///
/// It honours the same contract the interface documents, because the modules
/// are entitled to assume it — the arrays are allocated once and refilled
/// rather than swapped, a quantity that has not been measured yet is NaN and
/// not zero, and [refresh] is the only thing called on the frame path.
///
/// **It advances by frame, not by clock.** One [refresh] is one published
/// measurement worth [dt] of programme, so the state at frame *n* is a pure
/// function of *n* and the images come out the same on a fast machine and a slow
/// one. Once [captureAt] is reached it stops reporting new data, which freezes
/// every meter — so a screenshot taken any time after that is identical to one
/// taken a second later, and the renderer waits for the picture rather than
/// guessing how many frames the browser managed to draw.
///
/// Nothing here is a measurement. It is a plausible *shape* for one, and the
/// numbers it reports are chosen to make each module show the thing it exists
/// to show: a programme that lands on the streaming loudness target, so the
/// meters read in spec and are coloured as such, but with true peak driven into
/// the last dB — which leaves the validator a real failure to report and the
/// alert meter a reason to be red.
class MockSource implements MeterSource {
  /// Seconds of programme one publication advances.
  ///
  /// **Not the engine's 47 Hz, and deliberately so.** The modules that keep a
  /// history — the spectrogram, the loudness timeline — advance it once per
  /// painted frame, so a real 47 Hz would need 1,400 browser frames to fill a
  /// 30 second axis, and a headless browser does not paint anywhere near fast
  /// enough for that to be cheap. What actually matters is that the history is
  /// sampled about once per *pixel*: a 30 second window 320 px wide is 0.094
  /// seconds a pixel, so stepping this far per frame fills the axis in about
  /// 320 frames with nothing visibly lost.
  final double dt;

  /// Seconds of programme to play before freezing.
  ///
  /// Per module, because most of them have no history at all and reach their
  /// final reading immediately — only the ones with a time axis need to be left
  /// running.
  final double captureAt;

  /// Called once, after the programme has frozen. The renderer uses it to tell
  /// the browser the picture is final.
  final void Function()? onFrozen;

  final Float32List _peak = Float32List(MeterShape.maxChannels);
  final Float32List _rms = Float32List(MeterShape.maxChannels);
  final Float32List _vu = Float32List(MeterShape.maxChannels);
  final Uint32List _clip = Uint32List(MeterShape.maxChannels);
  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);
  final Float32List _spectrumPeak = Float32List(MeterShape.spectrumBands);
  final Float32List _spectrumPan = Float32List(MeterShape.spectrumBands);
  final Float32List _scope = Float32List(MeterShape.maxScopeFrames * 2);
  final Float32List _histogram = Float32List(MeterShape.histogramBins);

  int _frame = 0;
  double _t = 0.0;
  int _generation = 0;

  /// Short-term readings gathered so far, for the distribution and the range.
  final List<double> _shortTerms = <double>[];

  MockSource({this.dt = 0.094, this.captureAt = 4.0, this.onFrozen}) {
    for (var i = 0; i < MeterShape.spectrumBands; i++) {
      _spectrumPeak[i] = MeterShape.dbFloor;
    }
    _advance();
  }

  bool get isFrozen => _t >= captureAt;

  bool _announced = false;

  @override
  bool refresh() {
    if (isFrozen) {
      // Once, and only after a frame has been painted holding the final
      // reading — the callback is what opens the shutter.
      if (!_announced) {
        _announced = true;
        onFrozen?.call();
      }
      return false;
    }
    _frame++;
    _advance();
    return true;
  }

  // --- The programme --------------------------------------------------------

  /// Deterministic value noise in 0..1. A hash rather than a PRNG so that any
  /// point can be sampled without having drawn the ones before it.
  double _noise(double x, int seed) {
    final i = x.floor();
    final f = x - i;
    double at(int n) {
      var h = (n * 374761393 + seed * 668265263) & 0x7fffffff;
      h = (h ^ (h >> 13)) * 1274126177 & 0x7fffffff;
      return (h & 0xffff) / 0xffff;
    }

    // Smoothstep between integer lattice points, so the result is continuous.
    final s = f * f * (3 - 2 * f);
    return at(i) * (1 - s) + at(i + 1) * s;
  }

  /// Where the programme is in its arrangement, 0..1 through four sections.
  ///
  /// A single envelope would give a distribution with one peak and a loudness
  /// range of almost nothing, and the range and the histogram are two of the
  /// fourteen modules. So the material has a quiet opening, a body, a break and
  /// a louder final section — which is what produces a range worth reading.
  double _sectionLevel(double t) {
    if (t < 3.0) return 0.42; // opening, well below the body
    if (t < 10.0) return 0.86; // body
    if (t < 13.0) return 0.55; // break
    return 1.0; // final section, the loudest thing here
  }

  void _advance() {
    _t = _frame * dt;
    _generation++;

    final section = _sectionLevel(_t);
    // Bar-rate movement, so the meters read like music rather than like noise.
    final beat = 0.5 + 0.5 * math.sin(_t * 2 * math.pi * 2.0);
    final drift = _noise(_t * 1.3, 11);
    final env = (section * (0.78 + 0.22 * beat) * (0.9 + 0.2 * drift)).clamp(
      0.0,
      1.0,
    );

    // --- Levels, per channel ---
    for (var c = 0; c < 2; c++) {
      final trim = c == 0 ? 0.0 : -0.6 - 0.5 * _noise(_t * 0.7, 5 + c);
      _peak[c] = (-5.2 - 9.0 * (1 - env) + trim).clamp(-60.0, 0.0);
      _rms[c] = (-17.5 - 11.0 * (1 - env) + trim).clamp(-60.0, 0.0);
      // A dBFS level, not a VU reading: the module subtracts the
      // calibration's `vuReference` (-18 dBFS) to get the needle's position, so
      // reporting -3 here pinned it hard against the right stop. Around -20
      // dBFS puts it just below zero VU, where a needle is meant to sit.
      _vu[c] = (-19.5 - 11.0 * (1 - env) + trim).clamp(-40.0, -2.0);
    }

    // --- Spectrum ---
    // A bass-heavy programme with a broad presence rise and a shelf on top,
    // moving band to band so the analyser has something to hold a peak over.
    for (var b = 0; b < MeterShape.spectrumBands; b++) {
      final hz = bandCentreHz(b);
      final decade = math.log(hz / 20.0) / math.ln10;
      // Roughly pink, plus a low shelf and a presence lift around 3 kHz.
      //
      // **The absolute level matters as much as the shape.** These are 512
      // narrow bands, so the programme's energy is divided between them and no
      // single band is anywhere near the full-scale reading the loudness meters
      // show: a band sitting at −12 dB would be a sine tone, and it renders the
      // spectrogram as one saturated block with no structure in it. Landing
      // around −28 at the bottom and −65 at the top puts the curve in the
      // middle of the analyser's 0…−96 scale, where its shape can be read.
      var db = -50.0 - 11.0 * decade;
      db += 6.0 * math.exp(-math.pow(decade - 0.28, 2) / 0.10);
      db += 3.0 * math.exp(-math.pow(decade - 2.2, 2) / 0.22);
      // Air above 12 kHz falls away faster than the tilt alone would give.
      if (hz > 12000) db -= (math.log(hz / 12000) / math.ln10) * 18.0;
      // Movement, and enough of it that the spectrogram has visible grain
      // rather than a flat wash: band-to-band wander plus the beat in the bass.
      //
      // **Band and time are separate noise fields.** One field indexed by
      // `band + time` correlates the two axes, and a spectrogram's two axes are
      // band and time — so every feature came out as a diagonal streak, which
      // is a pattern no programme makes. Apart, they give steady tones that
      // hold a horizontal line and transients that cut a vertical one.
      db += 16.0 * (_noise(b * 0.05, 23) - 0.5);
      db += 10.0 * (_noise(_t * 1.6, 29) - 0.5);
      db +=
          5.0 * (_noise(b * 0.37, 31) - 0.5) * (_noise(_t * 3.1, 37) - 0.5) * 2;
      db += 4.0 * (beat - 0.5) * (1.0 - decade / 3.0).clamp(0.0, 1.0);
      db += 20 * math.log(env.clamp(0.05, 1.0)) / math.ln10 * 0.5;

      final v = db.clamp(MeterShape.dbFloor, 0.0);
      _spectrum[b] = v;
      if (v > _spectrumPeak[b]) _spectrumPeak[b] = v;

      // Bass centred, mids narrow, highs wide — a normal mix, and it gives the
      // stereo cloud a shape that widens as it goes up.
      // Bass centred, everything above it progressively wider — but scattered
      // rather than a clean function of frequency, which drew the cloud as a
      // geometric cone.
      final width = (0.25 + 0.75 * (decade / 3.0)).clamp(0.0, 1.0);
      final wander =
          _noise(b * 0.17, 41) - 0.5 + 0.4 * (_noise(_t * 0.5, 43) - 0.5);
      _spectrumPan[b] = (wander * 2.2 * width).clamp(-1.0, 1.0);
    }

    // --- Waveform ---
    // A bass note with harmonics and a little asymmetry, so the oscilloscope
    // shows a shape and the phase scope draws a tilted, filled figure rather
    // than a diagonal line.
    const cycles = 3.0;
    for (var i = 0; i < MeterShape.scopePoints; i++) {
      final p = i / MeterShape.scopePoints;
      final phase = 2 * math.pi * (p * cycles + _t * 0.7);
      var l = math.sin(phase) * 0.62;
      l += math.sin(phase * 2 + 0.6) * 0.19;
      l += math.sin(phase * 3 + 1.2) * 0.09;
      l += (_noise(p * 240 + _t * 60, 7) - 0.5) * 0.06;
      // The right channel is the left, delayed and slightly narrower: a real
      // correlation rather than a copy or a coin toss.
      final phaseR = phase - 0.62;
      var r = math.sin(phaseR) * 0.54;
      r += math.sin(phaseR * 2 + 1.4) * 0.21;
      r += math.sin(phaseR * 3 + 0.3) * 0.08;
      r += (_noise(p * 240 + _t * 60, 9) - 0.5) * 0.14;

      _scope[i * 2] = (l * env).clamp(-1.0, 1.0);
      _scope[i * 2 + 1] = (r * env).clamp(-1.0, 1.0);
    }

    // --- The gated distribution ---
    // Collected from the short-term readings actually reported, so the
    // histogram, the range and the distribution module cannot disagree.
    final s = lufsShort;
    if (!s.isNaN) _shortTerms.add(s);
    _fillHistogram();
  }

  void _fillHistogram() {
    for (var i = 0; i < MeterShape.histogramBins; i++) {
      _histogram[i] = 0.0;
    }
    if (_shortTerms.isEmpty) return;

    const span = MeterShape.histogramMaxLufs - MeterShape.histogramMinLufs;
    var counted = 0;
    for (final lufs in _shortTerms) {
      final bin =
          ((lufs - MeterShape.histogramMinLufs) /
                  span *
                  MeterShape.histogramBins)
              .floor();
      if (bin < 0 || bin >= MeterShape.histogramBins) continue;
      _histogram[bin] += 1.0;
      counted++;
    }
    if (counted == 0) return;
    for (var i = 0; i < MeterShape.histogramBins; i++) {
      _histogram[i] /= counted;
    }
  }

  // --- What the signal is ---------------------------------------------------

  @override
  int get generation => _generation;
  @override
  int get sampleRate => 48000;
  @override
  int get channels => 2;
  @override
  double get elapsedSeconds => _t;
  @override
  bool get isRunning => true;
  @override
  Transport get transport => Transport.none;
  @override
  int get droppedFrames => 0;
  @override
  bool get hasOverrun => false;
  @override
  bool get hasLoudness => true;
  @override
  bool get hasSpectrum => true;

  // --- Loudness -------------------------------------------------------------

  double get _env {
    final beat = 0.5 + 0.5 * math.sin(_t * 2 * math.pi * 2.0);
    final drift = _noise(_t * 1.3, 11);
    return (_sectionLevel(_t) * (0.78 + 0.22 * beat) * (0.9 + 0.2 * drift))
        .clamp(0.0, 1.0);
  }

  /// Momentary needs 400 ms of audio before it means anything, and says so
  /// until it has them. Every module renders that as an em dash.
  @override
  double get lufsMomentary =>
      _t < 0.4 ? double.nan : (-12.3 - 13.0 * (1 - _env)).clamp(-60.0, 0.0);

  /// Short-term needs three seconds. Smoothed against the momentary reading so
  /// the timeline is a line rather than a comb.
  @override
  double get lufsShort {
    if (_t < 3.0) return double.nan;
    final slow = 0.5 + 0.5 * math.sin(_t * 0.55 + 0.7);
    return (-13.1 - 16.0 * (1 - _sectionLevel(_t)) - 1.6 * slow).clamp(
      -60.0,
      0.0,
    );
  }

  /// Integrated settles: it is an average over everything gated in so far, so
  /// it moves a lot early and barely at all later.
  @override
  double get lufsIntegrated {
    if (_t < 3.0) return double.nan;
    const target = -14.0;
    final settle = (1 - math.exp(-(_t - 3.0) / 3.2)).clamp(0.0, 1.0);
    return -16.0 + (target + 16.0) * settle;
  }

  @override
  double get loudnessRange {
    if (_shortTerms.length < 40) return double.nan;
    final sorted = List<double>.from(_shortTerms)..sort();
    final lo = sorted[(sorted.length * 0.10).floor()];
    final hi =
        sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    return hi - lo;
  }

  @override
  double get loudnessRangeLow {
    if (_shortTerms.length < 40) return double.nan;
    final sorted = List<double>.from(_shortTerms)..sort();
    return sorted[(sorted.length * 0.10).floor()];
  }

  @override
  double get loudnessRangeHigh {
    if (_shortTerms.length < 40) return double.nan;
    final sorted = List<double>.from(_shortTerms)..sort();
    return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
  }

  @override
  double get loudnessRangeGate =>
      _shortTerms.length < 40 ? double.nan : lufsIntegrated - 20.0;

  // --- Peaks ----------------------------------------------------------------

  @override
  double get truePeak =>
      (-0.5 - 11.0 * (1 - _env) + 0.3 * _noise(_t * 6, 61)).clamp(-60.0, 3.0);

  /// Into the last dB, so the validator has a real failure to report and the
  /// alert meter has a reason to be red.
  @override
  double get truePeakMax => _t < 0.4 ? double.nan : -0.2;

  @override
  double get samplePeakMax => _t < 0.4 ? double.nan : -1.9;

  @override
  double get dynamicRangeShort => _t < 3.0 ? double.nan : 8.4;
  @override
  double get dynamicRangeIntegrated =>
      _shortTerms.length < 40 ? double.nan : loudnessRange;
  @override
  double get crestFactor => _t < 0.4 ? double.nan : 11.6 + 1.4 * _noise(_t, 71);
  @override
  double get peakToLoudnessRatio =>
      _t < 3.0 ? double.nan : lufsIntegrated.abs() - 0.2;
  @override
  double get peakToShortTermRatio =>
      _t < 3.0 ? double.nan : lufsShort.abs() - 0.2;

  // --- Stereo ---------------------------------------------------------------

  /// Well correlated but not mono, and never negative: a normal mix. The phase
  /// scope and the correlation readout both read this.
  @override
  double get correlation =>
      _t < 0.4 ? double.nan : 0.55 + 0.17 * math.sin(_t * 0.6 + 1.1);

  @override
  double get balance =>
      _t < 0.4 ? double.nan : -0.04 + 0.05 * math.sin(_t * 0.31);

  @override
  Float32List get peak => _peak;
  @override
  Float32List get rms => _rms;
  @override
  Float32List get vu => _vu;
  @override
  Uint32List get clip => _clip;
  @override
  Float32List get spectrum => _spectrum;
  @override
  Float32List get spectrumPeak => _spectrumPeak;
  @override
  Float32List get spectrumPan => _spectrumPan;
  @override
  Float32List get scope => _scope;
  @override
  int get scopeFrames => MeterShape.scopePoints;
  @override
  Float32List get histogram => _histogram;
}
