/*
 * bel_engine.c — lifecycle, the analysis thread, and the OS primitives.
 *
 * SPDX-License-Identifier: MIT
 *
 * The analysis thread is the spine of the whole design. It is the only thread
 * that writes measurements, which is what lets the reader side be a seqlock
 * instead of a mutex, which is what lets the UI read on the thread that is
 * about to paint. Everything downstream of that — no isolates, no channels, no
 * per-frame allocation — falls out of this one thread existing.
 *
 * It also *generates* the signal for the synthetic sources, because there is no
 * capture device yet. When one arrives, a real-time audio callback fills a ring
 * buffer and this thread drains it; the loop below is already shaped for that,
 * which is why it paces itself against a monotonic clock rather than spinning.
 *
 * BEL_SOURCE_PUSH has no thread at all — the caller's thread does the work
 * inside bel_engine_push(). Everything the thread would have done in a given
 * iteration happens there instead, in the same order.
 */

#include "bel_internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <errno.h>
#include <time.h>
#endif

#define BEL_VERSION_STRING "0.2.0-phase1"

#define BEL_DEFAULT_SAMPLE_RATE 48000u
#define BEL_DEFAULT_CHANNELS 2u

/* 1024 frames is 21.3 ms at 48 kHz, so measurements publish at about 47 Hz.
 * That is deliberately close to a display refresh: publishing much slower makes
 * the meters visibly steppy, and publishing much faster spends CPU on frames
 * nobody will ever see. */
#define BEL_DEFAULT_BLOCK_FRAMES 1024u

/* How much lateness the analysis loop will make up before giving up and
 * resynchronising. Roughly a dozen blocks: enough to absorb ordinary scheduler
 * jitter and a slow host, far short of replaying a backlog after a laptop
 * wakes from sleep. */
#define BEL_MAX_CATCHUP_SECONDS 0.25

/* ------------------------------------------------------------------------ */
/* OS primitives                                                             */
/* ------------------------------------------------------------------------ */

#if defined(_WIN32)

typedef struct {
  void *(*entry)(void *);
  void *arg;
} bel_thread_trampoline;

static DWORD WINAPI bel_thread_shim(LPVOID raw) {
  bel_thread_trampoline *t = (bel_thread_trampoline *)raw;
  void *(*entry)(void *) = t->entry;
  void *arg = t->arg;
  free(t);
  entry(arg);
  return 0;
}

int bel_thread_start(bel_thread *thread, void *(*entry)(void *), void *arg) {
  bel_thread_trampoline *t =
      (bel_thread_trampoline *)malloc(sizeof(bel_thread_trampoline));
  if (t == NULL) {
    return BEL_ERR_OUT_OF_MEMORY;
  }
  t->entry = entry;
  t->arg = arg;

  *thread = CreateThread(NULL, 0, bel_thread_shim, t, 0, NULL);
  if (*thread == NULL) {
    free(t);
    return BEL_ERR_THREAD;
  }
  return BEL_OK;
}

void bel_thread_join(bel_thread thread) {
  if (thread != NULL) {
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
  }
}

double bel_now_seconds(void) {
  static LARGE_INTEGER frequency;
  if (frequency.QuadPart == 0) {
    QueryPerformanceFrequency(&frequency);
  }
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return (double)counter.QuadPart / (double)frequency.QuadPart;
}

void bel_sleep_seconds(double seconds) {
  if (seconds <= 0.0) {
    return;
  }
  Sleep((DWORD)(seconds * 1000.0));
}

#else /* POSIX */

int bel_thread_start(bel_thread *thread, void *(*entry)(void *), void *arg) {
  return pthread_create(thread, NULL, entry, arg) == 0 ? BEL_OK : BEL_ERR_THREAD;
}

void bel_thread_join(bel_thread thread) { pthread_join(thread, NULL); }

double bel_now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

void bel_sleep_seconds(double seconds) {
  if (seconds <= 0.0) {
    return;
  }
  struct timespec request;
  request.tv_sec = (time_t)seconds;
  request.tv_nsec = (long)((seconds - (double)request.tv_sec) * 1e9);

  /* nanosleep returns early on a signal, and this thread will be interrupted
   * by the profiler and by the debugger. Resuming the remainder keeps the
   * pacing honest instead of quietly running fast. */
  struct timespec remaining;
  while (nanosleep(&request, &remaining) == -1 && errno == EINTR) {
    request = remaining;
  }
}

#endif

/* ------------------------------------------------------------------------ */
/* Resetting the integrators                                                 */
/* ------------------------------------------------------------------------ */

