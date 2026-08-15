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
 * The spectrum is driven from here too but computed in `bel_spectrum`, on its
 * own window and its own hop — a 4096-point transform has nothing to do with
 * however many frames a device happens to hand us.
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
 * VU ballistics.
 *
 * A VU meter is defined by its mechanism, not by a formula, and two properties
 * of that mechanism are what make it read differently from an RMS meter — which
 * is the entire reason anybody still uses one.
 *
 * **It is average-responding, RMS-calibrated.** The movement follows the mean
 * of the rectified signal, and the scale is then calibrated so that a sine
 * reads its RMS. The ratio between those two is pi/(2*sqrt(2)) for a sine and
 * something else for everything else, so a VU sits progressively lower than an
 * RMS meter as material gets peakier. A limited master and an unlimited one at
 * the same RMS read differently here, and that difference is the measurement.
 *
 * **It is second order.** The needle reaches 99% of a step in 300 ms with
 * 1 to 1.5% overshoot; the overshoot is why a VU appears to lean into
 * transients. A one-pole smoother hits the same 300 ms with no overshoot at
 * all, which is right on the number and wrong on the behaviour.
 *
 * zeta = 0.81 gives about 1.2% overshoot, inside the tolerance the standard
 * allows, and omega then follows from wanting the first crossing of 99% at
 * 300 ms: solving the step response for that gives omega*t = 4.03.
 */
#define BEL_VU_OMEGA 13.43f /* rad/s, = 4.03 / 0.300 s */
#define BEL_VU_ZETA 0.81f
#define BEL_VU_RMS_CALIBRATION 1.11072073454f /* pi / (2 * sqrt(2)) */

/* Forward Euler on a lightly damped oscillator gains energy when the step is
 * large, so the integration is subdivided until it cannot. At a 21 ms block
 * this is six substeps of arithmetic on two floats — cheaper than the log10
 * that formats the result. */
#define BEL_VU_MAX_STEP 0.05f /* omega * dt */

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

/*
 * Advance the needle towards `target` over `dt` seconds.
 *
 * Semi-implicit Euler — velocity first, then position from the *new* velocity.
 * Plain forward Euler on an oscillator adds a little energy every step, and at
 * zeta = 0.81 it takes a long time for that to look like anything other than
 * a meter that reads slightly high.
 */
static void bel_vu_advance(bel_channel_state *state, float target, float dt) {
  int steps = (int)(BEL_VU_OMEGA * dt / BEL_VU_MAX_STEP) + 1;
  if (steps > 64) {
    steps = 64; /* An absurd block size, but not a reason to spin. */
  }
  const float step = dt / (float)steps;

  for (int i = 0; i < steps; i++) {
    const float acceleration =
        BEL_VU_OMEGA * BEL_VU_OMEGA * (target - state->vu_position) -
        2.0f * BEL_VU_ZETA * BEL_VU_OMEGA * state->vu_velocity;
    state->vu_velocity += acceleration * step;
    state->vu_position += state->vu_velocity * step;
  }

  /* A needle does not go below its rest position. Without this the overshoot
   * on a decay swings the deflection negative, and the dB conversion turns
   * that into a floor reading that flickers. */
  if (state->vu_position < 0.0f) {
    state->vu_position = 0.0f;
    state->vu_velocity = 0.0f;
  }
}

/*
 * The most recent BEL_SCOPE_POINTS stereo frames, oldest first.
 *
 * Written as a sliding window over the published array rather than through a
 * ring with a rotation at publish time. It costs one memmove of 8 kB per block
 * and removes the class of bug where the scope draws the right samples in the
 * wrong order — which looks like a plausible Lissajous figure of a completely
 * different signal.
 */
