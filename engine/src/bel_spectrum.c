/*
 * bel_spectrum.c — short-time Fourier analysis. See bel_spectrum.h for why the
 * window, the hop and the band mapping are what they are.
 *
 * SPDX-License-Identifier: MIT
 */

#include "bel_spectrum.h"

#include "pffft.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Declared rather than taken from math.h, as elsewhere in the engine: M_PI is
 * POSIX, not ISO C, and `-std=c11` hides it on glibc and needs a macro defined
 * before the include on MSVC. */
#define BEL_PI 3.14159265358979323846

/* Amplitude of a full-scale sine, given the peak bin of a Hann-windowed
 * transform. The window sums to N/2 and a real sine splits its energy between
 * the positive and negative frequency, so the peak bin holds A*N/4. */
#define BEL_FFT_AMPLITUDE_SCALE (4.0f / (float)BEL_FFT_SIZE)

/* Below this a band is reported at the floor rather than as a very negative
 * number, so that digital silence does not produce -300 dB noise on screen. */
#define BEL_SPECTRUM_POWER_FLOOR 1e-15f

static float bel_db_from_power(float power) {
  if (power <= BEL_SPECTRUM_POWER_FLOOR) {
    return BEL_DB_FLOOR;
  }
  const float db = 10.0f * log10f(power);
  return db < BEL_DB_FLOOR ? BEL_DB_FLOOR : db;
}

/* --- Band mapping --------------------------------------------------------- */

/*
 * Which FFT bins each log-spaced display band covers.
 *
 * At the bottom of the range a band is far narrower than one bin — at 48 kHz
 * the first band spans 20.0 to 20.1 Hz and a bin is 11.7 Hz wide — so several
 * consecutive bands legitimately map to the same bin. That is not a bug to
 * work around: the transform genuinely has no more resolution there, and
 * interpolating between bins would invent detail that was never measured.
 */
static void bel_spectrum_map_bands(bel_spectrum *s) {
  const double nyquist_bin = (double)BEL_FFT_BINS - 1.0;
  const double bins_per_hz = (double)BEL_FFT_SIZE / (double)s->sample_rate;
  const double ratio =
      (double)BEL_SPECTRUM_HZ_HIGH / (double)BEL_SPECTRUM_HZ_LOW;

  for (uint32_t b = 0; b < BEL_SPECTRUM_BANDS; b++) {
    const double low = (double)BEL_SPECTRUM_HZ_LOW *
                       pow(ratio, (double)b / (double)BEL_SPECTRUM_BANDS);
    const double high = (double)BEL_SPECTRUM_HZ_LOW *
                        pow(ratio, (double)(b + 1) / (double)BEL_SPECTRUM_BANDS);

    long first = (long)ceil(low * bins_per_hz);
    long last = (long)floor(high * bins_per_hz);

    if (last < first) {
      /* Narrower than a bin: take the one nearest the band's centre. */
      first = last = (long)floor(sqrt(low * high) * bins_per_hz + 0.5);
    }

    if (first < 1) {
      first = 1; /* Bin 0 is DC, which is not a frequency anybody plots. */
    }
    if ((double)first > nyquist_bin) {
      /* Above Nyquist. Nothing was measured here and nothing is drawn. */
      s->band_first[b] = 0;
      s->band_last[b] = 0;
      continue;
    }
    if ((double)last > nyquist_bin) {
      last = (long)nyquist_bin;
    }

    s->band_first[b] = (uint16_t)first;
    s->band_last[b] = (uint16_t)last;
  }
}

/* --- Lifecycle ------------------------------------------------------------ */