static void bel_clear_measurements(bel_engine *engine) {
  memset(engine->channel, 0, sizeof(engine->channel));
  bel_loudness_reset(&engine->loudness);
  bel_truepeak_reset(&engine->truepeak);
  engine->frames_done = 0;
  engine->sample_peak_max_linear = 0.0f;
  engine->corr_sum_lr = 0.0;
  engine->corr_sum_ll = 0.0;
  engine->corr_sum_rr = 0.0;

  bel_snapshot *s = &engine->staging;
  s->elapsed_seconds = 0.0;
  s->sample_rate = engine->cfg.sample_rate;
  s->channels = engine->cfg.channels;
  s->flags = BEL_FLAG_SPECTRUM_UNAVAILABLE;

  s->lufs_momentary = NAN;
  s->lufs_short = NAN;
  s->lufs_integrated = NAN;
  s->lra = NAN;
  s->true_peak = NAN;
  s->true_peak_max = NAN;
  s->dr_short = NAN;
  s->dr_integrated = NAN;
  s->plr = NAN;
  s->psr = NAN;

  s->sample_peak_max = BEL_DB_FLOOR;
  s->crest = 0.0f;
  s->correlation = engine->cfg.channels >= 2 ? 0.0f : 1.0f;
  s->balance = 0.0f;

  for (uint32_t c = 0; c < BEL_MAX_CHANNELS; c++) {
    s->peak[c] = BEL_DB_FLOOR;
    s->rms[c] = BEL_DB_FLOOR;
    s->vu[c] = BEL_DB_FLOOR;
    s->clip[c] = 0;
  }
  for (uint32_t b = 0; b < BEL_SPECTRUM_BANDS; b++) {
    s->spectrum[b] = BEL_DB_FLOOR;
    s->spectrum_peak[b] = BEL_DB_FLOOR;
  }
}

/* ------------------------------------------------------------------------ */
/* The analysis thread                                                       */
/* ------------------------------------------------------------------------ */

static void *bel_analysis_thread(void *raw) {
  bel_engine *engine = (bel_engine *)raw;

  const double block_seconds =
      (double)engine->cfg.block_frames / (double)engine->cfg.sample_rate;
  double deadline = bel_now_seconds();

  while (bel_atomic_load_acquire(&engine->should_run)) {
    /* Reset is requested from the owner's thread but performed here, at a
     * block boundary. Clearing the integrators from under a running analysis
     * pass would be a plain data race, and the symptom — one impossible
     * reading immediately after a reset — is exactly the kind of thing that
     * gets dismissed as a display glitch and never fixed. */
    if (bel_atomic_load_acquire(&engine->reset_pending)) {
      bel_clear_measurements(engine);
      bel_atomic_store_release(&engine->reset_pending, 0);
    }

    bel_source_render(engine, engine->cfg.block_frames);
    bel_analyse(engine, engine->block, engine->cfg.block_frames);
    bel_snapshot_publish(engine);

    deadline += block_seconds;
    const double now = bel_now_seconds();

    if (deadline > now) {
      bel_sleep_seconds(deadline - now);
    } else if (now - deadline > BEL_MAX_CATCHUP_SECONDS) {
      /* Too far behind to be worth making up — the machine slept, or the
       * process was stopped in a debugger. Drop the debt and carry on from
       * here, because replaying minutes of backlog as fast as the CPU allows
       * would spin without ever catching up. */
      deadline = now;
    }
    /* Otherwise keep the debt. The next iteration's sleep computes as
     * non-positive and returns immediately, so the loop makes the time up one
     * block at a time. That matters more than it looks: `bel_sleep_seconds`
     * only guarantees *at least* the requested delay, and on a contended host
     * every block overshoots by a few milliseconds. Resetting the deadline on
     * each overshoot — which this loop used to do — discards that error
     * instead of absorbing it, and the engine then runs persistently slower
     * than real time. On an oversubscribed CI runner that came to a third of
     * real speed. */
  }

  bel_atomic_store_release(&engine->thread_alive, 0);
  return NULL;
}

/* ------------------------------------------------------------------------ */
/* Public API                                                                */
/* ------------------------------------------------------------------------ */

int32_t bel_abi_version(void) { return BEL_ABI_VERSION; }

const char *bel_version_string(void) { return BEL_VERSION_STRING; }

void bel_config_defaults(bel_config *cfg) {
  if (cfg == NULL) {
    return;
  }
  cfg->sample_rate = BEL_DEFAULT_SAMPLE_RATE;
  cfg->channels = BEL_DEFAULT_CHANNELS;
  cfg->source = BEL_SOURCE_TEST_TONE;
  cfg->block_frames = BEL_DEFAULT_BLOCK_FRAMES;
}

