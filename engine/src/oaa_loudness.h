/*
 * oaa_loudness.h — EBU R 128 loudness over the BS.1770-4 K-weighting.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Everything is built from one primitive: the mean square of the K-weighted
 * signal over a 10 ms sub-block. Every published quantity is a window of those
 * sub-blocks, which is what makes the momentary, short-term and integrated
 * readings provably consistent with each other — they are literally different
 * lengths of the same ring.
 *
 *   Momentary   last 40 sub-blocks   (400 ms)
 *   Short-term  last 300 sub-blocks  (3 s)
 *   Integrated  gated mean of every 400 ms block, stepped 100 ms (75% overlap)
 *   LRA         10th to 95th percentile of the gated 3 s distribution
 *
 * ---------------------------------------------------------------------------
 * Why the integrating measurements are histograms
 *
 * Integrated loudness is gated twice: once at an absolute -70 LUFS, then again
 * relative to the mean of whatever survived the first gate, minus 10 LU. The
 * second threshold moves as more audio arrives, so the set of blocks that
 * counts cannot be maintained incrementally — a block excluded a minute ago may
 * be included now.
 *
 * The obvious fix is to keep every block and re-filter. At 10 blocks a second
 * over Decibel's four-hour ceiling that is 144,000 values, which is affordable
 * to store but not to re-sort at display rate for LRA's percentiles.
 *
 * A histogram indexed by block loudness solves both. Insertion is O(1),
 * re-gating is a scan of a fixed number of bins regardless of programme length,
 * percentiles are a cumulative walk, and memory is constant. The one thing it
 * would normally cost is precision — so each bin stores the *exact* sum of the
 * energies filed into it rather than reconstructing them from the bin centre.
 * Only the gate thresholds and the percentile boundaries are quantised, and at
 * 0.01 LU per bin that is an order of magnitude inside the +/-0.1 LU the
 * conformance suite allows.
 */

#ifndef OAA_LOUDNESS_H
#define OAA_LOUDNESS_H

#include "oaa/oaa.h"
#include "oaa_kweight.h"

#include <stdint.h>

/* 10 ms. The resolution at which momentary and short-term loudness advance.
 *
 * Not 100 ms, which is the gating step and which this was until the official
 * EBU vectors were run against it. Tech 3341 tests 13 and 14 take a 400 ms tone
 * — exactly one momentary window long — and slide it through twenty files in
 * 20 ms steps, requiring Max M within ±0.1 LU every time. On a 100 ms grid a
 * tone offset by anything other than a multiple of 100 ms never lies inside one
 * window whole, so the highest momentary reading available is taken over part
 * tone and part silence: sixteen of those twenty read low, by up to 0.45 LU,
 * and test 14 by 0.70. At 10 ms the error is bounded by half a sub-block out of
 * the window, 5/400 = 0.054 LU, for a transient landing anywhere at all —
 * inside the tolerance by construction rather than by the offsets the EBU
 * happened to pick. */
#define OAA_SUBBLOCK_DIVISOR 100

#define OAA_MOMENTARY_SUBBLOCKS 40  /* 400 ms */
#define OAA_SHORTTERM_SUBBLOCKS 300 /* 3 s */

/* 100 ms, in sub-blocks. The step of both gating windows: the 75% overlap
 * BS.1770 asks of the 400 ms blocks behind integrated loudness, and the rate at
 * which the 3 s blocks behind LRA are filed.
 *
 * It is a separate constant from the sub-block above so that making the
 * momentary reading ten times finer did not also make both distributions ten
 * times denser — which would have moved every percentile in them, and so the
 * LRA of every programme, for no reason anybody asked for. */
#define OAA_GATING_STEP_SUBBLOCKS 10

/* The absolute gate of BS.1770-4, LUFS. A block quieter than this is not
 * programme: it is never filed into the integrated measurement, and the
 * dynamics readings in oaa_analysis.c are undefined below it for the same
 * reason — see the note there. Shared rather than repeated, so that the one
 * threshold that says "there is nothing here to measure" cannot drift into
 * two. */
#define OAA_GATE_ABSOLUTE (-70.0)