int bel_spectrum_init(bel_spectrum *s, uint32_t channels,
                      uint32_t sample_rate) {
  memset(s, 0, sizeof(*s));

  if (channels == 0 || channels > BEL_MAX_CHANNELS || sample_rate == 0) {
    return 0;
  }

  s->channels = channels;
  s->sample_rate = sample_rate;

  s->setup = pffft_new_setup(BEL_FFT_SIZE, PFFFT_REAL);
  s->window = (float *)calloc(BEL_FFT_SIZE, sizeof(float));
  s->input = (float *)calloc((size_t)channels * BEL_FFT_SIZE, sizeof(float));
  s->power = (float *)calloc((size_t)channels * BEL_FFT_BINS, sizeof(float));

  s->frame = (float *)pffft_aligned_malloc(BEL_FFT_SIZE * sizeof(float));
  s->work = (float *)pffft_aligned_malloc(BEL_FFT_SIZE * sizeof(float));
  s->coefficients =
      (float *)pffft_aligned_malloc(BEL_FFT_SIZE * sizeof(float));

  if (s->setup == NULL || s->window == NULL || s->input == NULL ||
      s->power == NULL || s->frame == NULL || s->work == NULL ||
      s->coefficients == NULL) {
    bel_spectrum_free(s);
    return 0;
  }

  /* Periodic Hann rather than symmetric: the window is applied to successive
   * overlapping frames of a continuous signal, not to one isolated record, and
   * the periodic form is the one whose overlapped copies sum flat. */
  for (uint32_t n = 0; n < BEL_FFT_SIZE; n++) {
    s->window[n] =
        0.5f -
        0.5f * cosf(2.0f * (float)BEL_PI * (float)n / (float)BEL_FFT_SIZE);
  }

  bel_spectrum_map_bands(s);
  bel_spectrum_reset(s);
  return 1;
}

void bel_spectrum_free(bel_spectrum *s) {
  if (s->setup != NULL) {
    pffft_destroy_setup(s->setup);
  }
  free(s->window);
  free(s->input);
  free(s->power);
  pffft_aligned_free(s->frame);
  pffft_aligned_free(s->work);
  pffft_aligned_free(s->coefficients);
  memset(s, 0, sizeof(*s));
}

void bel_spectrum_reset(bel_spectrum *s) {
  if (s->input != NULL) {
    memset(s->input, 0, (size_t)s->channels * BEL_FFT_SIZE * sizeof(float));
  }
  if (s->power != NULL) {
    memset(s->power, 0, (size_t)s->channels * BEL_FFT_BINS * sizeof(float));
  }
  s->write = 0;
  s->filled = 0;
  s->since_hop = 0;
  s->ready = 0;

  for (uint32_t b = 0; b < BEL_SPECTRUM_BANDS; b++) {
    s->band_db[b] = BEL_DB_FLOOR;
    s->band_pan[b] = 0.0f;
    s->hold_db[b] = BEL_DB_FLOOR;
    s->hold_left[b] = 0.0f;
  }
}

/* --- One transform -------------------------------------------------------- */

