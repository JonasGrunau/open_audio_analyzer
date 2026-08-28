// SPDX-License-Identifier: GPL-3.0-or-later

/// How protocol versions 4 and 5 carry the arrays a module *plots*.
///
/// ---------------------------------------------------------------------------
/// The rule, which is narrower than "compress the snapshot"
///
/// **A number a person reads stays exact; a value that only ever becomes a
/// pixel gets display precision.** Every scalar in the snapshot — LUFS, true
/// peak, LRA, correlation, crest — is still `float32` on the wire, and so are
/// `peak`, `rms`, `vu` and `clip`, which are printed as figures beside the
/// meters they drive. Those are what somebody makes a delivery decision from,
/// and 128 bytes is not worth the argument.
///
/// What is quantised is the five arrays that exist to be drawn: 14,336 of the
/// 15,056 bytes, 95 % of the frame, none of it ever displayed as a number.
/// Version 5's eight per-source spectra take the dB encoding too, for the
/// same reason: they become the same pixels.
///
/// ---------------------------------------------------------------------------
/// Why these widths and not fewer bits
///
/// Each was chosen against the widest consumer, not against a round number.
/// The analyser is the widest spectrum consumer and resolves about 0.204 dB per
/// pixel at a default size on a 1920-wide canvas; the spectrogram quantises to
/// 1.625 dB itself. A 1/256 dB step is two orders of magnitude finer than
/// either. The phase scope draws 1.4 px dots into a plot a few hundred pixels
/// across, so a sample needs about ten bits to land on the right one; Q1.14
/// gives fourteen. Nothing here is close to the limit, because being *visually*
/// lossless is the claim being made and a claim that needs the eye tested at
/// the margin is not one worth making.
///
/// ---------------------------------------------------------------------------
/// NaN is data, and it survives
///
/// This is the rule the rest of the protocol is built on — an unmeasured
/// quantity travels as NaN and is drawn as an em dash, because zero is a real
/// reading for correlation, balance and several dB quantities. A fixed-point
/// encoding has no NaN of its own, so each one here reserves a code for it, and
/// that code is excluded from the value range rather than overlapping it. A
/// display that turned "not measured" into "the floor" would draw a spectrum
/// flat along the bottom, which is a picture of silence — and silence is a
/// measurement nobody took.
abstract final class Quantise {
  // --- dB, unsigned 16-bit ---------------------------------------------------

  /// "Not measured" for a dB band.
  static const int dbNaN = 0xFFFF;

  /// Lowest dB the encoding can express. Below the engine's own −144 floor, so
  /// clamping here cannot turn a real reading into a different one.
  static const double dbOrigin = -160.0;

  /// Codes per dB. 1/256 dB, against 0.204 dB per pixel at the widest.
  static const double dbStep = 256.0;

  static const int _dbMax = 0xFFFE;

  static int db(double value) {
    if (value.isNaN) return dbNaN;
    // Clamped *before* rounding, and the comparisons are written so that an
    // infinity takes a branch rather than reaching `round()` — which throws on
    // one. Digital silence is a real reading and arrives here as -Infinity, so
    // this is an ordinary case, not a defensive one.
    final scaled = (value - dbOrigin) * dbStep;
    if (!(scaled > 0)) return 0;
    if (scaled >= _dbMax) return _dbMax;
    return scaled.round();
  }

  static double dbBack(int code) =>
      code == dbNaN ? double.nan : code / dbStep + dbOrigin;

  // --- A signed unit range, 16-bit -------------------------------------------

  /// "Not measured" for a signed unit value. `0x8000`, which is the one code an
  /// int16 has that has no positive twin.
  static const int unitNaN = -32768;

  static const int _unitScale = 32767;

  static int unit(double value) {
    if (value.isNaN) return unitNaN;
    final scaled = value * _unitScale;
    if (scaled <= -_unitScale) return -_unitScale;
    if (scaled >= _unitScale) return _unitScale;
    return scaled.round();
  }

  static double unitBack(int code) =>
      code == unitNaN ? double.nan : code / _unitScale;

  // --- An audio sample, Q1.14 signed 16-bit ----------------------------------

  /// "Not measured" for a sample.
  static const int sampleNaN = -32768;

  /// Q1.14: fourteen fractional bits, so the representable range is ±1.9999
  /// and the step is 6.1e-5. The headroom past ±1 is deliberate — a float file
  /// may legitimately exceed full scale, and a goniometer that folded those
  /// back to the rim would draw a limiter that is not there.
  static const double sampleScale = 16384.0;

  static const int _sampleMax = 32767;

  static int sample(double value) {
    if (value.isNaN) return sampleNaN;
    final scaled = value * sampleScale;
    if (scaled <= -_sampleMax) return -_sampleMax;
    if (scaled >= _sampleMax) return _sampleMax;
    return scaled.round();
  }

  static double sampleBack(int code) =>
      code == sampleNaN ? double.nan : code / sampleScale;

  // --- A fraction of one, unsigned 16-bit ------------------------------------

  /// "Not measured" for a histogram bin.
  static const int fractionNaN = 0xFFFF;

  static const int _fractionMax = 0xFFFE;

  static int fraction(double value) {
    if (value.isNaN) return fractionNaN;
    final scaled = value * _fractionMax;
    if (!(scaled > 0)) return 0;
    if (scaled >= _fractionMax) return _fractionMax;
    return scaled.round();
  }

  static double fractionBack(int code) =>
      code == fractionNaN ? double.nan : code / _fractionMax;
}
