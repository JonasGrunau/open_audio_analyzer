/*
 * bel_spectrum.h — the short-time Fourier analysis behind the analyser,
 * the spectrogram and the stereo cloud.
 *
 * SPDX-License-Identifier: MIT
 *
 * One transform per channel per hop, mapped onto log-spaced display bands. The
 * three modules that draw frequency content all read the same bands, which is
 * deliberate: two analysers on the same tab that disagree about where 1 kHz is,
 * or about how loud it is, are two analysers you cannot trust either of.
 *
 * ---------------------------------------------------------------------------
 * Why the numbers below are what they are
 *
 * 4096 points at 48 kHz is 11.7 Hz of resolution and 85 ms of window. That is
 * the usual compromise and it is a genuine one: halving it doubles the time
 * resolution and makes the bottom two octaves unreadable, because 23 Hz bins
 * cannot separate any two adjacent bass notes.
 *
 * The hop is a quarter of the window — 1024 frames, which is exactly one
 * analysis block at the default settings, so a publish carries a spectrum that
 * is at most one hop old.
 *
 * Magnitudes are Hann-compensated so that a full-scale sine reads 0 dBFS. Hann
 * scallops: a tone sitting between two bin centres reads up to 1.4 dB low. That
 * is inherent to reading a peak bin and every analyser does it; the fix would
 * be summing the three bins around a peak, which is right for a tone and wrong
 * for the broadband material this display mostly shows.
 *
 * ---------------------------------------------------------------------------
 * Peak-per-bin, not average-per-bin
 *
 * A display band at 10 kHz spans dozens of FFT bins. Averaging them buries a
 * narrow resonance under its quiet neighbours, and a narrow resonance is
 * precisely what somebody looks at a spectrum analyser to find. Taking the
 * loudest bin in the band overstates broadband noise slightly and never hides
 * a tone, which is the right way round.
 */

#ifndef BEL_SPECTRUM_H
#define BEL_SPECTRUM_H

#include "bel/bel.h"

#include <stdint.h>

/* Points per transform, and how far the window advances between them. */
#define BEL_FFT_SIZE 4096
#define BEL_FFT_HOP 1024

#define BEL_FFT_BINS (BEL_FFT_SIZE / 2 + 1)

/* How long a band's peak stays at its maximum, and how fast it falls after.
 * Slower than the sample-peak meter's 20 dB/s, because a spectrum peak is read
 * as a shape rather than a number and a fast fall makes the shape flicker. */
#define BEL_SPECTRUM_HOLD_SECONDS 1.5f
#define BEL_SPECTRUM_FALL_DB_PER_SECOND 12.0f

typedef struct PFFFT_Setup PFFFT_Setup;

typedef struct {
  PFFFT_Setup *setup;

  uint32_t channels;
  uint32_t sample_rate;

  /* Hann, and the raw input each channel is accumulating, as a ring. The ring
   * is what lets a 4096-point window advance by 1024 without the caller ever
   * handing us a buffer of either size. */
  float *window;
  float *input; /* channels * BEL_FFT_SIZE, channel-major */
  uint32_t write;
  uint32_t filled;    /* frames seen, saturating at BEL_FFT_SIZE */
  uint32_t since_hop; /* frames since the last transform */

  /* pffft insists on 16-byte alignment, so these come from its allocator
   * rather than from calloc with the rest of the engine. */
  float *frame; /* windowed, de-ringed input */
  float *work;
  float *coefficients;

  /* Latest per-bin power, per channel. Kept rather than folded straight into
   * bands because the pan calculation needs the two front channels separately
   * after the band mapping has already happened. */
  float *power; /* channels * BEL_FFT_BINS */

  /* Which bins each display band covers. `first` is zero for a band above
   * Nyquist — bin 0 is DC and never mapped, so it doubles as "no data" without
   * a parallel array of validity flags. */
  uint16_t band_first[BEL_SPECTRUM_BANDS];
  uint16_t band_last[BEL_SPECTRUM_BANDS];

  float band_db[BEL_SPECTRUM_BANDS];
  float band_pan[BEL_SPECTRUM_BANDS];
  float hold_db[BEL_SPECTRUM_BANDS];
  float hold_left[BEL_SPECTRUM_BANDS];

  int ready; /* a transform has run since the last reset */
} bel_spectrum;

/* Returns non-zero on success. Fails only on allocation, or on a build where
 * pffft refuses BEL_FFT_SIZE — neither is recoverable at the call site. */
int bel_spectrum_init(bel_spectrum *s, uint32_t channels, uint32_t sample_rate);
void bel_spectrum_free(bel_spectrum *s);

/* Clears the holds and the accumulated window. */
void bel_spectrum_reset(bel_spectrum *s);

/* Feeds interleaved audio, running as many transforms as the hop allows. */
void bel_spectrum_process(bel_spectrum *s, const float *interleaved,
                          uint32_t frames);

/* Copies the current bands out. `pan` may be NULL. */
void bel_spectrum_read(const bel_spectrum *s, float *bands, float *peaks,
                       float *pan);

#endif /* BEL_SPECTRUM_H */