static void bel_spectrum_transform(bel_spectrum *s) {
  const float scale = BEL_FFT_AMPLITUDE_SCALE;

  for (uint32_t c = 0; c < s->channels; c++) {
    const float *ring = &s->input[(size_t)c * BEL_FFT_SIZE];

    /* De-ring and window in one pass. `write` is where the *next* sample goes,
     * so it is also the oldest sample in the ring. */
    for (uint32_t n = 0; n < BEL_FFT_SIZE; n++) {
      const uint32_t index = (s->write + n) & (BEL_FFT_SIZE - 1);
      s->frame[n] = ring[index] * s->window[n];
    }

    pffft_transform_ordered(s->setup, s->frame, s->coefficients, s->work,
                            PFFFT_FORWARD);

    float *power = &s->power[(size_t)c * BEL_FFT_BINS];

    /* pffft packs the two purely real coefficients — DC and Nyquist — into the
     * first complex slot. Neither is inside the display range, and unpacking
     * them only to drop them would be the kind of code somebody later "fixes"
     * by plotting them. */
    power[0] = 0.0f;
    power[BEL_FFT_BINS - 1] = 0.0f;

    for (uint32_t k = 1; k < BEL_FFT_BINS - 1; k++) {
      const float re = s->coefficients[2 * k] * scale;
      const float im = s->coefficients[2 * k + 1] * scale;
      power[k] = re * re + im * im;
    }
  }

  /* --- Bands ----------------------------------------------------------- */
  const float dt = (float)BEL_FFT_HOP / (float)s->sample_rate;
  const float fall = BEL_SPECTRUM_FALL_DB_PER_SECOND * dt;

  for (uint32_t b = 0; b < BEL_SPECTRUM_BANDS; b++) {
    const uint32_t first = s->band_first[b];
    if (first == 0) {
      s->band_db[b] = BEL_DB_FLOOR;
      s->band_pan[b] = 0.0f;
      s->hold_db[b] = BEL_DB_FLOOR;
      continue;
    }
    const uint32_t last = s->band_last[b];

    /* Loudest bin in the band, over every channel. The same worst-case rule
     * the number boxes use for per-channel quantities: an average would hide
     * one hot channel, which is the thing worth seeing. */
    float loudest = 0.0f;
    for (uint32_t c = 0; c < s->channels; c++) {
      const float *power = &s->power[(size_t)c * BEL_FFT_BINS];
      for (uint32_t k = first; k <= last; k++) {
        if (power[k] > loudest) {
          loudest = power[k];
        }
      }
    }
    s->band_db[b] = bel_db_from_power(loudest);

    /* Front-pair balance. Summed over the band rather than taken at its peak
     * bin, because a band wide enough to hold several partials has a pan
     * position only if you account for all of them. */
    if (s->channels >= 2) {
      const float *left = &s->power[0];
      const float *right = &s->power[BEL_FFT_BINS];
      float energy_l = 0.0f;
      float energy_r = 0.0f;
      for (uint32_t k = first; k <= last; k++) {
        energy_l += left[k];
        energy_r += right[k];
      }
      const float total = energy_l + energy_r;
      s->band_pan[b] = total > BEL_SPECTRUM_POWER_FLOOR
                           ? (energy_r - energy_l) / total
                           : 0.0f;
    }

    /* Hold at the maximum, then fall. Applied here rather than at publish
     * time so that every transform is seen — a publish carries one frame, and
     * a hold that only saw published frames would miss whatever landed
     * between them. */
    if (s->band_db[b] >= s->hold_db[b]) {
      s->hold_db[b] = s->band_db[b];
      s->hold_left[b] = BEL_SPECTRUM_HOLD_SECONDS;
    } else if (s->hold_left[b] > 0.0f) {
      s->hold_left[b] -= dt;
    } else {
      s->hold_db[b] -= fall;
      if (s->hold_db[b] < BEL_DB_FLOOR) {
        s->hold_db[b] = BEL_DB_FLOOR;
      }
    }
  }

  s->ready = 1;
}

/* --- Feeding -------------------------------------------------------------- */

void bel_spectrum_process(bel_spectrum *s, const float *interleaved,
                          uint32_t frames) {
  if (s->setup == NULL || frames == 0) {
    return;
  }

  const uint32_t channels = s->channels;

  for (uint32_t i = 0; i < frames; i++) {
    const float *frame = &interleaved[(size_t)i * channels];
    for (uint32_t c = 0; c < channels; c++) {
      s->input[(size_t)c * BEL_FFT_SIZE + s->write] = frame[c];
    }
    s->write = (s->write + 1) & (BEL_FFT_SIZE - 1);

    if (s->filled < BEL_FFT_SIZE) {
      s->filled++;
    }
    s->since_hop++;

    /* One transform per hop, and only once the window is genuinely full.
     * Transforming a half-filled ring would analyse the zeros in it, which
     * reads as a real measurement of a signal that is quieter than it is. */
    if (s->since_hop >= BEL_FFT_HOP && s->filled >= BEL_FFT_SIZE) {
      s->since_hop = 0;
      bel_spectrum_transform(s);
    }
  }
}

void bel_spectrum_read(const bel_spectrum *s, float *bands, float *peaks,
                       float *pan) {
  for (uint32_t b = 0; b < BEL_SPECTRUM_BANDS; b++) {
    bands[b] = s->band_db[b];
    peaks[b] = s->hold_db[b];
    if (pan != NULL) {
      pan[b] = s->band_pan[b];
    }
  }
}
