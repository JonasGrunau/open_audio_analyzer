/*
 * oaa_truepeak.c — the 4x polyphase oversampler from BS.1770-4 Annex 2.
 *
 * SPDX-License-Identifier: MIT
 */

#include "oaa_truepeak.h"

#include <math.h>
#include <string.h>

/*
 * The interpolation filter, exactly as tabulated in BS.1770-4 Annex 2:
 * 48 taps, presented as four phases of twelve.
 *
 * Phases 2 and 3 are the time-reverses of phases 1 and 0. That is a property of
 * the filter, not a coincidence, but the table is written out in full anyway —
 * deriving two of the phases by reversing the others would save 24 numbers and
 * cost anyone checking this against the standard the ability to read straight
 * down the page.
 */
static const double kPhase[OAA_TRUEPEAK_PHASES][OAA_TRUEPEAK_TAPS] = {
    {0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000,
     -0.0594482421875, 0.1373291015625, 0.9721679687500, -0.1022949218750,
     0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500},
    {-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250,
     -0.1665039062500, 0.4650878906250, 0.7797851562500, -0.2003173828125,
     0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375},
    {-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000,
     -0.2003173828125, 0.7797851562500, 0.4650878906250, -0.1665039062500,
     0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875},
    {-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750,
     -0.1022949218750, 0.9721679687500, 0.1373291015625, -0.0594482421875,
     0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750},
};

void oaa_truepeak_init(oaa_truepeak *tp, uint32_t channels,
                       uint32_t sample_rate) {
  memset(tp, 0, sizeof(*tp));
  tp->channels = channels;
  tp->frames_per_subblock = sample_rate / 10; /* 100 ms */
  if (tp->frames_per_subblock == 0) {
    tp->frames_per_subblock = 1;
  }
}

void oaa_truepeak_reset(oaa_truepeak *tp) {
  /* The delay line is deliberately *not* cleared. It holds the last few
   * milliseconds of real signal, and zeroing it would fabricate a
   * discontinuity that the interpolator would then report as an inter-sample
   * peak — a reset would produce an overshoot that was never in the audio. */
  tp->frames_in_subblock = 0;
  tp->subblock_peak = 0.0;
  tp->history_write = 0;
  tp->history_filled = 0;
  tp->peak_max = 0.0;
  memset(tp->history, 0, sizeof(tp->history));
}

/* Largest magnitude of the four interpolated samples that follow the newest
 * input sample for one channel. */
static double oaa_truepeak_channel(const oaa_truepeak *tp, uint32_t channel) {
  const float *delay = tp->delay[channel];
  double largest = 0.0;

  for (uint32_t phase = 0; phase < OAA_TRUEPEAK_PHASES; phase++) {
    const double *taps = kPhase[phase];
    double sum = 0.0;

    for (uint32_t tap = 0; tap < OAA_TRUEPEAK_TAPS; tap++) {
      /* Walk the delay line backwards from the newest sample, wrapping. */
      const uint32_t index =
          (tp->pos + OAA_TRUEPEAK_TAPS - tap) % OAA_TRUEPEAK_TAPS;
      sum += taps[tap] * (double)delay[index];
    }

    const double magnitude = fabs(sum);
    if (magnitude > largest) {
      largest = magnitude;
    }
  }

  return largest;
}

void oaa_truepeak_process(oaa_truepeak *tp, const float *interleaved,
                          uint32_t frames) {
  const uint32_t channels = tp->channels;

  for (uint32_t frame = 0; frame < frames; frame++) {
    tp->pos = (tp->pos + 1) % OAA_TRUEPEAK_TAPS;

    for (uint32_t channel = 0; channel < channels; channel++) {
      tp->delay[channel][tp->pos] = interleaved[(size_t)frame * channels + channel];

      const double peak = oaa_truepeak_channel(tp, channel);
      if (peak > tp->subblock_peak) {
        tp->subblock_peak = peak;
      }
      if (peak > tp->peak_max) {
        tp->peak_max = peak;
      }
    }

    if (++tp->frames_in_subblock >= tp->frames_per_subblock) {
      tp->history[tp->history_write] = tp->subblock_peak;
      tp->history_write = (tp->history_write + 1) % OAA_TRUEPEAK_HISTORY;
      if (tp->history_filled < OAA_TRUEPEAK_HISTORY) {
        tp->history_filled++;
      }
      tp->frames_in_subblock = 0;
      tp->subblock_peak = 0.0;
    }
  }
}

double oaa_truepeak_windowed(const oaa_truepeak *tp) {
  /* Include the sub-block still being filled, so the reading responds
   * immediately rather than in 100 ms steps. */
  double largest = tp->subblock_peak;
  for (uint32_t i = 0; i < tp->history_filled; i++) {
    if (tp->history[i] > largest) {
      largest = tp->history[i];
    }
  }
  return largest;
}

double oaa_truepeak_max(const oaa_truepeak *tp) { return tp->peak_max; }
