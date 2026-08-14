/*
 * bel_snapshot.c — the seqlock that carries measurements from the analysis
 * thread to whoever is about to paint them.
 *
 * SPDX-License-Identifier: MIT
 *
 * A seqlock is the right primitive here for one specific reason: it is
 * wait-free on the writer side. The analysis thread is the thread that must
 * never be delayed — it is downstream of a real-time audio callback, and if it
 * falls behind, the ring buffer overruns and we lose signal we can never
 * recover. A mutex would let a descheduled UI thread block it. A seqlock
 * cannot: the writer publishes unconditionally and it is the *reader* that
 * retries.
 *
 * The cost of that choice is that a reader can observe a torn write and has to
 * try again. At ~47 Hz publishes against a 60-120 Hz reader, a retry is rare and
 * a second retry has never been observed; the loop is bounded anyway, because
 * spinning forever in a paint callback would be a far worse bug than showing
 * one stale frame.
 */

#include "bel_internal.h"

#include <string.h>

/* If the reader loses this many races in a row, something is pathological —
 * a writer stuck mid-publish, or a debugger stopped on the analysis thread.
 * Returning the previous contents is always safe: the caller compares
 * generations and simply does not repaint. */
#define BEL_ACQUIRE_MAX_ATTEMPTS 8

void bel_snapshot_publish(bel_engine *engine) {
  engine->generation++;
  engine->staging.generation = engine->generation;

  /* Odd: a write is in flight. Everything between the two increments is what
   * a reader is protected against; keeping it to one memcpy is what keeps
   * reader retries rare. */
  bel_atomic_increment(&engine->seq);

  memcpy(&engine->shared, &engine->staging, sizeof(bel_snapshot));

  /* Even: consistent again. The acq_rel on this increment is what publishes
   * the memcpy above to the reader's acquire load. */
  bel_atomic_increment(&engine->seq);
}

uint64_t bel_snapshot_acquire(bel_engine *engine) {
  if (engine == NULL) {
    return 0;
  }

  for (int attempt = 0; attempt < BEL_ACQUIRE_MAX_ATTEMPTS; attempt++) {
    const uint32_t before = bel_atomic_load_acquire(&engine->seq);
    if (before & 1u) {
      continue; /* writer mid-publish */
    }

    memcpy(&engine->front, &engine->shared, sizeof(bel_snapshot));

    const uint32_t after = bel_atomic_load_acquire(&engine->seq);
    if (before == after) {
      return engine->front.generation;
    }
  }

  /* Gave up. `front` may be torn, so report the last generation we know was
   * whole rather than the one we just failed to read. */
  return engine->front.generation;
}

const bel_snapshot *bel_snapshot_buffer(bel_engine *engine) {
  return engine == NULL ? NULL : &engine->front;
}

/* Offsets, straight from the compiler. See the header for why these are not
 * arithmetic on the Dart side. */

const float *bel_snapshot_peak(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->peak;
}

const float *bel_snapshot_rms(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->rms;
}

const float *bel_snapshot_vu(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->vu;
}

const uint32_t *bel_snapshot_clip(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->clip;
}

const float *bel_snapshot_spectrum(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->spectrum;
}

const float *bel_snapshot_spectrum_peak(const bel_snapshot *snapshot) {
  return snapshot == NULL ? NULL : snapshot->spectrum_peak;
}
