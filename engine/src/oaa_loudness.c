/*
 * oaa_loudness.c — EBU R 128 gating, integration and loudness range.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "oaa_loudness.h"

#include <math.h>
#include <string.h>

/* The offset in BS.1770-4's loudness equation. It is what calibrates the scale
 * so that a stereo 1 kHz sine at -23 dBFS reads exactly -23.0 LUFS: the K
 * filter's +0.691 dB at 1 kHz cancels it. */
#define OAA_LOUDNESS_OFFSET (-0.691)

/* The absolute gate, OAA_GATE_ABSOLUTE, lives in the header: the dynamics
 * readings in oaa_analysis.c are gated on the same line. */

/* Relative gate below the ungated mean, in LU. Integrated loudness uses 10;
 * loudness range uses 20. */
#define OAA_GATE_RELATIVE_INTEGRATED 10.0
#define OAA_GATE_RELATIVE_RANGE 20.0

void oaa_loudness_init(oaa_loudness *l, uint32_t channels,
                       uint32_t sample_rate) {
  memset(l, 0, sizeof(*l));

  l->channels = channels;
  l->frames_per_subblock = sample_rate / OAA_SUBBLOCK_DIVISOR;
  if (l->frames_per_subblock == 0) {
    l->frames_per_subblock = 1;
  }

  oaa_kweight_design((double)sample_rate, &l->shelf, &l->highpass);

  for (uint32_t c = 0; c < channels; c++) {
    l->weight[c] = oaa_channel_weight(c, channels);
  }
}

void oaa_loudness_reset(oaa_loudness *l) {
  /* Filter state is deliberately preserved. The biquads hold the last few
   * samples of real signal; clearing them injects a step that the RLB
   * high-pass rings on for tens of milliseconds, and the first momentary
   * reading after a reset would be that ringing rather than the programme. */
  memset(l->accumulator, 0, sizeof(l->accumulator));
  memset(l->ring, 0, sizeof(l->ring));
  memset(l->gating, 0, sizeof(l->gating));
  memset(l->shortterm, 0, sizeof(l->shortterm));
  l->frames_in_subblock = 0;
  l->subblocks_done = 0;
}

/* --- Scale conversions ---------------------------------------------------- */

static double loudness_from_energy(double energy) {
  if (!(energy > 0.0)) {
    return -HUGE_VAL;
  }
  return OAA_LOUDNESS_OFFSET + 10.0 * log10(energy);
}

static int bin_of_loudness(double loudness) {
  const int bin = (int)floor((loudness - OAA_HIST_MIN_LUFS) / OAA_HIST_STEP);
  if (bin < 0) {
    return -1; /* below the absolute gate; caller drops it */
  }
  return bin >= OAA_HIST_BINS ? OAA_HIST_BINS - 1 : bin;
}

/* The loudness a bin represents, taken at its centre. Used only for LRA's
 * percentile boundaries, where a half-bin bias would otherwise be systematic
 * in one direction. */
static double loudness_of_bin(int bin) {
  return OAA_HIST_MIN_LUFS + ((double)bin + 0.5) * OAA_HIST_STEP;
}

/* --- Windows over the sub-block ring -------------------------------------- */

/*
 * Weighted energy over the most recent `subblocks` sub-blocks, or -1 when
 * fewer than that have been measured.
 *
 * This is the sum over channels of G_i times the mean square of channel i,
 * which is the quantity BS.1770-4 puts inside the logarithm.
 */
static double window_energy(const oaa_loudness *l, uint32_t subblocks) {
  if (l->subblocks_done < subblocks) {
    return -1.0;
  }

  double total = 0.0;
  for (uint32_t c = 0; c < l->channels; c++) {
    if (l->weight[c] == 0.0) {
      continue; /* LFE */
    }
    double sum = 0.0;
    for (uint32_t k = 0; k < subblocks; k++) {
      /* `subblocks_done` is the count of closed sub-blocks, so it is also one
       * past the newest row. The early return above guarantees it exceeds `k`,
       * so the addition cannot wrap. */
      const uint32_t index =
          (uint32_t)((l->subblocks_done + OAA_SHORTTERM_SUBBLOCKS - 1 - k) %
                     OAA_SHORTTERM_SUBBLOCKS);
      sum += l->ring[index][c];
    }
    total += l->weight[c] * (sum / (double)subblocks);
  }
  return total;
}