static void bel_scope_append(bel_snapshot *out, const float *interleaved,
                             uint32_t frames, uint32_t channels) {
  const uint32_t taken =
      frames < BEL_SCOPE_POINTS ? frames : (uint32_t)BEL_SCOPE_POINTS;
  const uint32_t kept = (uint32_t)BEL_SCOPE_POINTS - taken;

  if (kept > 0) {
    memmove(out->scope, &out->scope[taken * 2], (size_t)kept * 2 * sizeof(float));
  }

  const uint32_t first = frames - taken;
  const uint32_t right = channels >= 2 ? 1 : 0;

  for (uint32_t i = 0; i < taken; i++) {
    const float *frame = &interleaved[(size_t)(first + i) * channels];
    out->scope[(kept + i) * 2] = frame[0];
    out->scope[(kept + i) * 2 + 1] = frame[right];
  }
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
  bel_spectrum_process(&engine->spectrum, in, frames);

  const float dt = (float)frames / (float)engine->cfg.sample_rate;

  const float rms_coefficient = bel_smoothing(dt, BEL_RMS_TAU_SECONDS);
  const float correlation_coefficient =
      bel_smoothing(dt, BEL_CORRELATION_TAU_SECONDS);

  bel_snapshot *out = &engine->staging;

  double energy[BEL_MAX_CHANNELS] = {0};
  double rectified[BEL_MAX_CHANNELS] = {0};
  double sum_lr = 0.0, sum_ll = 0.0, sum_rr = 0.0;

  for (uint32_t i = 0; i < frames; i++) {
    const float *frame = &in[(size_t)i * channels];

    for (uint32_t c = 0; c < channels; c++) {
      const float sample = frame[c];
      const float magnitude = fabsf(sample);
      bel_channel_state *state = &engine->channel[c];

      energy[c] += (double)sample * (double)sample;
      rectified[c] += magnitude;

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

    /* Smoothed in the mean-square domain, so a silent block decays it rather
     * than snapping it to the floor. */
    state->rms_mean_square = state->rms_mean_square * rms_coefficient +
                             mean_square * (1.0f - rms_coefficient);

    bel_vu_advance(state,
                   (float)(rectified[c] / (double)frames) *
                       BEL_VU_RMS_CALIBRATION,
                   dt);

    out->peak[c] = bel_db_from_linear(state->peak_linear);
    out->rms[c] = bel_db_from_linear(sqrtf(state->rms_mean_square));
    out->vu[c] = bel_db_from_linear(state->vu_position);
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

  double lra_low = NAN, lra_high = NAN, lra_gate = NAN;
  bel_loudness_range_bounds(&engine->loudness, &lra_low, &lra_high, &lra_gate);
  out->lra_low = (float)lra_low;
  out->lra_high = (float)lra_high;
  out->lra_gate = (float)lra_gate;

  bel_loudness_distribution(&engine->loudness, out->histogram,
                            BEL_HISTOGRAM_BINS, BEL_HISTOGRAM_MIN_LUFS,
                            BEL_HISTOGRAM_MAX_LUFS);

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

  /* --- Frequency content and the scope ------------------------------------ */
  bel_spectrum_read(&engine->spectrum, out->spectrum, out->spectrum_peak,
                    out->spectrum_pan);
  bel_scope_append(out, in, frames, channels);

  /* --- Housekeeping ------------------------------------------------------ */
  engine->frames_done += frames;
  out->elapsed_seconds =
      (double)engine->frames_done / (double)engine->cfg.sample_rate;
  out->sample_rate = engine->cfg.sample_rate;
  out->channels = channels;
  /* OR rather than assign: BEL_FLAG_OVERRUN is sticky until a reset, and the
   * analysis pass runs many times a second. Assigning here would erase the
   * warning a moment after it appeared. */
  out->flags |= BEL_FLAG_RUNNING;
  out->flags &= ~(uint32_t)BEL_FLAG_LOUDNESS_UNAVAILABLE;

  /* The bands stay unavailable until a full window has been transformed —
   * 4096 frames, about 85 ms. Until then they sit at the floor, which is
   * indistinguishable from digital silence unless somebody says so. */
  if (engine->spectrum.ready) {
    out->flags &= ~(uint32_t)BEL_FLAG_SPECTRUM_UNAVAILABLE;
  }
}
