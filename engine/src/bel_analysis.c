/*
 * bel_analysis.c — one pass over a block, driving every meter.
 *
 * SPDX-License-Identifier: MIT
 *
 * This file owns the meters that are only a few lines of arithmetic — sample
 * peak with hold, RMS with decay, a VU deflection, clip detection,
 * inter-channel correlation and stereo balance — and it *drives* the two that
 * are not: `bel_loudness` and `bel_truepeak`, each of which lives in its own
 * file next to the standard it implements.
 *
 * The dynamics figures at the bottom are where the two halves meet. They are
 * differences of a peak and a loudness, so they only become defined once both
 * of their operands are, and each one propagates NaN rather than substituting a
 * floor. That is deliberate: DR-I is meaningless before there is an integrated
 * loudness to subtract from, and a plausible-looking number there would be
 * worse than a dash.
 *
 * Still not measured here: the spectrum. Those bands stay at the floor behind
 * BEL_FLAG_SPECTRUM_UNAVAILABLE until the FFT lands with the analyser module
 * that draws it.
 */

#include "bel_internal.h"

#include <math.h>
#include <string.h>

/* --- Ballistics ---------------------------------------------------------- */

/* How long a peak is held at its maximum before it starts to fall, and how
 * fast it falls once it does. These are the conventional digital-PPM values;
 * Phase 3 makes them per-module options, as Decibel does. */
#define BEL_PEAK_HOLD_SECONDS 1.5f
#define BEL_PEAK_FALL_DB_PER_SECOND 20.0f

/* Time constant of the RMS averager, applied in the mean-square domain. */
#define BEL_RMS_TAU_SECONDS 0.300f

/*
 * VU ballistics, approximately.
 *
 * The standard specifies a needle that reaches 99% of a step in 300 ms with
 * under 1% overshoot — that is a second-order system, and the overshoot is
 * most of what makes a VU meter feel like a VU meter. This one-pole reaches
 * the same 99% in the same 300 ms and has no overshoot at all, so it is close
 * on the numbers and wrong on the feel.
 *
 * That is an acceptable trade for Phase 0, where nothing draws a needle yet.
 * The real second-order model ships with the VU module in Phase 3. Do not
 * quietly promote this one to "good enough" in the meantime.
 */
#define BEL_VU_TAU_SECONDS (0.300f / 4.60517f) /* 0.3 s / ln(100) */

/* Correlation is smoothed rather than shown per block, or it would be a
 * flickering mess at 10 Hz. */
#define BEL_CORRELATION_TAU_SECONDS 0.200f

/* A sample at or above this magnitude counts towards a clip run. Full scale is
 * 1.0; float sources can and do exceed it, which is itself worth flagging. */
#define BEL_CLIP_THRESHOLD 0.999f

/* --- Helpers ------------------------------------------------------------- */

static float bel_db_from_linear(float linear) {
  if (linear <= 0.0f) {
    return BEL_DB_FLOOR;
  }
  const float db = 20.0f * log10f(linear);
  return db < BEL_DB_FLOOR ? BEL_DB_FLOOR : db;
}

/* One-pole smoothing coefficient for a block of `dt` seconds. Computed per
 * block rather than cached because the block size is allowed to vary once a
 * real capture device is driving this. */
static float bel_smoothing(float dt, float tau) {
  if (tau <= 0.0f) {
    return 0.0f;
  }
  return expf(-dt / tau);
}

/* --- The pass ------------------------------------------------------------ */

