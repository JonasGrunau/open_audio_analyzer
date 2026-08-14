/*
 * bel_loudness.h — EBU R 128 loudness over the BS.1770-4 K-weighting.
 *
 * SPDX-License-Identifier: MIT
 *
 * Everything is built from one primitive: the mean square of the K-weighted
 * signal over a 100 ms sub-block. Every published quantity is a window of those
 * sub-blocks, which is what makes the momentary, short-term and integrated
 * readings provably consistent with each other — they are literally different
 * lengths of the same ring.
 *
 *   Momentary   last 4 sub-blocks   (400 ms)
 *   Short-term  last 30 sub-blocks  (3 s)
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

#ifndef BEL_LOUDNESS_H
#define BEL_LOUDNESS_H

#include "bel/bel.h"
#include "bel_kweight.h"

#include <stdint.h>

/* 100 ms. The step of every gating window, and the resolution at which
 * momentary and short-term advance. */
#define BEL_SUBBLOCK_DIVISOR 10

#define BEL_MOMENTARY_SUBBLOCKS 4  /* 400 ms */
#define BEL_SHORTTERM_SUBBLOCKS 30 /* 3 s */

/* Histogram span, in LUFS. The low edge is the absolute gate: nothing quieter
 * is ever filed. The high edge is far above any real programme — a block that
 * loud is clipping into a wall — and out-of-range values clamp rather than
 * being dropped, because silently discarding the loudest blocks would drag the
 * integrated reading down. */
#define BEL_HIST_MIN_LUFS (-70.0)
#define BEL_HIST_MAX_LUFS (10.0)
#define BEL_HIST_STEP 0.01
#define BEL_HIST_BINS 8000

typedef struct {
  uint32_t count;
  double energy_sum;
} bel_hist_bin;

typedef struct {
  bel_biquad shelf;
  bel_biquad highpass;
  bel_biquad_state shelf_state[BEL_MAX_CHANNELS];
  bel_biquad_state highpass_state[BEL_MAX_CHANNELS];
  double weight[BEL_MAX_CHANNELS];

  uint32_t channels;
  uint32_t frames_per_subblock;
  uint32_t frames_in_subblock;

  /* Sum of squares of the K-weighted signal in the sub-block being filled. */
  double accumulator[BEL_MAX_CHANNELS];

  /* Completed sub-blocks, as per-channel mean squares. */
  double ring[BEL_SHORTTERM_SUBBLOCKS][BEL_MAX_CHANNELS];
  uint32_t ring_write;
  uint64_t subblocks_done;

  bel_hist_bin gating[BEL_HIST_BINS];    /* 400 ms blocks -> integrated */
  bel_hist_bin shortterm[BEL_HIST_BINS]; /* 3 s blocks    -> LRA */
} bel_loudness;

void bel_loudness_init(bel_loudness *l, uint32_t channels, uint32_t sample_rate);

/* Clears the integrators and the histograms. Filter state is preserved — see
 * the note in the implementation. */
void bel_loudness_reset(bel_loudness *l);

void bel_loudness_process(bel_loudness *l, const float *interleaved,
                          uint32_t frames);

/*
 * Each returns NaN when the measurement is not yet defined — before 400 ms of
 * signal for momentary, before any block clears the absolute gate for
 * integrated. NaN rather than a floor value, because "nothing has been
 * measured" and "something very quiet was measured" are different facts and the
 * UI shows them differently.
 */
double bel_loudness_momentary(const bel_loudness *l);
double bel_loudness_shortterm(const bel_loudness *l);
double bel_loudness_integrated(const bel_loudness *l);
double bel_loudness_range(const bel_loudness *l);

#endif /* BEL_LOUDNESS_H */
