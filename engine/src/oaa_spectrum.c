/*
 * oaa_spectrum.c — short-time Fourier analysis. See oaa_spectrum.h for why the
 * window, the hop and the band mapping are what they are.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "oaa_spectrum.h"

#include "pffft.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Declared rather than taken from math.h, as elsewhere in the engine: M_PI is
 * POSIX, not ISO C, and `-std=c11` hides it on glibc and needs a macro defined
 * before the include on MSVC. */
#define OAA_PI 3.14159265358979323846

/* Amplitude of a full-scale sine, given the peak bin of a Hann-windowed
 * transform. The window sums to N/2 and a real sine splits its energy between
 * the positive and negative frequency, so the peak bin holds A*N/4.
 *
 * N here is the *window*, not the transform. Zero padding adds no energy, so
 * it cannot change what a tone reads — scaling by the padded length instead
 * would put the whole display 12 dB low. */
#define OAA_FFT_AMPLITUDE_SCALE (4.0f / (float)OAA_FFT_WINDOW)

/* Below this a band is reported at the floor rather than as a very negative
 * number, so that digital silence does not produce -300 dB noise on screen. */
#define OAA_SPECTRUM_POWER_FLOOR 1e-15f

static float oaa_db_from_power(float power) {
  if (power <= OAA_SPECTRUM_POWER_FLOOR) {
    return OAA_DB_FLOOR;
  }
  const float db = 10.0f * log10f(power);
  return db < OAA_DB_FLOOR ? OAA_DB_FLOOR : db;
}

/* --- Band mapping --------------------------------------------------------- */

/*
 * Which transform bins each log-spaced display band covers.
 *
 * Two regimes, and which one a band is in depends only on its width against
 * the bin spacing.
 *
 * A band wide enough to contain bins takes the loudest of them — see
 * "Peak-per-bin" in the header. Above about 216 Hz at 48 kHz, that is every
 * band.
 *
 * Below that a band contains no bin at all. The bottom octave is 51 of the 512
 * bands spread over 20 Hz, and no transform anybody would run in real time
 * puts a bin every 0.4 Hz. Rounding each of those bands to its nearest bin is
 * what drew the bass as a staircase: fifty-one bands, eight values, six-band
 * treads wide enough to count on screen.
 *
 * So they read *between* the bins instead. That is not the same thing as
 * inventing detail, and the distinction is the whole reason this is allowed:
 * the bins are not independent measurements with unknown territory between
 * them, they are samples of one continuous function — the transform of the
 * windowed frame — taken every 2.93 Hz across a main lobe 11.7 Hz wide. Four
 * samples per lobe is dense enough that a straight line between two of them
 * is within about a tenth of a decibel of the curve it is cutting. The band
 * gets the value the transform actually has at its centre frequency.
 *
 * What this does *not* do is resolve anything the window could not. Two bass
 * notes 8 Hz apart still merge into one hump; the hump is now drawn as a hump
 * rather than as a row of bricks, which is the honest picture of an 11.7 Hz
 * window and was always what the display was trying to say.
 */
