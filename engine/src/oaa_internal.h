/*
 * oaa_internal.h — the engine struct and the two OS primitives it needs.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Nothing here is part of the ABI. Anything a consumer can see belongs in
 * include/oaa/oaa.h; if you are tempted to expose a field from this file,
 * publish it in the snapshot instead.
 */

#ifndef OAA_INTERNAL_H
#define OAA_INTERNAL_H

#include "oaa/oaa.h"
#include "oaa_atomic.h"
#include "oaa_loudness.h"
#include "oaa_ring.h"
#include "oaa_spectrum.h"
#include "oaa_truepeak.h"

#include <stdint.h>

/* ------------------------------------------------------------------------ */
/* Thread and sleep, twice                                                   */
/* ------------------------------------------------------------------------ */

#if defined(_WIN32)
#include <windows.h>
typedef HANDLE oaa_thread;
#else
#include <pthread.h>
typedef pthread_t oaa_thread;
#endif

int oaa_thread_start(oaa_thread *thread, void *(*entry)(void *), void *arg);
void oaa_thread_join(oaa_thread thread);

/* Monotonic seconds. Used only for pacing a synthetic source against real
 * time; measurements themselves are counted in samples, never in wall clock,
 * because a file analysed at 200x real time must produce the same numbers as
 * the same file played back live. */
double oaa_now_seconds(void);
void oaa_sleep_seconds(double seconds);

/* ------------------------------------------------------------------------ */
/* Per-channel meter ballistics                                              */
/* ------------------------------------------------------------------------ */

typedef struct {
  float peak_linear;     /* current held peak, linear */
  float peak_hold_left;  /* seconds remaining before the hold releases */
  float rms_mean_square; /* smoothed mean square, linear */

  /* The run in progress, and the longest one since the reset. Only the second
   * is published: the first is zeroed by the next sample below full scale, so
   * sampling it at a block boundary misses every clip that ended inside the
   * block. See the note at the clip test in oaa_analysis.c. */
  uint32_t clip_run;
  uint32_t clip_worst;

  /* The VU needle, as a position and a velocity, because a VU meter is a
   * second-order system and its overshoot is most of what it feels like. See
   * the ballistics section of oaa_analysis.c. */
  float vu_position;
  float vu_velocity;
} oaa_channel_state;

/* ------------------------------------------------------------------------ */
/* The engine                                                                */
/* ------------------------------------------------------------------------ */

struct oaa_engine {
  oaa_config cfg;

  /* --- The seqlock ----------------------------------------------------- */
  /* Odd while a publish is in flight, even when `shared` is consistent. The
   * reader spins on this rather than taking a lock, so a slow or descheduled
   * UI thread can never stall the analysis thread. */
  oaa_atomic_u32 seq;
  oaa_snapshot shared;

  /* Where the analysis thread actually accumulates. It is copied into
   * `shared` inside the seqlock window, which keeps that window down to a
   * single memcpy instead of spanning the whole analysis pass. Writing
   * straight into `shared` would look like it saved a copy, but it would put
   * the payload writes *outside* the odd/even window — a reader could then
   * observe a torn block with matching sequence numbers on both sides and
   * never know. */
  oaa_snapshot staging;

  /* The reader's copy. Its address is handed out by oaa_snapshot_buffer() and
   * must never change for the engine's lifetime — Dart builds typed views over
   * it once at startup and reuses them for every frame. */
  oaa_snapshot front;

  /* --- Thread control --------------------------------------------------- */
  oaa_atomic_u32 should_run;
  oaa_atomic_u32 thread_alive;

  /* Set by oaa_engine_reset() from the owner's thread, consumed by the
   * analysis thread at a block boundary. See the comment at the top of the
   * analysis loop for why the reset is not simply performed in place. */
  oaa_atomic_u32 reset_pending;

  oaa_thread thread;

