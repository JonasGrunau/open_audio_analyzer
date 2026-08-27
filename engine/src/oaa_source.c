/*
 * oaa_source.c — where blocks of audio come from.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Phase 0 has two sources: digital black, and a synthetic tone. Device capture
 * (miniaudio) and file decode arrive in Phases 1 and 5 behind the same
 * `oaa_source_render` call, which is why that call takes a frame count and
 * fills a buffer rather than exposing anything about where the samples came
 * from.
 *
 * The test tone is not a placeholder. It is how the render path is profiled on
 * a machine with no audio hardware, and how CI exercises the engine on a
 * headless runner. It is also the only source whose output is known exactly,
 * which makes it the reference the meter arithmetic is checked against:
 *
 *   at OAA_TONE_AMPLITUDE = 0.5, channel 0 must read
 *     peak = -6.0206 dBFS   and   RMS = -9.0309 dBFS
 *
 * because a sine of amplitude A has RMS A/sqrt(2), i.e. 3.0103 dB below its
 * peak. If those two numbers ever drift, the meters are wrong, not the tone.
 */

#include "oaa_internal.h"

#include <math.h>
#include <string.h>

#define OAA_PI 3.14159265358979323846

/* 1 kHz, the traditional alignment tone. */
#define OAA_TONE_HZ 1000.0
#define OAA_TONE_AMPLITUDE 0.5

/* The modulator rates exist only to keep every meter moving while a human
 * looks at it. They are slow, and deliberately not harmonically related, so
 * the display never settles into a pattern that hides a stuck value. */
#define OAA_MOD_WIDTH_HZ 0.05 /* sweeps correlation +1 -> -1 -> +1 */
#define OAA_MOD_TILT_HZ 0.03  /* sweeps stereo balance */

void oaa_source_render(oaa_engine *engine, uint32_t frames) {
  const uint32_t channels = engine->cfg.channels;
  const double sample_rate = (double)engine->cfg.sample_rate;
  float *out = engine->block;

  if (engine->cfg.source == OAA_SOURCE_SILENCE) {
    memset(out, 0, sizeof(float) * (size_t)frames * channels);
    engine->tone_time += (double)frames / sample_rate;
    return;
  }

  const double radians_per_frame = 2.0 * OAA_PI * OAA_TONE_HZ / sample_rate;

  for (uint32_t i = 0; i < frames; i++) {
    const double t = engine->tone_time + (double)i / sample_rate;
    const double width = OAA_PI * sin(2.0 * OAA_PI * OAA_MOD_WIDTH_HZ * t);
    const double tilt = 0.30 * sin(2.0 * OAA_PI * OAA_MOD_TILT_HZ * t);

    for (uint32_t c = 0; c < channels; c++) {
      double phase = engine->tone_phase;
      double amplitude = OAA_TONE_AMPLITUDE;

      if (c == 1) {
        /* Right: phase-swept against left so correlation moves, and gently
         * tilted in level so balance moves. */
        phase += width;
        amplitude *= 1.0 + tilt;
      } else if (c > 1) {
        /* Surround channels get a fixed offset and a small attenuation, so a
         * 7.1 Digital Meter shows eight visibly distinct bars. */
        phase += 0.35 * (double)c;
        amplitude *= 1.0 - 0.08 * (double)c;
      }

      out[(size_t)i * channels + c] = (float)(amplitude * sin(phase));
    }

    /* Advance the carrier once per frame, not once per channel, and keep it
     * wrapped: an unwrapped phase accumulator loses precision within an hour
     * at 48 kHz, and this engine is expected to run for days. */
    engine->tone_phase += radians_per_frame;
    if (engine->tone_phase >= 2.0 * OAA_PI) {
      engine->tone_phase -= 2.0 * OAA_PI;
    }
  }

  engine->tone_time += (double)frames / sample_rate;
}