/* Histogram span, in LUFS. The low edge is the absolute gate: nothing quieter
 * is ever filed. The high edge is far above any real programme — a block that
 * loud is clipping into a wall — and out-of-range values clamp rather than
 * being dropped, because silently discarding the loudest blocks would drag the
 * integrated reading down. */
#define OAA_HIST_MIN_LUFS OAA_GATE_ABSOLUTE
#define OAA_HIST_MAX_LUFS (10.0)
#define OAA_HIST_STEP 0.01
#define OAA_HIST_BINS 8000

typedef struct {
  uint32_t count;
  double energy_sum;
} oaa_hist_bin;

typedef struct {
  oaa_biquad shelf;
  oaa_biquad highpass;
  oaa_biquad_state shelf_state[OAA_MAX_CHANNELS];
  oaa_biquad_state highpass_state[OAA_MAX_CHANNELS];
  double weight[OAA_MAX_CHANNELS];

  uint32_t channels;
  uint32_t frames_per_subblock;
  uint32_t frames_in_subblock;

  /* Sum of squares of the K-weighted signal in the sub-block being filled. */
  double accumulator[OAA_MAX_CHANNELS];

  /* Completed sub-blocks, as per-channel mean squares.
   *
   * There is deliberately no write cursor beside this. The row a sub-block
   * lands in is `subblocks_done % OAA_SHORTTERM_SUBBLOCKS`, computed where it
   * is used, so an index into this array cannot be wrong however the counter
   * got there. A stored cursor is the same number carried in a second place,
   * and it has to be *trusted* at the point of use: a Phase 8 crash was a
   * cursor of 3,262,164,031 (a float bit pattern, from something outside this
   * file) turning one sub-block boundary into an 8-byte store 229 GB past the
   * engine. Reducing at the point of use costs one modulo per 100 ms and
   * bounds the store by construction. */
  double ring[OAA_SHORTTERM_SUBBLOCKS][OAA_MAX_CHANNELS];
  uint64_t subblocks_done;

  oaa_hist_bin gating[OAA_HIST_BINS];    /* 400 ms blocks -> integrated */
  oaa_hist_bin shortterm[OAA_HIST_BINS]; /* 3 s blocks    -> LRA */
} oaa_loudness;

void oaa_loudness_init(oaa_loudness *l, uint32_t channels, uint32_t sample_rate);

/* Clears the integrators and the histograms. Filter state is preserved — see
 * the note in the implementation. */
void oaa_loudness_reset(oaa_loudness *l);

void oaa_loudness_process(oaa_loudness *l, const float *interleaved,
                          uint32_t frames);

/*
 * Each returns NaN when the measurement is not yet defined — before 400 ms of
 * signal for momentary, before any block clears the absolute gate for
 * integrated. NaN rather than a floor value, because "nothing has been
 * measured" and "something very quiet was measured" are different facts and the
 * UI shows them differently.
 */
double oaa_loudness_momentary(const oaa_loudness *l);
double oaa_loudness_shortterm(const oaa_loudness *l);
double oaa_loudness_integrated(const oaa_loudness *l);
double oaa_loudness_range(const oaa_loudness *l);

/*
 * The two percentiles the range is the difference of, and the relative gate
 * they were taken above. All three are NaN exactly when the range is.
 *
 * These are published because a histogram of the distribution without them is
 * a picture rather than a measurement: the whole question somebody asks of an
 * LRA of 9 LU is *which* 9 LU, and the answer is two lines on that plot.
 */
void oaa_loudness_range_bounds(const oaa_loudness *l, double *low, double *high,
                               double *gate);

/*
 * The gated short-term distribution, resampled onto `count` equal bins between
 * `min_lufs` and `max_lufs`, as fractions of the total that sum to 1.
 *
 * The same population LRA is computed from, deliberately: a plot drawn from a
 * different set of blocks than the number beside it is a plot that will
 * eventually be used to argue the number is wrong. Blocks outside the range
 * clamp into the end bins rather than vanishing, for the same reason the
 * internal histogram clamps — quietly dropping the loudest blocks would make
 * the picture disagree with the reading.
 *
 * Writes zeros when nothing has cleared the gates yet.
 */
void oaa_loudness_distribution(const oaa_loudness *l, float *bins,
                               uint32_t count, double min_lufs,
                               double max_lufs);

#endif /* OAA_LOUDNESS_H */
