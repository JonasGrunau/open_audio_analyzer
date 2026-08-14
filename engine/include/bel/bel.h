/*
 * bel.h — the entire public ABI of the Bel measurement engine.
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Jonas Grunau
 *
 * This one header is the whole contract. Three very different consumers link
 * against it — the Flutter app (through dart:ffi), the `bel` CLI, and the CLAP
 * plugin — and none of them may know anything about the others. If a thing is
 * not declared here, it is not part of the engine.
 *
 * ---------------------------------------------------------------------------
 * Why the API is shaped like this
 *
 * The UI must read measurements once per display frame, on the thread that is
 * about to paint, without allocating, without locking, and without blocking.
 * That single requirement produced every design decision below:
 *
 *   - There is no callback into the consumer. Callbacks from an audio thread
 *     into a garbage-collected runtime are how you get frame drops.
 *   - There is no "get me the current LUFS" accessor. One call per value would
 *     mean dozens of FFI transitions per frame, and worse, values read at
 *     different instants would disagree with each other on screen.
 *   - Instead the engine owns a single `bel_snapshot` at a *fixed address* for
 *     its whole lifetime. `bel_snapshot_acquire` refreshes it, and it is the
 *     only function on the per-frame path.
 *
 * The fixed address matters more than it looks: it lets Dart build typed views
 * over the arrays exactly once, at startup, and reuse them for every frame
 * thereafter. A moving buffer would force a new view allocation per frame,
 * which is precisely the garbage this design exists to avoid.
 *
 * ---------------------------------------------------------------------------
 * Threading contract
 *
 *   bel_engine_create/destroy/start/stop/reset   — one thread, the owner's.
 *   bel_snapshot_acquire                         — any single reader thread,
 *                                                  concurrently with the
 *                                                  engine's internal threads.
 *
 * Two threads calling `bel_snapshot_acquire` on the same engine is undefined.
 * Everything else the engine does internally is its own problem.
 */

#ifndef BEL_H
#define BEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define BEL_API __declspec(dllexport)
#elif defined(__GNUC__)
#  define BEL_API __attribute__((visibility("default")))
#else
#  define BEL_API
#endif

/* Bumped whenever this header changes in a way that breaks callers. The Dart
 * side asserts against it at startup, because a stale prebuilt library that
 * silently reads a reordered struct produces plausible-looking wrong numbers,
 * which is the worst failure mode a measurement tool has. */
#define BEL_ABI_VERSION 1

/* 7.1 is the widest layout the Digital Meter renders, so it is the widest the
 * graph carries. */
#define BEL_MAX_CHANNELS 8

/* Log-spaced spectrum bands published to the UI. Deliberately a *display*
 * resolution, not an FFT size: the FFT may be 8192 points, but the analyzer
 * only ever draws this many columns, so this is what crosses the boundary. */
#define BEL_SPECTRUM_BANDS 512

/* The floor every dB quantity clamps to, chosen a little below the noise floor
 * of 24-bit audio. Real -INFINITY is avoided deliberately: differences of dB
 * values are meaningful quantities here (crest is peak minus RMS), and
 * -inf minus -inf is NaN, which would turn a silent passage into "no data". */
#define BEL_DB_FLOOR (-144.0f)

/* ------------------------------------------------------------------------ */
/* Status codes                                                              */
/* ------------------------------------------------------------------------ */

typedef enum {
  BEL_OK = 0,
  BEL_ERR_INVALID_ARGUMENT = -1,
  BEL_ERR_OUT_OF_MEMORY = -2,
  BEL_ERR_WRONG_STATE = -3,
  BEL_ERR_THREAD = -4,
  BEL_ERR_UNSUPPORTED = -5
} bel_status;

/* ------------------------------------------------------------------------ */
/* Signal sources                                                            */
/* ------------------------------------------------------------------------ */

typedef enum {
  /* Digital black. Useful for asserting that the meters actually fall to their
   * floor rather than freezing at their last value. */
  BEL_SOURCE_SILENCE = 0,

  /* An internally generated test signal. This is not a toy: it is how the
   * render path is benchmarked without an audio device attached, and how CI
   * exercises the engine on machines that have no sound hardware at all. */
  BEL_SOURCE_TEST_TONE = 1,

  /* A hardware or loopback capture device. Phase 1. */
  BEL_SOURCE_DEVICE = 2,

  /* Decoded from a file, driven as fast as the CPU allows. Phase 5. */
  BEL_SOURCE_FILE = 3,

  /* The caller supplies the audio, synchronously, via bel_engine_push().
   *
   * No thread is started and nothing is paced against a clock: a push returns
   * once the block has been measured. That makes the engine a pure function of
   * the samples it was given, which is what lets the conformance suite feed it
   * a signal it constructed and assert on the result — no device, no timing,
   * no flakiness. It is also the shape file analysis needs, so Phase 5 decodes
   * into this rather than growing a second path. */
  BEL_SOURCE_PUSH = 4
} bel_source_kind;