static void oaa_spectrum_map_bands(oaa_spectrum *s) {
  const double nyquist_bin = (double)OAA_FFT_BINS - 1.0;
  const double bins_per_hz = (double)OAA_FFT_TRANSFORM / (double)s->sample_rate;
  const double ratio =
      (double)OAA_SPECTRUM_HZ_HIGH / (double)OAA_SPECTRUM_HZ_LOW;

  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    const double low = (double)OAA_SPECTRUM_HZ_LOW *
                       pow(ratio, (double)b / (double)OAA_SPECTRUM_BANDS);
    const double high = (double)OAA_SPECTRUM_HZ_LOW *
                        pow(ratio, (double)(b + 1) / (double)OAA_SPECTRUM_BANDS);

    long first = (long)ceil(low * bins_per_hz);
    long last = (long)floor(high * bins_per_hz);

    if (first < 1) {
      first = 1; /* Bin 0 is DC, which is not a frequency anybody plots. */
    }
    if ((double)first > nyquist_bin) {
      /* Above Nyquist. Nothing was measured here and nothing is drawn. */
      s->band_first[b] = 0;
      s->band_last[b] = 0;
      s->band_lerp[b] = -1.0f;
      continue;
    }
    if ((double)last > nyquist_bin) {
      last = (long)nyquist_bin;
    }

    if (last < first) {
      /* Narrower than a bin: read the transform at the band's centre, which
       * falls between two of its samples. Clamped so that `first + 1` is
       * always a bin that exists — at the very bottom and the very top of the
       * range the pair is the nearest one rather than the straddling one, and
       * a hair of extrapolation there beats reading off the end. */
      const double centre = sqrt(low * high) * bins_per_hz;
      double base = floor(centre);
      if (base < 1.0) {
        base = 1.0;
      }
      if (base > nyquist_bin - 1.0) {
        base = nyquist_bin - 1.0;
      }
      s->band_first[b] = (uint16_t)base;
      s->band_last[b] = (uint16_t)base;
      s->band_lerp[b] = (float)(centre - base);
      continue;
    }

    s->band_first[b] = (uint16_t)first;
    s->band_last[b] = (uint16_t)last;
    s->band_lerp[b] = -1.0f;
  }
}

/* --- Lifecycle ------------------------------------------------------------ */

int oaa_spectrum_init(oaa_spectrum *s, uint32_t channels,
                      uint32_t sample_rate) {
  memset(s, 0, sizeof(*s));

  if (channels == 0 || channels > OAA_MAX_CHANNELS || sample_rate == 0) {
    return 0;
  }

  s->channels = channels;
  s->sample_rate = sample_rate;

  s->setup = pffft_new_setup(OAA_FFT_TRANSFORM, PFFFT_REAL);
  s->window = (float *)calloc(OAA_FFT_WINDOW, sizeof(float));
  s->input = (float *)calloc((size_t)channels * OAA_FFT_WINDOW, sizeof(float));
  s->power = (float *)calloc((size_t)channels * OAA_FFT_BINS, sizeof(float));
  if (channels >= 2) {
    s->power_mid = (float *)calloc(OAA_FFT_BINS, sizeof(float));
    s->power_side = (float *)calloc(OAA_FFT_BINS, sizeof(float));
  }

  s->frame = (float *)pffft_aligned_malloc(OAA_FFT_TRANSFORM * sizeof(float));
  s->work = (float *)pffft_aligned_malloc(OAA_FFT_TRANSFORM * sizeof(float));
  s->coefficients =
      (float *)pffft_aligned_malloc(OAA_FFT_TRANSFORM * sizeof(float));

  if (s->setup == NULL || s->window == NULL || s->input == NULL ||
      s->power == NULL || s->frame == NULL || s->work == NULL ||
      s->coefficients == NULL ||
      (channels >= 2 && (s->power_mid == NULL || s->power_side == NULL))) {
    oaa_spectrum_free(s);
    return 0;
  }

  /* The padding, written once. Every transform overwrites the first
   * OAA_FFT_WINDOW samples and nothing ever touches the rest — pffft takes its
   * input as const, so the zeros survive. Missing this reads whatever the
   * allocator handed back as three quarters of the signal. */
  memset(s->frame, 0, OAA_FFT_TRANSFORM * sizeof(float));

  /* Periodic Hann rather than symmetric: the window is applied to successive
   * overlapping frames of a continuous signal, not to one isolated record, and
   * the periodic form is the one whose overlapped copies sum flat. */
  for (uint32_t n = 0; n < OAA_FFT_WINDOW; n++) {
    s->window[n] =
        0.5f -
        0.5f * cosf(2.0f * (float)OAA_PI * (float)n / (float)OAA_FFT_WINDOW);
  }

  oaa_spectrum_map_bands(s);
  oaa_spectrum_reset(s);
  return 1;
}