  /* Whether `thread` names a thread that was started and not yet joined.
   *
   * Not atomic, and deliberately separate from the two flags above: only the
   * owner's thread ever reads or writes it, and it is the only one that
   * answers the question stop() actually has to ask. `should_run` is the stop
   * *signal* — using it as the predicate makes stop() decide whether to join
   * by reading the flag it is about to clear, so anything that ever cleared it
   * elsewhere would silently turn destroy() into a free underneath a live
   * thread. `thread_alive` is the thread's own report and it goes false a few
   * instructions before the thread actually returns, which is too early to
   * skip the join on. */
  int thread_started;

  /* --- Analysis state, never published directly ------------------------- */
  oaa_channel_state channel[OAA_MAX_CHANNELS];

  /* The two measurements with their own standard. Kept as whole objects rather
   * than folded into this struct so that each can be unit tested — and read —
   * against the document that defines it. */
  oaa_loudness loudness;
  oaa_truepeak truepeak;

  /* Feeds the analyser, the spectrogram and the stereo cloud from one set of
   * transforms. Three modules drawing three independent FFTs of the same audio
   * would cost three times as much and, worse, could disagree with each other
   * about where a peak is. */
  oaa_spectrum spectrum;

  /* Live only for OAA_SOURCE_DEVICE. The ring is what makes the capture
   * callback's job a bounded memcpy; `device` is opaque so that miniaudio's
   * 96,000-line header is included by exactly one translation unit. */
  struct oaa_device *device;
  oaa_ring ring;
  int ring_ready;

  /* --- Watching the producer. OAA_SOURCE_DEVICE only ------------------- */
  /* All four are owned by the analysing thread and read by nobody else.
   *
   * They exist because an empty ring says nothing about why it is empty. A
   * device delivering digital silence and a device that has stopped delivering
   * at all produce the identical picture upstairs — every meter holds its last
   * value — so the only way to tell them apart is to ask the device, which is
   * what `oaa_device_running` is for. See OAA_FLAG_SOURCE_STOPPED. */
  double device_polled_seconds;  /* when the source was last asked */
  double device_revived_seconds; /* when a revive was last attempted */
  double device_stopped_seconds; /* when it was first seen stopped */
  int device_stopped;            /* what the last poll said */

  /* Frames the source was not there to produce, since the last reset.
   *
   * Kept apart from the ring's own drop count because the two are counted by
   * different things — the ring counts exactly what it refused, this is derived
   * from the clock — and because the device branch assigns the ring's count
   * into the snapshot on every block, which would wipe anything accumulated
   * into the same field. They are added on the way out: to a measurement,
   * audio missing is audio missing. */
  uint64_t stalled_frames;

  float *block;         /* interleaved scratch, block_frames * channels */
  double tone_phase;    /* radians, kept in [0, 2pi) to stay precise */
  double tone_time;     /* seconds of generated signal, for the modulators */
  uint64_t frames_done; /* since the last reset */
  uint64_t generation;

  double corr_sum_lr; /* running products for Pearson correlation */
  double corr_sum_ll;
  double corr_sum_rr;

  float sample_peak_max_linear;

  /* --- The silence gate, for OAA's SYSTEM loudness mode ----------------- */
  /* Written by the owner's thread, read by whichever thread analyses. A plain
   * int32 rather than an atomic: it is a mode the user picks, so a block
   * either side of the change is measured under the old one, and nothing about
   * the reading depends on which. */
  int32_t silence_reset;

  /* Seconds of consecutive sub-floor audio. Owned entirely by the analysing
   * thread. */
  double silence_seconds;
};

/* Fill `frames` frames of interleaved audio into engine->block. */
void oaa_source_render(oaa_engine *engine, uint32_t frames);

/* Run every meter over `interleaved` and fold the result into the staging
 * snapshot. Takes a buffer rather than reading engine->block, because the push
 * source analyses a caller's memory directly — which is also what makes the
 * conformance suite able to feed the engine a signal it constructed. */
void oaa_analyse(oaa_engine *engine, const float *interleaved, uint32_t frames);

/* Publish `shared` under the seqlock. */
void oaa_snapshot_publish(oaa_engine *engine);

#endif /* OAA_INTERNAL_H */