/* ------------------------------------------------------------------------ */
/* Snapshot flags                                                            */
/* ------------------------------------------------------------------------ */

#define BEL_FLAG_RUNNING (1u << 0)

/* Set while the loudness fields of the snapshot are not yet computed by this
 * build. It exists so the UI can render "—" instead of a number nobody
 * measured. A meter that displays a placeholder as though it were a reading is
 * worse than a meter that displays nothing, so this flag is checked, not
 * assumed. Cleared in Phase 1, when the fields land together with the EBU
 * conformance suite that proves them. */
#define BEL_FLAG_LOUDNESS_UNAVAILABLE (1u << 1)

/* Likewise for the spectrum arrays, which stay at BEL_DB_FLOOR until the FFT
 * lands in Phase 1. */
#define BEL_FLAG_SPECTRUM_UNAVAILABLE (1u << 2)

/* ------------------------------------------------------------------------ */
/* The snapshot                                                              */
/* ------------------------------------------------------------------------ */

/*
 * Everything the UI is allowed to draw, as one flat plain-old-data struct.
 *
 * Field values are in the units named in each comment. dB values use -INFINITY
 * for true digital silence. A field the current build does not compute is NaN,
 * never zero — zero is a legitimate reading for correlation, balance and
 * several dB quantities, so it cannot double as "no data".
 *
 * Layout rules, because dart:ffi reproduces this struct byte for byte:
 *   - No pointers. No bitfields. No `bool`. Fixed-size arrays only.
 *   - Widest members first, so natural alignment introduces no padding that
 *     differs between compilers.
 *   - The `reserved` members are explicit padding, named rather than left to
 *     the compiler so that adding a float later does not shift every field
 *     after it. They are public because a leading underscore would make the
 *     generated Dart bindings private and trip the unused-field lint.
 *   - Append new fields at the end, and bump BEL_ABI_VERSION when you do.
 */
typedef struct bel_snapshot {
  /* Increments every time the analysis thread publishes. The reader uses it to
   * skip repainting when nothing has changed — at 120 fps against a ~47 Hz
   * measurement rate, most frames have nothing new to say. */
  uint64_t generation;

  /* Seconds of signal measured since the last reset. Not wall-clock time: with
   * a file source this advances far faster than real time, and that is the
   * point. */
  double elapsed_seconds;

  uint32_t sample_rate;
  uint32_t channels;
  uint32_t flags; /* BEL_FLAG_* */
  uint32_t reserved0;

  /* --- Loudness, ITU-R BS.1770-4 / EBU R128, in LUFS ------------------- */
  float lufs_momentary;  /* 400 ms window */
  float lufs_short;      /* 3 s window */
  float lufs_integrated; /* gated, since reset */
  float lra;             /* loudness range, LU */

  /* --- Peaks, dBFS (sample) and dBTP (true peak) ----------------------- */
  float true_peak;       /* max over a 3 s sliding window */
  float true_peak_max;   /* max since reset */
  float sample_peak_max; /* max since reset */
  float reserved1;

  /* --- Dynamics -------------------------------------------------------- */
  /* Bel does not implement Decibel's "TrueDyn": it is proprietary and
   * undocumented, so any claim of parity would be a guess dressed as a
   * measurement. These are defined in docs/METRICS.md and reproducible from
   * the definition. */
  float dr_short;       /* true_peak - lufs_short,      LU */
  float dr_integrated;  /* true_peak_max - lufs_integrated, LU */
  float crest;          /* sample peak - RMS,           dB */
  float plr;            /* peak to loudness ratio,      LU */
  float psr;            /* peak to short-term ratio,    LU */
  float reserved2;

  /* --- Stereo field ---------------------------------------------------- */
  float correlation; /* -1 fully out of phase .. +1 mono */
  float balance;     /* -1 hard left .. +1 hard right */

  /* --- Per channel ------------------------------------------------------ */
  float peak[BEL_MAX_CHANNELS];    /* dBFS, with the meter's hold applied */
  float rms[BEL_MAX_CHANNELS];     /* dBFS, with the meter's decay applied */
  float vu[BEL_MAX_CHANNELS];      /* VU, 300 ms ballistics, 0 VU = calibration */
  uint32_t clip[BEL_MAX_CHANNELS]; /* consecutive full-scale samples seen */

  /* --- Spectrum, dBFS per log-spaced band ------------------------------- */
  float spectrum[BEL_SPECTRUM_BANDS];
  float spectrum_peak[BEL_SPECTRUM_BANDS];
} bel_snapshot;

