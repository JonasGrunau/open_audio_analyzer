/*
 * bel.h — the entire public ABI of the Bel measurement engine.
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Jonas Grunau
 *
 * This one header is the whole contract. Three very different consumers link
 * against it — the Flutter app (through dart:ffi), the `bel` CLI, and the
 * headless VST3/AU plugin — and none of them may know anything about the
 * others. If a thing is not declared here, it is not part of the engine.
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
#define BEL_ABI_VERSION 4

/* 7.1 is the widest layout the Digital Meter renders, so it is the widest the
 * graph carries. */
#define BEL_MAX_CHANNELS 8

/* Log-spaced spectrum bands published to the UI. Deliberately a *display*
 * resolution, not an FFT size: the analysis window is 4096 points and the
 * transform it is zero-padded into is 16384, but the analyzer only ever draws
 * this many columns, so this is what crosses the boundary. */
#define BEL_SPECTRUM_BANDS 512

/* The frequency range those bands span, log-spaced, at every sample rate.
 *
 * Fixed rather than derived from Nyquist on purpose: an analyser whose axis
 * shifts when you change interfaces is one you cannot compare two readings on.
 * Bands above Nyquist read BEL_DB_FLOOR, which below a 40 kHz sample rate means
 * the top of the display is honestly empty rather than quietly rescaled. */
#define BEL_SPECTRUM_HZ_LOW 20.0f
#define BEL_SPECTRUM_HZ_HIGH 20000.0f

/* Consecutive stereo sample pairs published for the phase scope, oldest first.
 *
 * 1024 is one analysis block at the default settings — about 21 ms — so at
 * 48 kHz the scope shows *every* sample rather than a decimation of them. A
 * goniometer that skips samples still draws a plausible figure, which is
 * exactly why the skipping would never be noticed. */
#define BEL_SCOPE_POINTS 1024

/* Bins in the published short-term loudness distribution, spanning
 * BEL_HISTOGRAM_MIN_LUFS to BEL_HISTOGRAM_MAX_LUFS.
 *
 * Far coarser than the 8000-bin histogram the engine gates and takes
 * percentiles on internally — this one is for drawing, and 0.5 LU is finer than
 * a pixel column on any real display. */
#define BEL_HISTOGRAM_BINS 120
#define BEL_HISTOGRAM_MIN_LUFS (-60.0f)
#define BEL_HISTOGRAM_MAX_LUFS (0.0f)

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

/* Set while the loudness fields of the snapshot are not computed by this build,
 * so the UI can render an em dash instead of a number nobody measured.
 *
 * **This build does not set it** — loudness landed together with the EBU
 * conformance suite that proves it. The flag stays in the ABI and consumers
 * must keep checking it, because it is exactly the mechanism a future build
 * would use to say a measurement is unavailable for some platform or source.
 * An individual reading can still be NaN when it is not yet *defined*:
 * momentary loudness needs 400 ms of signal before it means anything. */
#define BEL_FLAG_LOUDNESS_UNAVAILABLE (1u << 1)

/* Likewise for the spectrum arrays. **This build does not set it** — the FFT
 * landed with the analyser and spectrogram that draw it. Kept in the ABI for
 * the same reason as the flag above: a source that cannot produce a spectrum
 * needs a way to say so. */
#define BEL_FLAG_SPECTRUM_UNAVAILABLE (1u << 2)

/* Audio has been lost since the last reset — see `dropped_frames`. Sticky
 * until reset, because a measurement taken over discarded audio stays
 * questionable long after the drop itself has passed. */
