/*
 * bel_internal.h — the engine struct and the two OS primitives it needs.
 *
 * SPDX-License-Identifier: MIT
 *
 * Nothing here is part of the ABI. Anything a consumer can see belongs in
 * include/bel/bel.h; if you are tempted to expose a field from this file,
 * publish it in the snapshot instead.
 */

#ifndef BEL_INTERNAL_H
#define BEL_INTERNAL_H

#include "bel/bel.h"
#include "bel_atomic.h"
#include "bel_loudness.h"
#include "bel_truepeak.h"

#include <stdint.h>

/* ------------------------------------------------------------------------ */
/* Thread and sleep, twice                                                   */
/* ------------------------------------------------------------------------ */

#if defined(_WIN32)
#include <windows.h>
typedef HANDLE bel_thread;
#else
#include <pthread.h>
typedef pthread_t bel_thread;
#endif

int bel_thread_start(bel_thread *thread, void *(*entry)(void *), void *arg);
void bel_thread_join(bel_thread thread);

/* Monotonic seconds. Used only for pacing a synthetic source against real
 * time; measurements themselves are counted in samples, never in wall clock,
 * because a file analysed at 200x real time must produce the same numbers as
 * the same file played back live. */
double bel_now_seconds(void);
void bel_sleep_seconds(double seconds);

/* ------------------------------------------------------------------------ */
/* Per-channel meter ballistics                                              */
/* ------------------------------------------------------------------------ */

typedef struct {
  float peak_linear;     /* current held peak, linear */
  float peak_hold_left;  /* seconds remaining before the hold releases */
  float rms_mean_square; /* smoothed mean square, linear */
  float vu_value;        /* smoothed VU deflection, linear */
  uint32_t clip_run;     /* consecutive samples at or above full scale */
} bel_channel_state;

/* ------------------------------------------------------------------------ */
/* The engine                                                                */
/* ------------------------------------------------------------------------ */

struct bel_engine {
  bel_config cfg;

  /* --- The seqlock ----------------------------------------------------- */
  /* Odd while a publish is in flight, even when `shared` is consistent. The
   * reader spins on this rather than taking a lock, so a slow or descheduled
   * UI thread can never stall the analysis thread. */
  bel_atomic_u32 seq;
  bel_snapshot shared;

  /* Where the analysis thread actually accumulates. It is copied into
   * `shared` inside the seqlock window, which keeps that window down to a
   * single memcpy instead of spanning the whole analysis pass. Writing
   * straight into `shared` would look like it saved a copy, but it would put
   * the payload writes *outside* the odd/even window — a reader could then
   * observe a torn block with matching sequence numbers on both sides and
   * never know. */
  bel_snapshot staging;

  /* The reader's copy. Its address is handed out by bel_snapshot_buffer() and
   * must never change for the engine's lifetime — Dart builds typed views over
   * it once at startup and reuses them for every frame. */
  bel_snapshot front;

  /* --- Thread control --------------------------------------------------- */
  bel_atomic_u32 should_run;
  bel_atomic_u32 thread_alive;

  /* Set by bel_engine_reset() from the owner's thread, consumed by the
   * analysis thread at a block boundary. See the comment at the top of the
   * analysis loop for why the reset is not simply performed in place. */
  bel_atomic_u32 reset_pending;

  bel_thread thread;

  /* --- Analysis state, never published directly ------------------------- */
  bel_channel_state channel[BEL_MAX_CHANNELS];

  /* The two measurements with their own standard. Kept as whole objects rather
   * than folded into this struct so that each can be unit tested — and read —
   * against the document that defines it. */
  bel_loudness loudness;
  bel_truepeak truepeak;
  float *block;         /* interleaved scratch, block_frames * channels */
  double tone_phase;    /* radians, kept in [0, 2pi) to stay precise */
  double tone_time;     /* seconds of generated signal, for the modulators */
  uint64_t frames_done; /* since the last reset */
  uint64_t generation;

  double corr_sum_lr; /* running products for Pearson correlation */
  double corr_sum_ll;
  double corr_sum_rr;

  float sample_peak_max_linear;
};

/* Fill `frames` frames of interleaved audio into engine->block. */
void bel_source_render(bel_engine *engine, uint32_t frames);

/* Run every meter over `interleaved` and fold the result into the staging
 * snapshot. Takes a buffer rather than reading engine->block, because the push
 * source analyses a caller's memory directly — which is also what makes the
 * conformance suite able to feed the engine a signal it constructed. */
void bel_analyse(bel_engine *engine, const float *interleaved, uint32_t frames);

/* Publish `shared` under the seqlock. */
void bel_snapshot_publish(bel_engine *engine);

#endif /* BEL_INTERNAL_H */
