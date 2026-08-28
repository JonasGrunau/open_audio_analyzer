// SPDX-License-Identifier: GPL-3.0-or-later
//
// The spectrum analysis, held against arithmetic.
//
// An FFT is unusually easy to get subtly wrong and unusually easy to check:
// feed it a sine of known amplitude at a known frequency and the answer is a
// number you can write down in advance. The failure this suite exists to catch
// is not "no spectrum" — a transform with its scaling wrong, its window
// uncompensated or its bands mapped backwards still fills the array with
// plausible-looking data, and a spectrum analyser is exactly the kind of
// display nobody reads absolute numbers off often enough to notice.
//
// Most level assertions below put their tone **exactly on a bin centre**, so
// that a failure is unambiguously the scaling and not the window. A test that
// allowed for windowing error would have to tolerate more than a decibel and
// would then pass with the scaling factor wrong by half.
//
// The two exceptions are deliberate and are the point of their own tests: the
// transform is zero-padded to four times the window, which is what samples the
// main lobe finely enough to read a tone that falls between window bins and to
// draw the bottom octaves as a curve rather than as a staircase.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_engine/oaa_engine.dart';
import 'package:test/test.dart';

/// Window-bin spacing is `sampleRate / 4096` — the resolution, not the
/// sampling. A tone at an exact multiple of it lands in one window bin with no
/// leakage into its neighbours.
double _binCentreHz(int bin, int sampleRate) => bin * sampleRate / 4096;

/// Pushes `seconds` of one or two sines and returns the engine.
///
/// Long enough that several transforms run: the peak hold, the band mapping and
/// the flag all become meaningful only after a full 4096-point window.
OaaEngine _analysed({
  required List<double> frequencies,
  required List<double> amplitudes,
  int sampleRate = 48000,
  int channels = 2,
  List<double> channelGains = const [1.0, 1.0],
  double seconds = 0.5,
}) {
  final engine = OaaEngine.start(
    source: OaaSource.push,
    sampleRate: sampleRate,
    channels: channels,
  );

  final frames = (seconds * sampleRate).round();
  final buffer = Float32List(frames * channels);

  for (var i = 0; i < frames; i++) {
    var sample = 0.0;
    for (var t = 0; t < frequencies.length; t++) {
      sample +=
          amplitudes[t] *
          math.sin(2 * math.pi * frequencies[t] * i / sampleRate);
    }
    for (var c = 0; c < channels; c++) {
      buffer[i * channels + c] = sample * channelGains[c];
    }
  }

  engine.push(buffer);
  return engine;
}

/// The band holding the most energy.
int _loudestBand(OaaEngine engine) {
  var loudest = 0;
  for (var band = 1; band < kOaaSpectrumBands; band++) {
    if (engine.spectrum[band] > engine.spectrum[loudest]) loudest = band;
  }
  return loudest;
}