#define BEL_FLAG_OVERRUN (1u << 3)

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

  /* Frames the capture callback had to discard because the analysis thread
   * fell behind, since the last reset.
   *
   * This is not a diagnostic counter. Integrated loudness averages every block
   * since the reset, so a dropped second does not make the reading slightly
   * stale — it makes it an average of a different programme than the one that
   * played. A non-zero value here means the integrated reading cannot be
   * trusted, and the UI has to say so rather than quietly showing it. */
  uint32_t dropped_frames;

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
  /* The most recent FFT frame. Instantaneous, so it is a measurement of a
   * moment rather than an average of several. */
  float spectrum[BEL_SPECTRUM_BANDS];

  /* Peak hold over *every* FFT frame since the last publish, then a 1.5 s hold
   * and a 12 dB/s fall.
   *
   * This is not redundant with a hold the UI could keep itself, and the reason
   * is worth stating: the analyser runs an FFT every hop, and a publish carries
   * only the last one. A hold computed from published frames would therefore
   * miss every transient that landed between them, which is the single thing a
   * peak hold exists to catch. */
  float spectrum_peak[BEL_SPECTRUM_BANDS];

  /* --- Appended in ABI 3 ------------------------------------------------- */
  /* New fields go at the end, so that adding one cannot shift any field a
   * previously compiled consumer already knows the offset of. */

  /* The two percentiles LRA is the difference of, LUFS, and the relative gate
   * they were taken above. Published because a histogram that shows the
   * distribution without showing where the range was drawn from is a picture,
   * not a measurement. NaN together with `lra`. */
  float lra_low;  /* 10th percentile of the gated short-term distribution */
  float lra_high; /* 95th percentile */
  float lra_gate; /* relative gate: ungated mean - 20 LU */
  float reserved3;

  /* Energy balance per spectrum band: -1 entirely left, +1 entirely right, 0
   * centred. Zero for mono, and meaningless for a band with no energy in it —
   * read `spectrum` first and skip bands at the floor, because the pan of
   * silence is not a direction. */
  float spectrum_pan[BEL_SPECTRUM_BANDS];

  /* The last BEL_SCOPE_POINTS stereo frames, interleaved x=left, y=right,
   * oldest first. Raw sample values, **not** rotated into goniometer axes:
   * that rotation is a display choice, and doing it here would bake one
   * module's convention into the ABI every other consumer has to undo. Mono
   * publishes the same value in both, which draws the diagonal it should. */
  float scope[BEL_SCOPE_POINTS * 2];

  /* Fraction of the gated short-term blocks that fell in each bin, so the bins
   * sum to 1 and the UI needs no total. All zero before the first gated block
   * exists. */
  float histogram[BEL_HISTOGRAM_BINS];
} bel_snapshot;

/* ------------------------------------------------------------------------ */
/* Configuration                                                             */
/* ------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------ */
/* Devices                                                                    */
/* ------------------------------------------------------------------------ */

#define BEL_DEVICE_ID_MAX 256
#define BEL_DEVICE_NAME_MAX 256

typedef struct bel_device_info {
  /* Opaque, platform-specific, and stable enough to store in a preset. Pass it
   * back in bel_config.device_id. */
  char id[BEL_DEVICE_ID_MAX];

  /* What to show a human. */
  char name[BEL_DEVICE_NAME_MAX];

  uint32_t channels;
  uint32_t sample_rate;

  /* Non-zero when this is the system's default capture device. */
  uint32_t is_default;

  /* Non-zero when this device captures the system's own output rather than a
   * physical input. Only WASAPI provides this natively; on macOS and Linux a
   * virtual loopback device appears as an ordinary input and cannot be
   * distinguished, so this stays zero there. Do not use it to decide whether
   * loopback is *possible* — only to label a device that certainly is. */
  uint32_t is_loopback;
} bel_device_info;

typedef struct bel_device_list bel_device_list;

/* Enumerates capture devices. Returns NULL if the audio backend is
 * unavailable, which is a normal outcome on a headless machine and not an
 * error worth crashing over. Free with bel_device_list_free. */
BEL_API bel_device_list *bel_devices_enumerate(void);
BEL_API uint32_t bel_device_list_count(const bel_device_list *list);
BEL_API const bel_device_info *bel_device_list_at(const bel_device_list *list,
                                                  uint32_t index);
BEL_API void bel_device_list_free(bel_device_list *list);

