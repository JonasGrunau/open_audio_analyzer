/*
 * bel_analysis.c — the meters that exist in Phase 0.
 *
 * SPDX-License-Identifier: MIT
 *
 * What is here is only what can be computed correctly from a block of samples
 * with no filter design and no FFT: sample peak with hold, RMS with decay, a
 * VU deflection, clip detection, inter-channel correlation and stereo balance.
 *
 * What is deliberately *not* here is every loudness quantity. K-weighting,
 * R128 gating, LRA and true-peak oversampling land in Phase 1 together with the
 * EBU conformance suite that proves them, and not one release earlier. A
 * loudness meter that has never been run against the reference vectors is a
 * number generator, and shipping one would undermine the only thing this
 * project actually has to be good at. Until then those fields are NaN and
 * BEL_FLAG_LOUDNESS_UNAVAILABLE is set, so the UI renders a dash rather than
 * inventing a reading.
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

void bel_analyse_block(bel_engine *engine, uint32_t frames) {
  if (frames == 0) {
    return;
  }

  const uint32_t channels = engine->cfg.channels;
  const float *in = engine->block;
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
    /* Pearson correlation over the block. A proper sliding window with running
     * sums replaces this in Phase 1; per block plus smoothing is honest at
     * this block size and costs nothing to read. */
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

  /* --- Not measured yet -------------------------------------------------- */
  out->lufs_momentary = NAN;
  out->lufs_short = NAN;
  out->lufs_integrated = NAN;
  out->lra = NAN;
  out->true_peak = NAN;
  out->true_peak_max = NAN;
  out->dr_short = NAN;
  out->dr_integrated = NAN;
  out->plr = NAN;
  out->psr = NAN;

  /* --- Housekeeping ------------------------------------------------------ */
  engine->frames_done += frames;
  out->elapsed_seconds =
      (double)engine->frames_done / (double)engine->cfg.sample_rate;
  out->sample_rate = engine->cfg.sample_rate;
  out->channels = channels;
  out->flags = BEL_FLAG_RUNNING | BEL_FLAG_LOUDNESS_UNAVAILABLE |
               BEL_FLAG_SPECTRUM_UNAVAILABLE;
}
