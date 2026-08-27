/*
 * oaa_kweight.c — designing the BS.1770-4 K-weighting filter.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "oaa_kweight.h"

#include <math.h>

#define OAA_PI 3.14159265358979323846

/*
 * The analog prototype, from ITU-R BS.1770-4.
 *
 * These are not rounded — the extra digits are load-bearing. The standard
 * prints its 48 kHz coefficients to 14 decimal places, and reproducing them
 * from this prototype (which `oaa_kweight_test` checks) needs the prototype at
 * comparable precision. Rounding f0 to 1682 Hz moves the printed coefficients
 * in their sixth decimal place.
 */
#define OAA_SHELF_F0 1681.974450955533
#define OAA_SHELF_GAIN_DB 3.999843853973347
#define OAA_SHELF_Q 0.7071752369554196

/* The exponent relating the shelf's band gain to its high gain. Also from the
 * standard's derivation, and also not a round number. */
#define OAA_SHELF_VB_EXPONENT 0.4996667741545416

#define OAA_HIGHPASS_F0 38.13547087602444
#define OAA_HIGHPASS_Q 0.5003270373238773

void oaa_kweight_design(double sample_rate, oaa_biquad *shelf,
                        oaa_biquad *highpass) {
  /* --- Stage 1: high-frequency shelf ---------------------------------- */
  {
    const double k = tan(OAA_PI * OAA_SHELF_F0 / sample_rate);
    const double vh = pow(10.0, OAA_SHELF_GAIN_DB / 20.0);
    const double vb = pow(vh, OAA_SHELF_VB_EXPONENT);
    const double a0 = 1.0 + k / OAA_SHELF_Q + k * k;

    shelf->b0 = (vh + vb * k / OAA_SHELF_Q + k * k) / a0;
    shelf->b1 = 2.0 * (k * k - vh) / a0;
    shelf->b2 = (vh - vb * k / OAA_SHELF_Q + k * k) / a0;
    shelf->a1 = 2.0 * (k * k - 1.0) / a0;
    shelf->a2 = (1.0 - k / OAA_SHELF_Q + k * k) / a0;
  }

  /* --- Stage 2: RLB high-pass ------------------------------------------ */
  {
    const double k = tan(OAA_PI * OAA_HIGHPASS_F0 / sample_rate);
    const double denominator = 1.0 + k / OAA_HIGHPASS_Q + k * k;

    /* Deliberately left unnormalised. The standard's table gives exactly
     * 1, -2, 1 for this stage's numerator, and dividing through by the
     * denominator here would scale the filter's passband gain away from unity
     * and shift every loudness reading. */
    highpass->b0 = 1.0;
    highpass->b1 = -2.0;
    highpass->b2 = 1.0;
    highpass->a1 = 2.0 * (k * k - 1.0) / denominator;
    highpass->a2 = (1.0 - k / OAA_HIGHPASS_Q + k * k) / denominator;
  }
}

double oaa_channel_weight(uint32_t index, uint32_t count) {
  /* See the header for why the layout is inferred from the count, and why the
   * four-channel case is special-cased. */
  if (count <= 3) {
    return 1.0; /* M, or L R, or L R C */
  }
  if (count == 4) {
    return index < 2 ? 1.0 : 1.41; /* quad: L R Ls Rs */
  }
  if (count == 5) {
    return index < 3 ? 1.0 : 1.41; /* L R C Ls Rs */
  }

  /* 5.1 and wider, SMPTE order: L R C LFE Ls Rs [Lrs Rrs]. */
  switch (index) {
    case 0:
    case 1:
    case 2:
      return 1.0;
    case 3:
      /* LFE is excluded from loudness by the standard, not attenuated. */
      return 0.0;
    case 4:
    case 5:
      /* The surround pair, and only that pair. */
      return 1.41;
    default:
      /* Everything past 5.1 is unweighted. The +1.5 dB belongs to the two
       * surround channels of the 5.1 layout, not to "any channel behind you":
       * Report ITU-R BS.2217's channel table gives 7.1 as
       * 1.00 / 1.00 / 1.00 / N/A / 1.41 / 1.41 / 1.00 / 1.00, so the rear pair
       * Lrs and Rrs weigh the same as the front. Weighting them 1.41 read its
       * two 7.1 compliance files 0.35 LU high, which is 3.5 times the tolerance
       * and the only case in either official set that was wrong by more than
       * 0.03. Nothing narrower than 7.1 is affected — a 5.1 file never reaches
       * this arm. */
      return 1.0;
  }
}