void oaa_spectrum_free(oaa_spectrum *s) {
  if (s->setup != NULL) {
    pffft_destroy_setup(s->setup);
  }
  free(s->window);
  free(s->input);
  free(s->power);
  free(s->power_mid);
  free(s->power_side);
  pffft_aligned_free(s->frame);
  pffft_aligned_free(s->work);
  pffft_aligned_free(s->coefficients);
  memset(s, 0, sizeof(*s));
}

void oaa_spectrum_reset(oaa_spectrum *s) {
  if (s->input != NULL) {
    memset(s->input, 0, (size_t)s->channels * OAA_FFT_WINDOW * sizeof(float));
  }
  if (s->power != NULL) {
    memset(s->power, 0, (size_t)s->channels * OAA_FFT_BINS * sizeof(float));
  }
  if (s->power_mid != NULL) {
    memset(s->power_mid, 0, OAA_FFT_BINS * sizeof(float));
    memset(s->power_side, 0, OAA_FFT_BINS * sizeof(float));
  }
  s->write = 0;
  s->filled = 0;
  s->since_hop = 0;
  s->ready = 0;

  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    s->band_db[b] = OAA_DB_FLOOR;
    s->band_pan[b] = 0.0f;
    s->hold_db[b] = OAA_DB_FLOOR;
    s->hold_left[b] = 0.0f;
    for (uint32_t i = 0; i < OAA_SPECTRUM_PAIR_SOURCES; i++) {
      /* A one-channel engine has a left and nothing else: its right, mid and
       * side are not quiet, they are not measured, and they say so with the
       * value that cannot be mistaken for a level. */
      const int measured = i == 0 || s->channels >= 2;
      s->source_db[i][b] = measured ? OAA_DB_FLOOR : NAN;
      s->source_hold_db[i][b] = measured ? OAA_DB_FLOOR : NAN;
      s->source_hold_left[i][b] = 0.0f;
    }
  }
}

/* --- Folding one power array onto one band -------------------------------- */

/* The band's level from one power array: the loudest bin it covers, or the
 * transform read between the two nearest for a band too narrow to contain
 * one — see "Between the bins" in the header. Written once so that the
 * combined fold and the four per-source folds cannot come to read a band
 * differently. */
static float oaa_spectrum_band_power(const oaa_spectrum *s, const float *power,
                                     uint32_t b) {
  const uint32_t first = s->band_first[b];
  const float lerp = s->band_lerp[b];
  if (lerp >= 0.0f) {
    const float below = power[first];
    const float above = power[first + 1];
    return below + (above - below) * lerp;
  }
  const uint32_t last = s->band_last[b];
  float loudest = 0.0f;
  for (uint32_t k = first; k <= last; k++) {
    if (power[k] > loudest) {
      loudest = power[k];
    }
  }
  return loudest;
}

/* Hold at the maximum, then fall. Applied per transform rather than at
 * publish time so that every transform is seen — a publish carries one frame,
 * and a hold that only saw published frames would miss whatever landed
 * between them. */
static void oaa_spectrum_hold(float db, float *hold_db, float *hold_left,
                              float dt, float fall) {
  if (db >= *hold_db) {
    *hold_db = db;
    *hold_left = OAA_SPECTRUM_HOLD_SECONDS;
  } else if (*hold_left > 0.0f) {
    *hold_left -= dt;
  } else {
    *hold_db -= fall;
    if (*hold_db < OAA_DB_FLOOR) {
      *hold_db = OAA_DB_FLOOR;
    }
  }
}

/* One windowed transform of `frame` into `power`. `frame` holds the
 * de-ringed, windowed samples in its first OAA_FFT_WINDOW slots and the
 * padding after them. */