/* ------------------------------------------------------------------------ */
/* Configuration                                                             */
/* ------------------------------------------------------------------------ */

typedef struct bel_config {
  uint32_t sample_rate; /* 0 asks the source to pick */
  uint32_t channels;    /* 1..BEL_MAX_CHANNELS */
  uint32_t source;      /* bel_source_kind */
  uint32_t block_frames;/* analysis block size; 0 selects a sane default */
} bel_config;

typedef struct bel_engine bel_engine;

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                 */
/* ------------------------------------------------------------------------ */

BEL_API int32_t bel_abi_version(void);
BEL_API const char *bel_version_string(void);

/* Fills `cfg` with defaults. Call this before overriding fields, so that
 * adding a field to bel_config does not silently leave it at zero in every
 * existing caller. */
BEL_API void bel_config_defaults(bel_config *cfg);

BEL_API bel_engine *bel_engine_create(const bel_config *cfg);
BEL_API void bel_engine_destroy(bel_engine *engine);

BEL_API int32_t bel_engine_start(bel_engine *engine);
BEL_API int32_t bel_engine_stop(bel_engine *engine);

/* Clears every integrating measurement — integrated loudness, LRA, all the
 * "max since reset" peaks, the clip counters — and restarts the elapsed clock.
 * Momentary values are left alone; they describe the signal, not the session. */
BEL_API void bel_engine_reset(bel_engine *engine);

/* ------------------------------------------------------------------------ */
/* The per-frame path                                                        */
/* ------------------------------------------------------------------------ */

/*
 * The stable address of this engine's snapshot. Valid from create() until
 * destroy(), and it never moves. Call it once and keep the pointer; the
 * contents are only meaningful after bel_snapshot_acquire().
 */
BEL_API const bel_snapshot *bel_snapshot_buffer(bel_engine *engine);

/*
 * Refresh the snapshot from the analysis thread and return its generation.
 *
 * This is the only function called every frame, so it is the only one whose
 * cost is worth arguing about. It is a seqlock read: an atomic load, a memcpy
 * of a few kilobytes, and a second atomic load to confirm no writer intervened.
 * It never blocks the analysis thread and it never waits on a mutex.
 *
 * Returns the same value as the previous call when nothing new was published,
 * which is the caller's cue to skip repainting.
 */
BEL_API uint64_t bel_snapshot_acquire(bel_engine *engine);

/* ------------------------------------------------------------------------ */
/* Pushing audio                                                             */
/* ------------------------------------------------------------------------ */

/*
 * Measure `frames` frames of interleaved float audio and publish the result.
 *
 * Only valid when the engine was created with BEL_SOURCE_PUSH; anything else
 * returns BEL_ERR_WRONG_STATE rather than quietly mixing pushed audio into a
 * stream that a device is already driving.
 *
 * Synchronous: on return the snapshot reflects these samples. Any block size is
 * accepted, and the measurements do not depend on it — the 400 ms and 3 s
 * windows are counted in samples internally, so pushing an hour in one call and
 * pushing it in 512-frame chunks produce identical readings. The conformance
 * suite relies on exactly that.
 */
BEL_API int32_t bel_engine_push(bel_engine *engine, const float *interleaved,
                                uint32_t frames);

/* ------------------------------------------------------------------------ */
/* Array addresses                                                           */
/* ------------------------------------------------------------------------ */

/*
 * The address of each array field inside a snapshot.
 *
 * These exist so that a consumer can build a typed view over the arrays
 * without knowing their byte offsets. dart:ffi can read the scalars through a
 * generated struct definition perfectly well, but the array fields need to
 * reach the canvas as a flat Float32List — `Canvas.drawRawPoints` and
 * `Vertices.raw` take one directly, and going through per-element accessors
 * instead would put 512 bounds-checked loads on the paint path where a single
 * pointer would do.
 *
 * Asking the compiler for the offset rather than computing it in Dart is the
 * whole point. A struct layout that differs between the compiler that built
 * the library and the assumptions baked into the bindings does not crash — it
 * reads the wrong field and displays a plausible number, which is the failure
 * mode this project can least afford.
 *
 * Call once, at startup, and keep the views: the snapshot never moves.
 */
BEL_API const float *bel_snapshot_peak(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_rms(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_vu(const bel_snapshot *snapshot);
BEL_API const uint32_t *bel_snapshot_clip(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_spectrum(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_spectrum_peak(const bel_snapshot *snapshot);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* BEL_H */