typedef struct bel_config {
  /* For the synthetic and pushed sources these are binding. For
   * BEL_SOURCE_DEVICE they are ignored: the engine adopts whatever format the
   * hardware produces, because resampling in front of a measurement changes
   * the measurement. Read the actual values back from the snapshot. */
  uint32_t sample_rate; /* 0 asks the source to pick */
  uint32_t channels;    /* 1..BEL_MAX_CHANNELS */

  uint32_t source;       /* bel_source_kind */
  uint32_t block_frames; /* analysis block size; 0 selects a sane default */

  /* Which capture device, for BEL_SOURCE_DEVICE. NULL means the system
   * default. Copied during bel_engine_create; the caller need not keep it. */
  const char *device_id;
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
 * of the snapshot — about 15 kB, most of it the scope and the spectrum — and a
 * second atomic load to confirm no writer intervened. It never blocks the
 * analysis thread and it never waits on a mutex.
 *
 * Fifteen kilobytes at 120 fps is under 2 MB/s and roughly a microsecond a
 * frame, which is the argument for copying the whole thing rather than growing
 * a second, narrower path for the modules that only want one number. Two ways
 * to read a measurement is two ways for them to disagree.
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
BEL_API const float *bel_snapshot_spectrum_pan(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_scope(const bel_snapshot *snapshot);
BEL_API const float *bel_snapshot_histogram(const bel_snapshot *snapshot);

/* ------------------------------------------------------------------------ */
/* Files                                                                     */
/* ------------------------------------------------------------------------ */

/*
 * Decoding a file into blocks of samples, for offline analysis.
 *
 * There is deliberately no `bel_analyse_file()` here. The caller opens a file,
 * creates a BEL_SOURCE_PUSH engine configured to match it, and loops: read a
 * block, push it, read the snapshot. That is more code at the call site than a
 * single function would be, and it buys two things worth more than the
 * brevity.
 *
 * The first is that offline analysis is not a second implementation. It runs
 * the identical `bel_analyse` over identical buffers, so "the offline number
 * equals the realtime number" is true by construction rather than by
 * inspection — which is the whole argument for trusting a file report.
 *
 * The second is progress and cancellation. An hour of audio takes seconds to
 * analyse, and a one-shot call would own those seconds with no way to report
 * how far it had got or to be told to stop. The loop belongs to the caller
 * because the user interface belongs to the caller.
 *
 * **Push in blocks, not in one call.** The gated loudness measurements are
 * sample-accurate and genuinely independent of block size, but RMS, crest and
 * the VU ballistics are computed per pushed block — pushing an entire file at
 * once yields one RMS reading averaged over the whole programme and a VU
 * needle that moves exactly once. Use the engine's configured `block_frames`
 * and the offline readings match the realtime ones.
 */

typedef enum {
  BEL_FILE_FORMAT_UNKNOWN = 0,
  BEL_FILE_FORMAT_WAV = 1,  /* RIFF or RIFX */
  BEL_FILE_FORMAT_AIFF = 2,
  BEL_FILE_FORMAT_RF64 = 3, /* RIFF's 64-bit successor, for files over 4 GB */
  BEL_FILE_FORMAT_W64 = 4,  /* Sony Wave64 */
  BEL_FILE_FORMAT_FLAC = 5,
  BEL_FILE_FORMAT_MP3 = 6
} bel_file_format;

typedef struct bel_file_info {
  uint32_t sample_rate;
  uint32_t channels;

  /* Total frames in the file, or 0 when the decoder could not determine it.
   * Zero means unknown, never empty: treat it as an indeterminate length
   * rather than as a file with nothing in it. */
  uint64_t frames;

  /* frames / sample_rate. Zero when `frames` is unknown. */
  double duration_seconds;

  uint32_t format; /* bel_file_format */

  /* Bits per sample in the source encoding, or 0 for a lossy format where the
   * question has no answer. Reported so a file report can describe its input;
   * the samples themselves always arrive as float regardless. */
  uint32_t bits_per_sample;
} bel_file_info;

typedef struct bel_file bel_file;

/*
 * Opens `path`, a UTF-8 filename, and identifies its format. Returns NULL if
 * the file cannot be read or is not a format this build decodes — which is a
 * normal outcome for a user dropping an arbitrary file on the window, not an
 * error worth crashing over. Close with bel_file_close.
 *
 * The file is reported at its own sample rate and channel count, and nothing
 * resamples or remixes it: resampling in front of a measurement changes the
 * measurement. Configure the engine from bel_file_get_info rather than the
 * other way round. A file with more than BEL_MAX_CHANNELS channels opens
 * successfully and reports its true channel count, so that the caller can say
 * what it found instead of guessing; the engine will refuse it.
 */
BEL_API bel_file *bel_file_open(const char *path);

BEL_API int32_t bel_file_get_info(const bel_file *file, bel_file_info *out);

/*
 * Reads up to `frames` frames of interleaved float samples into `interleaved`,
 * which must have room for `frames * channels` floats. Returns the number of
 * frames actually read; 0 means end of file.
 *
 * Sample values are not clamped. A float WAV may legitimately contain values
 * outside ±1.0, and clamping them here would destroy exactly the overshoots
 * true-peak metering exists to find.
 */
BEL_API uint64_t bel_file_read(bel_file *file, float *interleaved,
                               uint64_t frames);

/*
 * Seeks to `frame`. Returns BEL_ERR_UNSUPPORTED if the decoder could not seek,
 * which some malformed or streamed files will do.
 *
 * Analysis never uses this — an integrating measurement over a file that was
 * seeked through is a measurement of a programme nobody played. It exists for
 * a future waveform view that needs to read a region without re-reading the
 * whole file.
 */
BEL_API int32_t bel_file_seek(bel_file *file, uint64_t frame);

BEL_API void bel_file_close(bel_file *file);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* BEL_H */