static void oaa_spectrum_power_of_frame(oaa_spectrum *s, float *power) {
  const float scale = OAA_FFT_AMPLITUDE_SCALE;

  pffft_transform_ordered(s->setup, s->frame, s->coefficients, s->work,
                          PFFFT_FORWARD);

  /* pffft packs the two purely real coefficients — DC and Nyquist — into the
   * first complex slot. Neither is inside the display range, and unpacking
   * them only to drop them would be the kind of code somebody later "fixes"
   * by plotting them. */
  power[0] = 0.0f;
  power[OAA_FFT_BINS - 1] = 0.0f;

  for (uint32_t k = 1; k < OAA_FFT_BINS - 1; k++) {
    const float re = s->coefficients[2 * k] * scale;
    const float im = s->coefficients[2 * k + 1] * scale;
    power[k] = re * re + im * im;
  }
}

/* --- One transform -------------------------------------------------------- */

static void oaa_spectrum_transform(oaa_spectrum *s) {
  for (uint32_t c = 0; c < s->channels; c++) {
    const float *ring = &s->input[(size_t)c * OAA_FFT_WINDOW];

    /* De-ring and window in one pass. `write` is where the *next* sample goes,
     * so it is also the oldest sample in the ring. Everything past
     * OAA_FFT_WINDOW is the padding and stays as init left it. */
    for (uint32_t n = 0; n < OAA_FFT_WINDOW; n++) {
      const uint32_t index = (s->write + n) & (OAA_FFT_WINDOW - 1);
      s->frame[n] = ring[index] * s->window[n];
    }

    oaa_spectrum_power_of_frame(s, &s->power[(size_t)c * OAA_FFT_BINS]);
  }

  /* The front pair's mid and side, as two more signals through the same
   * window and the same transform. Windowing is linear, so the windowed mid
   * is the mean of the two windowed channels sample for sample — one pass
   * over both rings each, no third ring to keep. */
  if (s->channels >= 2) {
    const float *left = &s->input[0];
    const float *right = &s->input[OAA_FFT_WINDOW];
    for (uint32_t n = 0; n < OAA_FFT_WINDOW; n++) {
      const uint32_t index = (s->write + n) & (OAA_FFT_WINDOW - 1);
      s->frame[n] = 0.5f * (left[index] + right[index]) * s->window[n];
    }
    oaa_spectrum_power_of_frame(s, s->power_mid);
    for (uint32_t n = 0; n < OAA_FFT_WINDOW; n++) {
      const uint32_t index = (s->write + n) & (OAA_FFT_WINDOW - 1);
      s->frame[n] = 0.5f * (left[index] - right[index]) * s->window[n];
    }
    oaa_spectrum_power_of_frame(s, s->power_side);
  }

  /* --- Bands ----------------------------------------------------------- */
  const float dt = (float)OAA_FFT_HOP / (float)s->sample_rate;
  const float fall = OAA_SPECTRUM_FALL_DB_PER_SECOND * dt;

  /* Which power array each pair source folds from. NULL is a source this
   * engine cannot make, whose bands were set to NaN at reset and stay so. */
  const float *source_power[OAA_SPECTRUM_PAIR_SOURCES] = {
      &s->power[0],
      s->channels >= 2 ? &s->power[OAA_FFT_BINS] : NULL,
      s->power_mid,
      s->power_side,
  };

  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    const uint32_t first = s->band_first[b];
    if (first == 0) {
      s->band_db[b] = OAA_DB_FLOOR;
      s->band_pan[b] = 0.0f;
      s->hold_db[b] = OAA_DB_FLOOR;
      for (uint32_t i = 0; i < OAA_SPECTRUM_PAIR_SOURCES; i++) {
        if (source_power[i] != NULL) {
          s->source_db[i][b] = OAA_DB_FLOOR;
          s->source_hold_db[i][b] = OAA_DB_FLOOR;
        }
      }
      continue;
    }
    const uint32_t last = s->band_last[b];

    /* Loudest bin in the band, over every channel — or, for a band with no
     * bin in it, the transform read between the two nearest. The worst-case
     * rule across channels is the one the number boxes use for per-channel
     * quantities: an average would hide one hot channel, which is the thing
     * worth seeing. */
    float loudest = 0.0f;
    for (uint32_t c = 0; c < s->channels; c++) {
      const float level = oaa_spectrum_band_power(
          s, &s->power[(size_t)c * OAA_FFT_BINS], b);
      if (level > loudest) {
        loudest = level;
      }
    }
    s->band_db[b] = oaa_db_from_power(loudest);

    /* Front-pair balance. Summed over the band rather than taken at its peak
     * bin, because a band wide enough to hold several partials has a pan
     * position only if you account for all of them. */
    if (s->channels >= 2) {
      const float *left = &s->power[0];
      const float *right = &s->power[OAA_FFT_BINS];
      float energy_l = 0.0f;
      float energy_r = 0.0f;
      for (uint32_t k = first; k <= last; k++) {
        energy_l += left[k];
        energy_r += right[k];
      }
      const float total = energy_l + energy_r;
      s->band_pan[b] = total > OAA_SPECTRUM_POWER_FLOOR
                           ? (energy_r - energy_l) / total
                           : 0.0f;
    }

    oaa_spectrum_hold(s->band_db[b], &s->hold_db[b], &s->hold_left[b], dt,
                      fall);

    /* The same band on each of the pair's four signals, each with a hold of
     * its own. */
    for (uint32_t i = 0; i < OAA_SPECTRUM_PAIR_SOURCES; i++) {
      if (source_power[i] == NULL) {
        continue;
      }
      s->source_db[i][b] =
          oaa_db_from_power(oaa_spectrum_band_power(s, source_power[i], b));
      oaa_spectrum_hold(s->source_db[i][b], &s->source_hold_db[i][b],
                        &s->source_hold_left[i][b], dt, fall);
    }
  }

  s->ready = 1;
}