static void file_block(oaa_hist_bin *histogram, double energy) {
  const double loudness = loudness_from_energy(energy);
  if (!(loudness > OAA_GATE_ABSOLUTE)) {
    return; /* absolute gate, applied once, at insertion */
  }
  const int bin = bin_of_loudness(loudness);
  if (bin < 0) {
    return;
  }
  histogram[bin].count++;
  histogram[bin].energy_sum += energy;
}

/* --- Processing ----------------------------------------------------------- */

static void close_subblock(oaa_loudness *l) {
  const double frames = (double)l->frames_per_subblock;

  /* Reduced here rather than carried in a field — see the ring's note in the
   * header. This is the one place the ring is written, so this modulo is what
   * makes every store into it in range by construction. */
  const uint32_t row =
      (uint32_t)(l->subblocks_done % OAA_SHORTTERM_SUBBLOCKS);

  for (uint32_t c = 0; c < l->channels; c++) {
    l->ring[row][c] = l->accumulator[c] / frames;
    l->accumulator[c] = 0.0;
  }
  l->subblocks_done++;

  /* A 400 ms gating block every 100 ms is the 75% overlap the standard asks
   * for; the same applies to the 3 s blocks LRA is built from. Momentary and
   * short-term move with every sub-block — that is the point of the sub-block
   * being 10 ms — but the two histograms are filed at the coarser step, so both
   * integrating measurements see exactly the blocks they saw when a sub-block
   * was 100 ms long. */
  if (l->subblocks_done % OAA_GATING_STEP_SUBBLOCKS != 0) {
    return;
  }

  const double gating_energy = window_energy(l, OAA_MOMENTARY_SUBBLOCKS);
  if (gating_energy >= 0.0) {
    file_block(l->gating, gating_energy);
  }

  const double shortterm_energy = window_energy(l, OAA_SHORTTERM_SUBBLOCKS);
  if (shortterm_energy >= 0.0) {
    file_block(l->shortterm, shortterm_energy);
  }
}

void oaa_loudness_process(oaa_loudness *l, const float *interleaved,
                          uint32_t frames) {
  const uint32_t channels = l->channels;

  for (uint32_t frame = 0; frame < frames; frame++) {
    for (uint32_t c = 0; c < channels; c++) {
      if (l->weight[c] == 0.0) {
        continue; /* LFE contributes nothing; do not spend filter time on it */
      }

      const double input = (double)interleaved[(size_t)frame * channels + c];
      const double shelved =
          oaa_biquad_process(&l->shelf, &l->shelf_state[c], input);
      const double weighted =
          oaa_biquad_process(&l->highpass, &l->highpass_state[c], shelved);

      l->accumulator[c] += weighted * weighted;
    }

    if (++l->frames_in_subblock >= l->frames_per_subblock) {
      l->frames_in_subblock = 0;
      close_subblock(l);
    }
  }
}

/* --- Readings ------------------------------------------------------------- */

double oaa_loudness_momentary(const oaa_loudness *l) {
  const double energy = window_energy(l, OAA_MOMENTARY_SUBBLOCKS);
  if (energy < 0.0) {
    return NAN;
  }
  const double loudness = loudness_from_energy(energy);
  return loudness == -HUGE_VAL ? (double)OAA_DB_FLOOR : loudness;
}

double oaa_loudness_shortterm(const oaa_loudness *l) {
  const double energy = window_energy(l, OAA_SHORTTERM_SUBBLOCKS);
  if (energy < 0.0) {
    return NAN;
  }
  const double loudness = loudness_from_energy(energy);
  return loudness == -HUGE_VAL ? (double)OAA_DB_FLOOR : loudness;
}

/* Mean energy of every block at or above `from_bin`. */
static double gated_mean(const oaa_hist_bin *histogram, int from_bin,
                         uint64_t *count_out) {
  double energy = 0.0;
  uint64_t count = 0;

  for (int bin = from_bin < 0 ? 0 : from_bin; bin < OAA_HIST_BINS; bin++) {
    energy += histogram[bin].energy_sum;
    count += histogram[bin].count;
  }

  *count_out = count;
  return count == 0 ? 0.0 : energy / (double)count;
}

