/*
 * oaa_truepeak.h — inter-sample peak, per ITU-R BS.1770-4 Annex 2.
 *
 * SPDX-License-Identifier: MIT
 *
 * Sample peak and true peak are different measurements, and the difference is
 * the entire reason this file exists. A signal whose highest *sample* sits at
 * −0.1 dBFS can reconstruct above 0 dBFS between those samples, and the
 * converter — or the lossy encoder a streaming service runs it through — is
 * where that overshoot turns into audible distortion. Only true peak is worth
 * checking a delivery ceiling against.
 *
 * The measurement is: upsample 4x through the FIR the standard specifies, then
 * take the largest magnitude of the result.
 */

#ifndef OAA_TRUEPEAK_H
#define OAA_TRUEPEAK_H

#include "oaa/oaa.h"

#include <stdint.h>

/* Taps per polyphase branch. The standard's filter is 48 taps, given as 4
 * phases of 12. */
#define OAA_TRUEPEAK_TAPS 12
#define OAA_TRUEPEAK_PHASES 4

/* Per-100 ms maxima retained, so a 3 s sliding maximum can be taken without
 * storing samples. Matches the loudness sub-block cadence deliberately: the
 * two measurements are shown side by side and must describe the same window. */
#define OAA_TRUEPEAK_HISTORY 30

typedef struct {
  uint32_t channels;

  /* Input delay line, newest at [pos]. One per channel. */
  float delay[OAA_MAX_CHANNELS][OAA_TRUEPEAK_TAPS];
  uint32_t pos;

  uint32_t frames_per_subblock;
  uint32_t frames_in_subblock;

  double subblock_peak;                    /* running max within the current sub-block */
  double history[OAA_TRUEPEAK_HISTORY];    /* completed sub-block maxima */
  uint32_t history_write;
  uint32_t history_filled;

  double peak_max; /* largest magnitude since reset, linear */
} oaa_truepeak;

void oaa_truepeak_init(oaa_truepeak *tp, uint32_t channels, uint32_t sample_rate);
void oaa_truepeak_reset(oaa_truepeak *tp);
void oaa_truepeak_process(oaa_truepeak *tp, const float *interleaved,
                          uint32_t frames);

/* Largest inter-sample peak over roughly the last 3 s, linear. */
double oaa_truepeak_windowed(const oaa_truepeak *tp);

/* Largest inter-sample peak since reset, linear. */
double oaa_truepeak_max(const oaa_truepeak *tp);

#endif /* OAA_TRUEPEAK_H */
