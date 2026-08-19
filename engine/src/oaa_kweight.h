/*
 * oaa_kweight.h — the ITU-R BS.1770-4 K-weighting filter.
 *
 * SPDX-License-Identifier: MIT
 *
 * Two cascaded biquads: a high-frequency shelf that models the acoustic effect
 * of a head in a diffuse field, then an RLB high-pass that discounts the low
 * end. Everything the loudness measurement reports is downstream of these, so
 * an error here is an error in every loudness number Open Audio Analyzer
 * displays.
 *
 * The coefficients are **designed at the stream's actual sample rate** rather
 * than read from the 48 kHz table the standard prints. The table is a worked
 * example, not the definition: the definition is the analog prototype below,
 * and using the 48 kHz numbers at 44.1 kHz shifts both corner frequencies by
 * nearly 9% — which is a real, silent error on the most common delivery rate
 * there is. `oaa_kweight_test` asserts that designing at 48 kHz reproduces the
 * printed table, which is what ties our derivation to the standard's.
 */

#ifndef OAA_KWEIGHT_H
#define OAA_KWEIGHT_H

#include <stdint.h>

/* Direct form I. The state is per channel; the coefficients are not. */
typedef struct {
  double b0, b1, b2, a1, a2;
} oaa_biquad;

typedef struct {
  double x1, x2, y1, y2;
} oaa_biquad_state;

/*
 * Design both stages for `sample_rate`.
 *
 * Valid for any rate the engine accepts. The prototype's corner frequencies are
 * well below Nyquist at every one of them, so no rate needs special handling.
 */
void oaa_kweight_design(double sample_rate, oaa_biquad *shelf,
                        oaa_biquad *highpass);

static inline double oaa_biquad_process(const oaa_biquad *c,
                                        oaa_biquad_state *s, double x) {
  const double y = c->b0 * x + c->b1 * s->x1 + c->b2 * s->x2 - c->a1 * s->y1 -
                   c->a2 * s->y2;
  s->x2 = s->x1;
  s->x1 = x;
  s->y2 = s->y1;
  s->y1 = y;
  return y;
}

/*
 * The BS.1770-4 weight for a channel, by its index in the stream.
 *
 * The standard weights surround channels 1.41 (+1.5 dB) and excludes LFE
 * entirely. Applying that needs to know which channel is which, and an
 * interleaved buffer does not say — so this assumes the conventional order for
 * each channel count:
 *
 *   1   M
 *   2   L R
 *   3   L R C
 *   4   L R Ls Rs          (quad — *not* L R C LFE)
 *   5   L R C Ls Rs
 *   6+  L R C LFE Ls Rs [Lrs Rrs]   (SMPTE film order)
 *
 * The four-channel case is the one that bites: reading it as L R C LFE would
 * silently zero a real surround channel. Open Audio Analyzer has no
 * channel-layout metadata to consult yet; when a device or file source supplies
 * one, this function should take it instead of guessing from the count.
 */
double oaa_channel_weight(uint32_t index, uint32_t count);

#endif /* OAA_KWEIGHT_H */