double oaa_loudness_integrated(const oaa_loudness *l) {
  /* Everything in the histogram already cleared the absolute gate. */
  uint64_t count = 0;
  const double ungated_mean = gated_mean(l->gating, 0, &count);
  if (count == 0) {
    return NAN;
  }

  const double relative =
      loudness_from_energy(ungated_mean) - OAA_GATE_RELATIVE_INTEGRATED;

  const double gated =
      gated_mean(l->gating, bin_of_loudness(relative), &count);
  if (count == 0) {
    /* The relative gate excluded everything, which happens only for a
     * programme shorter than one gating block above the absolute gate. */
    return NAN;
  }
  return loudness_from_energy(gated);
}

/* The first bin of the relative-gated short-term distribution, and the number
 * of blocks in it. Returns -1 when nothing has cleared the gates. */
static int range_gate_start(const oaa_loudness *l, uint64_t *total_out,
                            double *gate_out) {
  uint64_t count = 0;
  const double ungated_mean = gated_mean(l->shortterm, 0, &count);
  if (count == 0) {
    return -1;
  }

  const double relative =
      loudness_from_energy(ungated_mean) - OAA_GATE_RELATIVE_RANGE;
  const int first_bin = bin_of_loudness(relative);
  const int start = first_bin < 0 ? 0 : first_bin;

  uint64_t total = 0;
  for (int bin = start; bin < OAA_HIST_BINS; bin++) {
    total += l->shortterm[bin].count;
  }
  if (total == 0) {
    return -1;
  }

  if (gate_out != NULL) {
    *gate_out = relative;
  }
  *total_out = total;
  return start;
}

void oaa_loudness_range_bounds(const oaa_loudness *l, double *low, double *high,
                               double *gate) {
  *low = NAN;
  *high = NAN;
  *gate = NAN;

  uint64_t total = 0;
  double relative = NAN;
  const int start = range_gate_start(l, &total, &relative);
  if (start < 0) {
    return;
  }

  /* EBU Tech 3342: the range is the 10th to the 95th percentile of what
   * survives both gates. */
  const uint64_t low_rank = (uint64_t)(((double)total - 1.0) * 0.10 + 0.5);
  const uint64_t high_rank = (uint64_t)(((double)total - 1.0) * 0.95 + 0.5);

  int low_bin = start;
  int high_bin = start;
  uint64_t cumulative = 0;
  int found_low = 0;

  for (int bin = start; bin < OAA_HIST_BINS; bin++) {
    const uint32_t bin_count = l->shortterm[bin].count;
    if (bin_count == 0) {
      continue;
    }
    const uint64_t next = cumulative + bin_count;

    if (!found_low && next > low_rank) {
      low_bin = bin;
      found_low = 1;
    }
    if (next > high_rank) {
      high_bin = bin;
      break;
    }
    cumulative = next;
  }

  *low = loudness_of_bin(low_bin);
  *high = loudness_of_bin(high_bin);
  *gate = relative;
}

double oaa_loudness_range(const oaa_loudness *l) {
  double low = NAN, high = NAN, gate = NAN;
  oaa_loudness_range_bounds(l, &low, &high, &gate);
  if (isnan(low) || isnan(high)) {
    return NAN;
  }
  const double range = high - low;
  return range < 0.0 ? 0.0 : range;
}

void oaa_loudness_distribution(const oaa_loudness *l, float *bins,
                               uint32_t count, double min_lufs,
                               double max_lufs) {
  for (uint32_t i = 0; i < count; i++) {
    bins[i] = 0.0f;
  }
  if (count == 0 || !(max_lufs > min_lufs)) {
    return;
  }

  uint64_t total = 0;
  const int start = range_gate_start(l, &total, NULL);
  if (start < 0) {
    return;
  }

  const double span = max_lufs - min_lufs;
  const double inverse_total = 1.0 / (double)total;

  for (int bin = start; bin < OAA_HIST_BINS; bin++) {
    const uint32_t bin_count = l->shortterm[bin].count;
    if (bin_count == 0) {
      continue;
    }
    const double loudness = loudness_of_bin(bin);

    double position = (loudness - min_lufs) / span * (double)count;
    if (position < 0.0) {
      position = 0.0;
    }
    uint32_t index = (uint32_t)position;
    if (index >= count) {
      index = count - 1;
    }

    bins[index] += (float)((double)bin_count * inverse_total);
  }
}