bel_engine *bel_engine_create(const bel_config *cfg) {
  bel_config resolved;
  bel_config_defaults(&resolved);
  if (cfg != NULL) {
    if (cfg->sample_rate != 0) {
      resolved.sample_rate = cfg->sample_rate;
    }
    if (cfg->channels != 0) {
      resolved.channels = cfg->channels;
    }
    if (cfg->block_frames != 0) {
      resolved.block_frames = cfg->block_frames;
    }
    resolved.source = cfg->source;
  }

  if (resolved.channels > BEL_MAX_CHANNELS || resolved.sample_rate < 8000u) {
    return NULL;
  }
  /* Device and file sources are declared in the ABI but not implemented yet.
   * Failing loudly beats silently substituting the test tone and letting
   * somebody believe they are metering their soundcard. */
  if (resolved.source != BEL_SOURCE_SILENCE &&
      resolved.source != BEL_SOURCE_TEST_TONE &&
      resolved.source != BEL_SOURCE_PUSH) {
    return NULL;
  }

  bel_engine *engine = (bel_engine *)calloc(1, sizeof(bel_engine));
  if (engine == NULL) {
    return NULL;
  }
  engine->cfg = resolved;

  engine->block = (float *)calloc(
      (size_t)resolved.block_frames * resolved.channels, sizeof(float));
  if (engine->block == NULL) {
    free(engine);
    return NULL;
  }

  bel_loudness_init(&engine->loudness, resolved.channels, resolved.sample_rate);
  bel_truepeak_init(&engine->truepeak, resolved.channels, resolved.sample_rate);

  bel_clear_measurements(engine);

  /* Publish once before anybody starts, so a UI that paints before start()
   * shows floors rather than a zeroed struct that reads as 0.0 dBFS — which
   * would be full scale on every meter. */
  memcpy(&engine->shared, &engine->staging, sizeof(bel_snapshot));
  memcpy(&engine->front, &engine->staging, sizeof(bel_snapshot));

  return engine;
}

void bel_engine_destroy(bel_engine *engine) {
  if (engine == NULL) {
    return;
  }
  bel_engine_stop(engine);
  free(engine->block);
  free(engine);
}

int32_t bel_engine_start(bel_engine *engine) {
  if (engine == NULL) {
    return BEL_ERR_INVALID_ARGUMENT;
  }
  if (bel_atomic_load_acquire(&engine->thread_alive)) {
    return BEL_ERR_WRONG_STATE;
  }

  if (engine->cfg.source == BEL_SOURCE_PUSH) {
    /* Nothing to start. A pushed source has no clock of its own — the caller
     * is the clock — so spawning a thread here would produce an engine that
     * measured silence in between the caller's pushes. */
    engine->staging.flags |= (uint32_t)BEL_FLAG_RUNNING;
    bel_snapshot_publish(engine);
    return BEL_OK;
  }

  bel_atomic_store_release(&engine->should_run, 1);
  bel_atomic_store_release(&engine->thread_alive, 1);

  const int status =
      bel_thread_start(&engine->thread, bel_analysis_thread, engine);
  if (status != BEL_OK) {
    bel_atomic_store_release(&engine->should_run, 0);
    bel_atomic_store_release(&engine->thread_alive, 0);
    return status;
  }
  return BEL_OK;
}

int32_t bel_engine_stop(bel_engine *engine) {
  if (engine == NULL) {
    return BEL_ERR_INVALID_ARGUMENT;
  }
  if (!bel_atomic_load_acquire(&engine->should_run)) {
    return BEL_OK;
  }

  bel_atomic_store_release(&engine->should_run, 0);
  bel_thread_join(engine->thread);

  engine->staging.flags &= ~(uint32_t)BEL_FLAG_RUNNING;
  bel_snapshot_publish(engine);
  return BEL_OK;
}

int32_t bel_engine_push(bel_engine *engine, const float *interleaved,
                        uint32_t frames) {
  if (engine == NULL || interleaved == NULL) {
    return BEL_ERR_INVALID_ARGUMENT;
  }
  if (engine->cfg.source != BEL_SOURCE_PUSH) {
    return BEL_ERR_WRONG_STATE;
  }
  if (frames == 0) {
    return BEL_OK;
  }

  if (bel_atomic_load_acquire(&engine->reset_pending)) {
    bel_clear_measurements(engine);
    bel_atomic_store_release(&engine->reset_pending, 0);
  }

  bel_analyse(engine, interleaved, frames);
  engine->staging.flags |= (uint32_t)BEL_FLAG_RUNNING;
  bel_snapshot_publish(engine);
  return BEL_OK;
}

void bel_engine_reset(bel_engine *engine) {
  if (engine == NULL) {
    return;
  }
  if (bel_atomic_load_acquire(&engine->thread_alive)) {
    bel_atomic_store_release(&engine->reset_pending, 1);
    return;
  }
  /* Not running: nobody else touches the state, so do it here rather than
   * leaving a request pending that only a later start() would honour. */
  bel_clear_measurements(engine);
  bel_snapshot_publish(engine);
}