void main() {
  test('a full-scale sine on a bin centre reads 0 dBFS', () {
    // Bin 85 at 48 kHz is 996.09 Hz — as close to 1 kHz as the transform can
    // put a tone without leaking into its neighbours.
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [1.0],
    );
    addTearDown(engine.dispose);

    expect(engine.hasSpectrum, isTrue);
    expect(engine.spectrum[_loudestBand(engine)], closeTo(0.0, 0.1));
  });

  test('level is linear in dB, not in amplitude', () {
    for (final dbfs in [-6.0, -20.0, -60.0]) {
      final engine = _analysed(
        frequencies: [_binCentreHz(85, 48000)],
        amplitudes: [math.pow(10, dbfs / 20).toDouble()],
      );
      addTearDown(engine.dispose);

      expect(
        engine.spectrum[_loudestBand(engine)],
        closeTo(dbfs, 0.1),
        reason: 'a $dbfs dBFS sine should read $dbfs dBFS',
      );
    }
  });

  test('a tone lands where its frequency is, to the resolution available', () {
    // The tolerance is the *coarser* of the two resolutions in play, and it has
    // to be, because which one dominates flips partway up the display:
    //
    //   Below about 900 Hz a display band is narrower than an FFT bin, so
    //   several consecutive bands map to the same bin and read identically.
    //   Asking which of them is loudest has no answer — the transform does not
    //   know. A 50 Hz tone genuinely cannot be placed better than +/-11.7 Hz.
    //
    //   Above that the bands are the coarse ones, and 3% — about a twentieth of
    //   an octave — is a band or so wide.
    //
    // Insisting on one band everywhere would mean asserting a tie-break, which
    // is not a property of the measurement.
    const binHz = 48000 / 4096;

    for (final hz in [50.0, 440.0, 1000.0, 6300.0, 15000.0]) {
      final engine = _analysed(frequencies: [hz], amplitudes: [0.5]);
      addTearDown(engine.dispose);

      final band = _loudestBand(engine);
      expect(
        (bandCentreHz(band) - hz).abs(),
        lessThan(math.max(binHz, hz * 0.03)),
        reason:
            '$hz Hz landed in band $band, centred at '
            '${bandCentreHz(band).toStringAsFixed(1)} Hz',
      );
    }
  });

  test('a tone between two window bins still reads its own level', () {
    // Halfway between window bins 85 and 86 is the worst case for Hann
    // scalloping. Transforming the 4096-point window on its own samples the
    // main lobe only at the bin centres, so its peak is missed and the tone
    // reads about 1.4 dB low — every level on screen sagging by an amount that
    // depends on where the content happens to sit relative to the bins.
    //
    // Padding to 16384 samples the same lobe four times as finely, and 0.3 dB
    // is what is left. Tighten this and it fails; loosen it past a decibel and
    // it would pass with the padding removed, which is the whole point.
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 48000) + 48000 / 4096 / 2],
      amplitudes: [1.0],
    );
    addTearDown(engine.dispose);

    expect(engine.spectrum[_loudestBand(engine)], closeTo(0.0, 0.3));
  });

  test('the bottom octave is drawn as a curve, not as two bricks', () {
    // The complaint this guards against is visual and the measurement behind
    // it is not: 20 to 40 Hz is 51 of the 512 display bands, and an unpadded
    // 4096-point transform at 48 kHz has exactly *two* bins in there. Fifty-one
    // bands sharing two values draw as two flat slabs a third of the module
    // wide, and no amount of painting fixes it.
    //
    // Padding alone takes that from two values to eight, which is still six
    // treads. Reading between the bins as well gives every band its own value,
    // so the threshold here is most of the octave rather than a handful: at
    // eight it would pass with the interpolation deleted, and at two with the
    // padding deleted as well.
    final engine = _analysed(
      frequencies: [41.2, 55.0, 82.4, 110.0],
      amplitudes: [0.2, 0.2, 0.2, 0.2],
    );
    addTearDown(engine.dispose);

    final first = bandOfHz(20).round().clamp(0, kOaaSpectrumBands - 1);
    final last = bandOfHz(40).round().clamp(0, kOaaSpectrumBands - 1);

    final distinct = <double>{
      for (var band = first; band <= last; band++) engine.spectrum[band],
    };
    expect(distinct.length, greaterThanOrEqualTo((last - first) * 4 ~/ 5));
  });

  test('two tones stay separate, and the gap between them stays empty', () {
    final engine = _analysed(
      frequencies: [_binCentreHz(9, 48000), _binCentreHz(427, 48000)],
      amplitudes: [0.5, 0.5],
      seconds: 0.5,
    );
    addTearDown(engine.dispose);

    // 105.5 Hz and 5004 Hz. On a log axis those are nearly 400 bands apart,
    // which is the whole reason the display is log-spaced.
    final low = bandOfHz(_binCentreHz(9, 48000)).round();
    final high = bandOfHz(_binCentreHz(427, 48000)).round();

    expect(engine.spectrum[low], closeTo(-6.02, 0.2));
    expect(engine.spectrum[high], closeTo(-6.02, 0.2));

    // Halfway between them on the log axis — about 700 Hz — has nothing in it.
    final between = (low + high) ~/ 2;
    expect(engine.spectrum[between], lessThan(-60.0));
  });

  test('the band mapping follows the sample rate', () {
    // The same tone at three sample rates must land in the same *band*, which
    // it only can if the bin-to-frequency conversion uses the rate rather than
    // assuming 48 kHz. Getting this wrong shifts the whole display by a fifth
    // of an octave at 44.1 kHz and nobody notices by eye.
    final bands = <int>[];
    for (final rate in [44100, 48000, 96000]) {
      final engine = _analysed(
        frequencies: [1000.0],
        amplitudes: [0.5],
        sampleRate: rate,
      );
      addTearDown(engine.dispose);
      bands.add(_loudestBand(engine));
    }

    expect(bands[1], closeTo(bands[0].toDouble(), 1));
    expect(bands[2], closeTo(bands[0].toDouble(), 1));
  });

  test('per-band pan follows the channel the energy is in', () {
    final right = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
      channelGains: const [0.0, 1.0],
    );
    addTearDown(right.dispose);
    expect(right.spectrumPan[_loudestBand(right)], closeTo(1.0, 0.01));

    final left = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
      channelGains: const [1.0, 0.0],
    );
    addTearDown(left.dispose);
    expect(left.spectrumPan[_loudestBand(left)], closeTo(-1.0, 0.01));

    final centre = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
    );
    addTearDown(centre.dispose);
    expect(centre.spectrumPan[_loudestBand(centre)], closeTo(0.0, 0.01));
  });

  test('the peak hold never sits below the spectrum it holds', () {
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
    );
    addTearDown(engine.dispose);

    for (var band = 0; band < kOaaSpectrumBands; band++) {
      expect(
        engine.spectrumPeak[band],
        greaterThanOrEqualTo(engine.spectrum[band]),
        reason: 'band $band',
      );
    }
    // And on each of the four signals a pair can be read as, since each
    // carries a hold of its own.
    for (final source in SpectrumSource.values) {
      final bands = engine.spectrumOf(source);
      final peaks = engine.spectrumPeakOf(source);
      for (var band = 0; band < kOaaSpectrumBands; band++) {
        expect(
          peaks[band],
          greaterThanOrEqualTo(bands[band]),
          reason: '${source.id} band $band',
        );
      }
    }
  });

  // --- The four signals of a pair --------------------------------------------
  //
  // Mid is (L + R) / 2 and side is (L − R) / 2, and both are *transformed as
  // signals*, so their arithmetic is the arithmetic of the signal: a tone in
  // one channel only is half as loud — 6.02 dB down — on both, a tone in both
  // channels is all mid and no side, and an anti-phase tone the reverse. The
  // per-channel folds read the tone at its own level or not at all. None of
  // that can be got from per-channel power, which is what these hold against.

  test('a sine in the left channel reads on left, not right, and −6 dB on '
      'mid and side', () {
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
      channelGains: const [1.0, 0.0],
    );
    addTearDown(engine.dispose);
    final band = _loudestBand(engine);

    expect(engine.spectrumOf(SpectrumSource.all)[band], closeTo(-6.02, 0.1));
    expect(engine.spectrumOf(SpectrumSource.left)[band], closeTo(-6.02, 0.1));
    expect(engine.spectrumOf(SpectrumSource.right)[band], kOaaDbFloor);
    expect(engine.spectrumOf(SpectrumSource.mid)[band], closeTo(-12.04, 0.1));
    expect(engine.spectrumOf(SpectrumSource.side)[band], closeTo(-12.04, 0.1));
  });

  test('a sine in both channels is all mid and no side; anti-phase, the '
      'reverse', () {
    final inPhase = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
    );
    addTearDown(inPhase.dispose);
    final band = _loudestBand(inPhase);

    expect(inPhase.spectrumOf(SpectrumSource.all)[band], closeTo(-6.02, 0.1));
    expect(inPhase.spectrumOf(SpectrumSource.left)[band], closeTo(-6.02, 0.1));
    expect(inPhase.spectrumOf(SpectrumSource.right)[band], closeTo(-6.02, 0.1));
    expect(inPhase.spectrumOf(SpectrumSource.mid)[band], closeTo(-6.02, 0.1));
    expect(inPhase.spectrumOf(SpectrumSource.side)[band], kOaaDbFloor);

    final antiPhase = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
      channelGains: const [1.0, -1.0],
    );
    addTearDown(antiPhase.dispose);

    expect(antiPhase.spectrumOf(SpectrumSource.mid)[band], kOaaDbFloor);
    expect(
      antiPhase.spectrumOf(SpectrumSource.side)[band],
      closeTo(-6.02, 0.1),
    );
    // The combined fold takes the loudest channel, so it does not care that
    // the two cancel; the pan sees equal energy either side.
    expect(antiPhase.spectrumOf(SpectrumSource.all)[band], closeTo(-6.02, 0.1));
    expect(antiPhase.spectrumPan[band], closeTo(0.0, 0.01));
  });

  test('a one-channel engine has a left and nothing else', () {
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 48000)],
      amplitudes: [0.5],
      channels: 1,
      channelGains: const [1.0],
    );
    addTearDown(engine.dispose);

    // Left is the one channel there is, folded by the same rule as the
    // combined set — so band for band they are the same numbers.
    final left = engine.spectrumOf(SpectrumSource.left);
    for (var band = 0; band < kOaaSpectrumBands; band++) {
      expect(left[band], engine.spectrum[band], reason: 'band $band');
    }

    // The other three are not silence — the floor would draw as a measured
    // nothing — they are unmeasured, which is NaN, in every band.
    for (final source in [
      SpectrumSource.right,
      SpectrumSource.mid,
      SpectrumSource.side,
    ]) {
      final bands = engine.spectrumOf(source);
      final peaks = engine.spectrumPeakOf(source);
      for (var band = 0; band < kOaaSpectrumBands; band++) {
        expect(bands[band].isNaN, isTrue, reason: '${source.id} band $band');
        expect(peaks[band].isNaN, isTrue, reason: '${source.id} band $band');
      }
    }
  });

  test('silence reads as the floor, not as zero', () {
    final engine = _analysed(frequencies: const [], amplitudes: const []);
    addTearDown(engine.dispose);

    // The distinction matters: an array of 0.0 draws as a flat line at full
    // scale, which is the single most alarming thing a spectrum analyser can
    // show and would be entirely an artefact.
    expect(engine.hasSpectrum, isTrue);
    for (var band = 0; band < kOaaSpectrumBands; band++) {
      expect(engine.spectrum[band], kOaaDbFloor);
    }
  });

  test('bands above Nyquist stay empty rather than wrapping', () {
    // At 44.1 kHz the top of the fixed 20 Hz - 20 kHz display is only just
    // inside Nyquist; the point of the assertion is that nothing above it is
    // ever filled by aliasing the bin index round.
    final engine = _analysed(
      frequencies: [_binCentreHz(85, 44100)],
      amplitudes: [0.5],
      sampleRate: 44100,
    );
    addTearDown(engine.dispose);

    final nyquistBand = bandOfHz(44100 / 2).round();
    for (var band = nyquistBand; band < kOaaSpectrumBands; band++) {
      expect(engine.spectrum[band], kOaaDbFloor, reason: 'band $band');
    }
  });

  test('the frequency mapping round-trips', () {
    for (var band = 0; band < kOaaSpectrumBands; band += 37) {
      expect(bandOfHz(bandCentreHz(band)), closeTo(band.toDouble(), 1e-9));
    }
  });
}