/* --- Feeding -------------------------------------------------------------- */

void oaa_spectrum_process(oaa_spectrum *s, const float *interleaved,
                          uint32_t frames) {
  if (s->setup == NULL || frames == 0) {
    return;
  }

  const uint32_t channels = s->channels;

  for (uint32_t i = 0; i < frames; i++) {
    const float *frame = &interleaved[(size_t)i * channels];
    for (uint32_t c = 0; c < channels; c++) {
      s->input[(size_t)c * OAA_FFT_WINDOW + s->write] = frame[c];
    }
    s->write = (s->write + 1) & (OAA_FFT_WINDOW - 1);

    if (s->filled < OAA_FFT_WINDOW) {
      s->filled++;
    }
    s->since_hop++;

    /* One transform per hop, and only once the window is genuinely full.
     * Transforming a half-filled ring would analyse the zeros in it, which
     * reads as a real measurement of a signal that is quieter than it is. */
    if (s->since_hop >= OAA_FFT_HOP && s->filled >= OAA_FFT_WINDOW) {
      s->since_hop = 0;
      oaa_spectrum_transform(s);
    }
  }
}

void oaa_spectrum_read(const oaa_spectrum *s, float *bands, float *peaks,
                       float *pan) {
  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    bands[b] = s->band_db[b];
    peaks[b] = s->hold_db[b];
    if (pan != NULL) {
      pan[b] = s->band_pan[b];
    }
  }
}

void oaa_spectrum_read_source(const oaa_spectrum *s, int32_t source,
                              float *bands, float *peaks) {
  if (source < OAA_SPECTRUM_LEFT || source > OAA_SPECTRUM_SIDE) {
    return;
  }
  const uint32_t i = (uint32_t)(source - OAA_SPECTRUM_LEFT);
  for (uint32_t b = 0; b < OAA_SPECTRUM_BANDS; b++) {
    bands[b] = s->source_db[i][b];
    peaks[b] = s->source_hold_db[i][b];
  }
}
