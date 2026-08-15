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
 * ---------------------------------------------------------------------------
 * Why the transform is four times the window
 *
 * The window and the transform are two different lengths, and confusing them
 * is the mistake this section exists to prevent.
 *
 * The *window* sets what the analysis can resolve: 4096 points at 48 kHz is an
 * 11.7 Hz main lobe, and two bass notes closer together than that merge into
 * one hump no matter what is done afterwards. Lengthening it would separate
 * them, at the cost of smearing every transient across four times as much
 * time, which is the wrong trade for a spectrogram.
 *
 * The *transform* sets how finely that shape is sampled for drawing, and the
 * two are unrelated. Transforming the window on its own samples the spectrum
 * every 11.7 Hz, but the display asks for 512 log-spaced bands and the bottom
 * octave of those is 51 bands over 20 Hz — so twenty-five consecutive bands
 * would read the same bin and the bass would draw as a staircase of bricks.
 *
 * Padding the window out to 16384 with zeros and transforming that samples the
 * *same* transform of the *same* 4096 windowed samples every 2.93 Hz instead.
 * Nothing is invented and nothing is interpolated between measurements: the
 * zero-padded DFT is the exact continuous-frequency transform of the windowed
 * frame, evaluated at four times as many frequencies. The main lobe is still
 * 11.7 Hz wide — the display now draws its actual shape rather than one sample
 * of it stretched across a quarter of an octave.
 *
 * It also removes the Hann scalloping loss. Reading the peak bin of an
 * unpadded transform costs up to 1.4 dB when a tone sits between two bin
 * centres; with the lobe sampled every 2.93 Hz the worst case is under 0.1 dB.
 *
 * ---------------------------------------------------------------------------
 * Between the bins
 *
 * Padding is not enough on its own. The bottom octave of the display is 51 of
 * the 512 bands spread across 20 Hz, and even at 2.93 Hz there is no bin in
 * most of them. Rounding each band to its nearest bin is what drew the bass as
 * a staircase; below about 216 Hz a band is read *between* two bins instead,
 * which is legitimate for the same reason the padding is — the bins are
 * samples of one continuous function, not separate measurements with unknown
 * territory in between. bel_spectrum_map_bands() has the argument in full.
 *
 * ---------------------------------------------------------------------------
 * Peak-per-bin, not average-per-bin
 *
 * A display band at 10 kHz spans a couple of hundred transform bins. Averaging
 * them buries a narrow resonance under its quiet neighbours, and a narrow
 * resonance is precisely what somebody looks at a spectrum analyser to find.
 * Taking the loudest bin in the band overstates broadband noise slightly and
 * never hides a tone, which is the right way round.
 *
 * The padding does not change what this rule means, because the extra bins are
 * not extra measurements: the band's loudest bin is now the loudest point of
 * the same main lobe rather than the loudest *sample* of it. Broadband bands
 * therefore read up to a decibel higher than they did unpadded, which is the
 * scalloping loss going away rather than a level shift.
 */

#ifndef BEL_SPECTRUM_H
#define BEL_SPECTRUM_H

#include "bel/bel.h"

#include <stdint.h>

/* Points of audio per analysis, and how far that window advances between them.
 * BEL_FFT_WINDOW is the resolution; it is also the ring size, so it must stay
 * a power of two. */
#define BEL_FFT_WINDOW 4096
#define BEL_FFT_HOP 1024

/* Points per transform: the window, zero-padded. Only the sampling of the
 * result gets finer — see the header comment. */
#define BEL_FFT_TRANSFORM 16384

#define BEL_FFT_BINS (BEL_FFT_TRANSFORM / 2 + 1)

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
  float *input; /* channels * BEL_FFT_WINDOW, channel-major */
  uint32_t write;
  uint32_t filled;    /* frames seen, saturating at BEL_FFT_SIZE */
  uint32_t since_hop; /* frames since the last transform */

  /* pffft insists on 16-byte alignment, so these come from its allocator
   * rather than from calloc with the rest of the engine.
   *
   * `frame` is BEL_FFT_TRANSFORM long and only its first BEL_FFT_WINDOW
   * samples are ever written; the padding is zeroed once at init and left
   * alone, which pffft permits because it takes its input as const. */
  float *frame; /* windowed, de-ringed input, zero-padded */
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

  /* Where between `first` and `first + 1` the band's centre falls, for the
   * bands too narrow to contain a bin at all; negative for the wider bands,
   * which take the loudest bin they cover instead. See "Between the bins" in
   * the header comment for why this is a reading and not an invention. */
  float band_lerp[BEL_SPECTRUM_BANDS];

  float band_db[BEL_SPECTRUM_BANDS];
  float band_pan[BEL_SPECTRUM_BANDS];
  float hold_db[BEL_SPECTRUM_BANDS];
  float hold_left[BEL_SPECTRUM_BANDS];

  int ready; /* a transform has run since the last reset */
} bel_spectrum;

/* Returns non-zero on success. Fails only on allocation, or on a build where
 * pffft refuses BEL_FFT_TRANSFORM — neither is recoverable at the call site. */
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
