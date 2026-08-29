// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

/// The A-weighting curve of IEC 61672-1, in dB, at [hz].
///
/// Zero at 1 kHz by construction — the standard defines the curve as the
/// filter's magnitude response normalised there, and the normalisation is
/// computed rather than quoted, so the reading at 1 kHz is exactly the
/// unweighted one rather than exactly the unweighted one plus a rounding
/// error. Negative below about 500 Hz and above 6 kHz, a little over +1 dB
/// between 1.5 and 4 kHz, −50.5 dB at 20 Hz and −9.3 dB at 20 kHz.
///
/// This is a function of frequency and nothing else, which is why it is here
/// and not a measurement the engine makes. The analyser applies it to *one
/// band* at a time — the one under its cursor — where it is exact: a band of
/// the spectrum is a level at a frequency, and the A-weighted level of a
/// component at frequency *f* is its level plus this curve at *f*. It is not
/// applied to the curve as a whole, and an A-weighted *loudness* — the sum
/// over the weighted spectrum — is a different number that nothing here
/// reports; `docs/METRICS.md` says so.
///
/// The band is a fifty-first of an octave wide and the curve's steepest slope
/// is about 17 dB per octave, at the bottom of the range, so the value at the
/// band's centre is within a fifth of a decibel of the value anywhere in the
/// band, and within a hundredth above 200 Hz.
double aWeightingDb(double hz) => _responseDb(hz) - _responseDb(1000);

/// 20·log10 of the unnormalised A response — the four poles of
/// IEC 61672-1:2013 § 5.4.11, with the constant term left for the caller.
double _responseDb(double hz) {
  final f2 = hz * hz;
  final ra =
      _f4Squared *
      f2 *
      f2 /
      ((f2 + _f1Squared) *
          math.sqrt((f2 + _f2Squared) * (f2 + _f3Squared)) *
          (f2 + _f4Squared));
  return 20 * math.log(ra) / math.ln10;
}

// The four pole frequencies of the standard, squared once. IEC 61672-1 gives
// them to a tenth of a hertz, and a curve computed from these agrees with its
// table to the tenth of a decibel the table is printed to.
const double _f1Squared = 20.598997 * 20.598997;
const double _f2Squared = 107.65265 * 107.65265;
const double _f3Squared = 737.86223 * 737.86223;
const double _f4Squared = 12194.217 * 12194.217;