void bel_analyse(bel_engine *engine, const float *interleaved,
                 uint32_t frames) {
  if (frames == 0) {
    return;
  }

  const uint32_t channels = engine->cfg.channels;
  const float *in = interleaved;

  /* The two standards-defined measurements run over the whole buffer first.
   * Both keep their own sub-block cadence internally, because a 400 ms gating
   * window has nothing to do with however many frames a device happens to hand
   * us. */
  bel_loudness_process(&engine->loudness, in, frames);
  bel_truepeak_process(&engine->truepeak, in, frames);

  const float dt = (float)frames / (float)engine->cfg.sample_rate;

  const float rms_coefficient = bel_smoothing(dt, BEL_RMS_TAU_SECONDS);
  const float vu_coefficient = bel_smoothing(dt, BEL_VU_TAU_SECONDS);
  const float correlation_coefficient =
      bel_smoothing(dt, BEL_CORRELATION_TAU_SECONDS);

  bel_snapshot *out = &engine->staging;

  double energy[BEL_MAX_CHANNELS] = {0};
  double sum_lr = 0.0, sum_ll = 0.0, sum_rr = 0.0;

  for (uint32_t i = 0; i < frames; i++) {
    const float *frame = &in[(size_t)i * channels];

    for (uint32_t c = 0; c < channels; c++) {
      const float sample = frame[c];
      const float magnitude = fabsf(sample);
      bel_channel_state *state = &engine->channel[c];

      energy[c] += (double)sample * (double)sample;

      if (magnitude > state->peak_linear) {
        state->peak_linear = magnitude;
        state->peak_hold_left = BEL_PEAK_HOLD_SECONDS;
      }

      if (magnitude >= BEL_CLIP_THRESHOLD) {
        state->clip_run++;
      } else {
        state->clip_run = 0;
      }

      if (magnitude > engine->sample_peak_max_linear) {
        engine->sample_peak_max_linear = magnitude;
      }
    }

    if (channels >= 2) {
      const double l = frame[0];
      const double r = frame[1];
      sum_lr += l * r;
      sum_ll += l * l;
      sum_rr += r * r;
    }
  }

  /* --- Per channel ------------------------------------------------------ */
  for (uint32_t c = 0; c < channels; c++) {
    bel_channel_state *state = &engine->channel[c];
    const float mean_square = (float)(energy[c] / (double)frames);

    /* Peak: hold at the maximum, then fall at a fixed dB rate. Working in the
     * linear domain means the fall is a multiply, not an exp/log round trip. */
    if (state->peak_hold_left > 0.0f) {
      state->peak_hold_left -= dt;
    } else {
      state->peak_linear *= powf(10.0f, -BEL_PEAK_FALL_DB_PER_SECOND * dt / 20.0f);
    }

    /* RMS and VU both smooth mean square, so a silent block decays them rather
     * than snapping them to the floor. */
    state->rms_mean_square = state->rms_mean_square * rms_coefficient +
                             mean_square * (1.0f - rms_coefficient);
    state->vu_value = state->vu_value * vu_coefficient +
                      mean_square * (1.0f - vu_coefficient);

    out->peak[c] = bel_db_from_linear(state->peak_linear);
    out->rms[c] = bel_db_from_linear(sqrtf(state->rms_mean_square));
    out->vu[c] = bel_db_from_linear(sqrtf(state->vu_value));
    out->clip[c] = state->clip_run;
  }

  for (uint32_t c = channels; c < BEL_MAX_CHANNELS; c++) {
    out->peak[c] = BEL_DB_FLOOR;
    out->rms[c] = BEL_DB_FLOOR;
    out->vu[c] = BEL_DB_FLOOR;
    out->clip[c] = 0;
  }

  /* --- Programme-wide --------------------------------------------------- */
  out->sample_peak_max = bel_db_from_linear(engine->sample_peak_max_linear);

  float loudest_peak = BEL_DB_FLOOR;
  float loudest_rms = BEL_DB_FLOOR;
  for (uint32_t c = 0; c < channels; c++) {
    if (out->peak[c] > loudest_peak) {
      loudest_peak = out->peak[c];
    }
    if (out->rms[c] > loudest_rms) {
      loudest_rms = out->rms[c];
    }
  }
  out->crest = loudest_peak - loudest_rms;

  /* --- Stereo field ----------------------------------------------------- */
  if (channels >= 2) {
    /* Pearson correlation over the block, then smoothed. A true sliding window
     * with running sums would be more faithful at very short block sizes; at
     * the sizes a real device delivers, this and the 200 ms smoother are
     * indistinguishable on screen. */
    const double denominator = sqrt(sum_ll * sum_rr);
    const float block_correlation =
        denominator > 1e-20 ? (float)(sum_lr / denominator) : 0.0f;

    out->correlation = out->correlation * correlation_coefficient +
                       block_correlation * (1.0f - correlation_coefficient);

    const double total = sum_ll + sum_rr;
    out->balance = total > 1e-20 ? (float)((sum_rr - sum_ll) / total) : 0.0f;
  } else {
    /* Mono is perfectly correlated with itself and dead centre. Saying so is
     * more useful than reporting nothing. */
    out->correlation = 1.0f;
    out->balance = 0.0f;
  }

  /* --- Loudness and true peak -------------------------------------------- */
  out->lufs_momentary = (float)bel_loudness_momentary(&engine->loudness);
  out->lufs_short = (float)bel_loudness_shortterm(&engine->loudness);
  out->lufs_integrated = (float)bel_loudness_integrated(&engine->loudness);
  out->lra = (float)bel_loudness_range(&engine->loudness);

  out->true_peak = bel_db_from_linear(
      (float)bel_truepeak_windowed(&engine->truepeak));
  out->true_peak_max =
      bel_db_from_linear((float)bel_truepeak_max(&engine->truepeak));

  /* --- Dynamics ----------------------------------------------------------- */
  /* Differences of the above, so undefined whenever either operand is. The
   * arithmetic propagates NaN on its own; the point of writing it out is that
   * nobody later "fixes" a dash by clamping one of these to zero. See
   * docs/METRICS.md for the definitions — none of these is Decibel's TrueDyn,
   * and none of them pretends to be. */
  out->dr_short = out->true_peak - out->lufs_short;
  out->dr_integrated = out->true_peak_max - out->lufs_integrated;
  out->plr = out->true_peak_max - out->lufs_integrated;
  out->psr = out->true_peak - out->lufs_short;

  /* --- Housekeeping ------------------------------------------------------ */
  engine->frames_done += frames;
  out->elapsed_seconds =
      (double)engine->frames_done / (double)engine->cfg.sample_rate;
  out->sample_rate = engine->cfg.sample_rate;
  out->channels = channels;
  /* OR rather than assign: BEL_FLAG_OVERRUN is sticky until a reset, and the
   * analysis pass runs many times a second. Assigning here would erase the
   * warning a moment after it appeared. */
  out->flags |= BEL_FLAG_RUNNING | BEL_FLAG_SPECTRUM_UNAVAILABLE;
  out->flags &= ~(uint32_t)BEL_FLAG_LOUDNESS_UNAVAILABLE;
}
