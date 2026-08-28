/*
 * oaa.h — the entire public ABI of the Open Audio Analyzer measurement engine.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (c) 2026 Jonas Grunau
 *
 * This one header is the whole contract. Three very different consumers link
 * against it — the Flutter app (through dart:ffi), the `oaa` CLI, and the
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
 *   - Instead the engine owns a single `oaa_snapshot` at a *fixed address* for
 *     its whole lifetime. `oaa_snapshot_acquire` refreshes it, and it is the
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
 *   oaa_engine_create/destroy/start/stop/reset   — one thread, the owner's.
 *   oaa_snapshot_acquire                         — any single reader thread,
 *                                                  concurrently with the
 *                                                  engine's internal threads.
 *
 * Two threads calling `oaa_snapshot_acquire` on the same engine is undefined.
 * Everything else the engine does internally is its own problem.
 */

#ifndef OAA_H
#define OAA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define OAA_API __declspec(dllexport)
#elif defined(__GNUC__)
#  define OAA_API __attribute__((visibility("default")))
#else
#  define OAA_API
#endif

/* Bumped whenever this header changes in a way that breaks callers. The Dart
 * side asserts against it at startup, because a stale prebuilt library that
 * silently reads a reordered struct produces plausible-looking wrong numbers,
 * which is the worst failure mode a measurement tool has. */
#define OAA_ABI_VERSION 5

/* 7.1 is the widest layout the Digital Meter renders, so it is the widest the
 * graph carries. */
#define OAA_MAX_CHANNELS 8

/* Log-spaced spectrum bands published to the UI. Deliberately a *display*
 * resolution, not an FFT size: the analysis window is 4096 points and the
 * transform it is zero-padded into is 16384, but the analyzer only ever draws
 * this many columns, so this is what crosses the boundary. */
#define OAA_SPECTRUM_BANDS 512

/* The frequency range those bands span, log-spaced, at every sample rate.
 *
 * Fixed rather than derived from Nyquist on purpose: an analyser whose axis
 * shifts when you change interfaces is one you cannot compare two readings on.
 * Bands above Nyquist read OAA_DB_FLOOR, which below a 40 kHz sample rate means
 * the top of the display is honestly empty rather than quietly rescaled. */
#define OAA_SPECTRUM_HZ_LOW 20.0f
#define OAA_SPECTRUM_HZ_HIGH 20000.0f

/* Consecutive stereo sample pairs published for the phase scope, oldest first.
 *
 * 1024 is one analysis block at the default settings — about 21 ms — so at
 * 48 kHz the scope shows *every* sample rather than a decimation of them. A
 * goniometer that skips samples still draws a plausible figure, which is
 * exactly why the skipping would never be noticed. */
#define OAA_SCOPE_POINTS 1024

/* Bins in the published short-term loudness distribution, spanning
 * OAA_HISTOGRAM_MIN_LUFS to OAA_HISTOGRAM_MAX_LUFS.
 *
 * Far coarser than the 8000-bin histogram the engine gates and takes
 * percentiles on internally — this one is for drawing, and 0.5 LU is finer than
 * a pixel column on any real display. */
#define OAA_HISTOGRAM_BINS 120
#define OAA_HISTOGRAM_MIN_LUFS (-60.0f)
#define OAA_HISTOGRAM_MAX_LUFS (0.0f)

/* The floor every dB quantity clamps to, chosen a little below the noise floor
 * of 24-bit audio. Real -INFINITY is avoided deliberately: differences of dB
 * values are meaningful quantities here (crest is peak minus RMS), and
 * -inf minus -inf is NaN, which would turn a silent passage into "no data". */
#define OAA_DB_FLOOR (-144.0f)

/* ------------------------------------------------------------------------ */
/* Status codes                                                              */
/* ------------------------------------------------------------------------ */

typedef enum {
  OAA_OK = 0,
  OAA_ERR_INVALID_ARGUMENT = -1,
  OAA_ERR_OUT_OF_MEMORY = -2,
  OAA_ERR_WRONG_STATE = -3,
  OAA_ERR_THREAD = -4,
  OAA_ERR_UNSUPPORTED = -5
} oaa_status;

/* ------------------------------------------------------------------------ */
/* Signal sources                                                            */
/* ------------------------------------------------------------------------ */

typedef enum {
  /* Digital black. Useful for asserting that the meters actually fall to their
   * floor rather than freezing at their last value. */
  OAA_SOURCE_SILENCE = 0,

  /* An internally generated test signal. This is not a toy: it is how the
   * render path is benchmarked without an audio device attached, and how CI
   * exercises the engine on machines that have no sound hardware at all. */
  OAA_SOURCE_TEST_TONE = 1,

  /* A hardware or loopback capture device. Phase 1. */
  OAA_SOURCE_DEVICE = 2,

  /* Reserved, and refused by oaa_engine_create. File analysis does not use a
   * source of its own: the caller opens an oaa_file, creates an
   * OAA_SOURCE_PUSH engine to match it, and pushes the blocks it decodes. That
   * is what makes offline analysis the same `oaa_analyse` over the same buffers
   * as realtime rather than a second path. The value stays allocated so that
   * nothing else claims 3. */
  OAA_SOURCE_FILE = 3,

  /* The caller supplies the audio, synchronously, via oaa_engine_push().
   *
   * No thread is started and nothing is paced against a clock: a push returns
   * once the block has been measured. That makes the engine a pure function of
   * the samples it was given, which is what lets the conformance suite feed it
   * a signal it constructed and assert on the result — no device, no timing,
   * no flakiness. It is also the shape file analysis needs, so Phase 5 decodes
   * into this rather than growing a second path. */
  OAA_SOURCE_PUSH = 4
} oaa_source_kind;

/* ------------------------------------------------------------------------ */
/* Snapshot flags                                                            */
/* ------------------------------------------------------------------------ */

#define OAA_FLAG_RUNNING (1u << 0)

/* Set while the loudness fields of the snapshot are not computed by this build,
 * so the UI can render an em dash instead of a number nobody measured.
 *
 * **This build does not set it** — loudness landed together with the EBU
 * conformance suite that proves it. The flag stays in the ABI and consumers
 * must keep checking it, because it is exactly the mechanism a future build
 * would use to say a measurement is unavailable for some platform or source.
 * An individual reading can still be NaN when it is not yet *defined*:
 * momentary loudness needs 400 ms of signal before it means anything. */
#define OAA_FLAG_LOUDNESS_UNAVAILABLE (1u << 1)

/* Likewise for the spectrum arrays — but unlike the flag above, **this build
 * sets it**. `oaa_clear_measurements` raises it on every reset and the analysis
 * pass clears it only once a full 4096-frame window has been transformed, about
 * 85 ms in. Until then the bands sit at the floor, which is indistinguishable
 * from digital silence: a consumer that skips this check draws a spectrum of
 * nothing and presents it as a measurement. It stays in the ABI for the flag
 * above's reason as well — a source that cannot produce a spectrum at all needs
 * a way to say so. */
#define OAA_FLAG_SPECTRUM_UNAVAILABLE (1u << 2)

/* Audio has been lost since the last reset — see `dropped_frames`. Sticky
 * until reset, because a measurement taken over discarded audio stays
 * questionable long after the drop itself has passed. */
#define OAA_FLAG_OVERRUN (1u << 3)

/* The capture source has stopped producing, and will not start again by
 * itself.
 *
 * A producer that stops is otherwise completely invisible, which is the whole
 * reason this bit exists. The analysis thread paces itself against a monotonic
 * clock, not against the audio, so it goes on publishing at the same ~47 Hz
 * with an empty ring: every meter holds its last value, `generation` keeps
 * incrementing, and nothing anywhere says why. Pressing reset then clears the
 * meters to their floors and they sit *there* instead, which reads as an engine
 * that has died rather than as a source that has left — and the only way out
 * was to select a different source, which happens to rebuild the engine.
 *
 * This is not a statement about the signal. A source producing digital silence
 * is running, and meters at their floor are the correct reading for it; this
 * bit says that no audio is arriving at all. The engine puts such a source back
 * itself where it can (see `oaa_device_revive`) and leaves the bit set only for
 * what it cannot fix from the inside: a device that was unplugged, or one whose
 * sample rate or channel count changed underneath a DSP graph that was sized
 * for the old one. Reopening the source is the consumer's move then, because
 * adopting a new format means rebuilding everything derived from it.
 *
 * Live rather than sticky, unlike OAA_FLAG_OVERRUN: it describes the source's
 * state right now, and the audio the stall cost is reported where every other
 * kind of lost audio is, in `dropped_frames`.
 *
 * Set only for OAA_SOURCE_DEVICE. No other source has a producer that can
 * leave. */
#define OAA_FLAG_SOURCE_STOPPED (1u << 4)

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
 *   - Append new fields at the end, and bump OAA_ABI_VERSION when you do.
 */
typedef struct oaa_snapshot {
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
  uint32_t flags; /* OAA_FLAG_* */

  /* Frames of audio that never reached the measurement, since the last reset.
   *
   * This is not a diagnostic counter. Integrated loudness averages every block
   * since the reset, so a lost second does not make the reading slightly stale
   * — it makes it an average of a different programme than the one that played.
   * A non-zero value here means the integrated reading cannot be trusted, and
   * the UI has to say so rather than quietly showing it.
   *
   * Two things land here, because to a measurement they are the same event.
   * Frames the capture callback had to discard because the analysis thread fell
   * behind are counted exactly, by the ring that refused them. Frames missed
   * while the source was stopped (OAA_FLAG_SOURCE_STOPPED) are counted from the
   * analysis clock instead, so they are approximate — to within the one block
   * it takes to notice — because a producer that has gone away is not there to
   * tell anyone what it did not produce. Approximate is the point: the number
   * exists to prove audio was lost, and a gap reported as zero is a gap the
   * user never hears about. */
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
  /* Open Dynamic Range — ODR-S and ODR-I in the application: true peak over a
   * window minus the loudness of the same window, in LU. Defined in
   * docs/METRICS.md and reproducible from the definition; the same arithmetic
   * as the PSR and PLR of AES TD1004, with the operands that note leaves open
   * pinned down. Decibel's "TrueDyn" is, by process.audio's own description,
   * most probably the same pair; it is not documented as one, so these are
   * published under their own name and claim no parity. The field names below
   * predate the name and stay, because the layout is what a consumer links.
   *
   * dr_short is NaN while short-term loudness is at or below the absolute
   * gate (-70 LUFS): silence and noise floor have no dynamics to report, and
   * the dB floor would otherwise make them read 0 LU. dr_integrated is NaN
   * for as long as lufs_integrated is, which is the same line — but its peak
   * is gated by nothing: true_peak_max counts a transient in a block the
   * loudness gate excluded, because a converter will see it. The engine
   * publishes no minimum of dr_short; a file report and the Validator each
   * take their own over what they read. */
  float dr_short;       /* true_peak - lufs_short,      LU */
  float dr_integrated;  /* true_peak_max - lufs_integrated, LU */

  /* Crest factor in dB: sample peak minus RMS, both taken over the block just
   * measured — not the held peak and the smoothed RMS the meters draw. Those
   * settle at different rates, so their difference drifts on its own: it read
   * 11.6 dB for a block of DC, where the answer is 0. A sine is 3.0103 dB.
   * Multichannel reports the peakiest channel. */
  float crest;

  /* plr equals dr_integrated and psr equals dr_short, exactly, always. Both
   * spellings are in common use, so both are published, from one expression
   * each so they cannot drift. Do not offer all four to a user as distinct
   * measurements. */
  float plr;            /* peak to loudness ratio,      LU */
  float psr;            /* peak to short-term ratio,    LU */
  float reserved2;

  /* --- Stereo field ---------------------------------------------------- */
  float correlation; /* -1 fully out of phase .. +1 mono */
  float balance;     /* -1 hard left .. +1 hard right */

  /* --- Per channel ------------------------------------------------------ */
  float peak[OAA_MAX_CHANNELS];    /* dBFS, with the meter's hold applied */
  float rms[OAA_MAX_CHANNELS];     /* dBFS, with the meter's decay applied */
  float vu[OAA_MAX_CHANNELS];      /* VU, 300 ms ballistics, 0 VU = calibration */

  /* The longest run of consecutive full-scale samples since the last reset —
   * latched, not live. A live run is zeroed by the next sample below full
   * scale, so a publish would carry whatever it happened to be at the block
   * boundary and every clip that ended mid-block would read zero. Non-zero
   * here means "this channel clipped, and the worst run was this long"; it
   * stays non-zero until oaa_engine_reset. */
  uint32_t clip[OAA_MAX_CHANNELS];

  /* --- Spectrum, dBFS per log-spaced band ------------------------------- */
  /* The most recent FFT frame. Instantaneous, so it is a measurement of a
   * moment rather than an average of several. */
  float spectrum[OAA_SPECTRUM_BANDS];

  /* Peak hold over *every* FFT frame since the last publish, then a 1.5 s hold
   * and a 12 dB/s fall.
   *
   * This is not redundant with a hold the UI could keep itself, and the reason
   * is worth stating: the analyser runs an FFT every hop, and a publish carries
   * only the last one. A hold computed from published frames would therefore
   * miss every transient that landed between them, which is the single thing a
   * peak hold exists to catch. */
  float spectrum_peak[OAA_SPECTRUM_BANDS];

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
  float spectrum_pan[OAA_SPECTRUM_BANDS];

  /* The last OAA_SCOPE_POINTS stereo frames, interleaved x=left, y=right,
   * oldest first. Raw sample values, **not** rotated into goniometer axes:
   * that rotation is a display choice, and doing it here would bake one
   * module's convention into the ABI every other consumer has to undo. Mono
   * publishes the same value in both, which draws the diagonal it should. */
  float scope[OAA_SCOPE_POINTS * 2];

  /* Fraction of the gated short-term blocks that fell in each bin, so the bins
   * sum to 1 and the UI needs no total. All zero before the first gated block
   * exists. */
  float histogram[OAA_HISTOGRAM_BINS];
} oaa_snapshot;

/* ------------------------------------------------------------------------ */
/* Configuration                                                             */
/* ------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------ */
/* Devices                                                                    */
/* ------------------------------------------------------------------------ */

#define OAA_DEVICE_ID_MAX 256
#define OAA_DEVICE_NAME_MAX 256

/*
 * The one device id that is not a backend's own.
 *
 * Every other id is the opaque bytes of a platform device handle, hex-encoded
 * (see oaa_device.c). This one is a reserved word, and the hyphen is what
 * guarantees it can never collide with one: a hex encoding has no hyphens in
 * it. Pass it as oaa_config.device_id to meter the system's own output.
 *
 * Enumeration offers it **only where it can actually work** — macOS 14.2 and
 * later, where a Core Audio process tap captures what is being sent to the
 * default output device with no driver installed and without rerouting the
 * audio away from the speakers. Everywhere else it is absent from the list and
 * refused by oaa_engine_create, because on Windows WASAPI loopback already
 * appears as an ordinary capture device, and on Linux so does a PipeWire or
 * PulseAudio monitor source. See engine/src/oaa_tap.h.
 *
 * It is a stable string rather than a generated id on purpose: it is written
 * into the user's settings file, which this project expects people to read and
 * edit by hand.
 */
#define OAA_DEVICE_ID_SYSTEM_OUTPUT "system-output"

typedef struct oaa_device_info {
  /* Opaque, platform-specific, and stable enough to store in a preset. Pass it
   * back in oaa_config.device_id. */
  char id[OAA_DEVICE_ID_MAX];

  /* What to show a human. */
  char name[OAA_DEVICE_NAME_MAX];

  uint32_t channels;
  uint32_t sample_rate;

  /* Non-zero when this is the system's default capture device. */
  uint32_t is_default;

  /* Non-zero when this device captures the system's own output rather than a
   * physical input.
   *
   * Set for WASAPI's loopback devices, which report it natively, and for the
   * macOS process tap offered under OAA_DEVICE_ID_SYSTEM_OUTPUT, which is one
   * by construction. It stays zero for a *virtual* loopback — BlackHole, a
   * PipeWire monitor — because those are indistinguishable from a real input
   * and reporting a guess would be worse than reporting nothing. So: this
   * labels a device that certainly captures system output, and its absence
   * says nothing about whether some other device in the list also does. */
  uint32_t is_loopback;
} oaa_device_info;

typedef struct oaa_device_list oaa_device_list;

/* Enumerates capture devices. Returns NULL if the audio backend is
 * unavailable, which is a normal outcome on a headless machine and not an
 * error worth crashing over. Free with oaa_device_list_free. */
OAA_API oaa_device_list *oaa_devices_enumerate(void);
OAA_API uint32_t oaa_device_list_count(const oaa_device_list *list);
OAA_API const oaa_device_info *oaa_device_list_at(const oaa_device_list *list,
                                                  uint32_t index);
OAA_API void oaa_device_list_free(oaa_device_list *list);

typedef struct oaa_config {
  /* For the synthetic and pushed sources these are binding. For
   * OAA_SOURCE_DEVICE they are ignored: the engine adopts whatever format the
   * hardware produces, because resampling in front of a measurement changes
   * the measurement. Read the actual values back from the snapshot. */
  uint32_t sample_rate; /* 0 asks the source to pick */
  uint32_t channels;    /* 1..OAA_MAX_CHANNELS */

  uint32_t source;       /* oaa_source_kind */
  uint32_t block_frames; /* analysis block size; 0 selects a sane default */

  /* Which capture device, for OAA_SOURCE_DEVICE. NULL means the system
   * default, and OAA_DEVICE_ID_SYSTEM_OUTPUT means the system's own output
   * where that is offered. Copied during oaa_engine_create; the caller need
   * not keep it. */
  const char *device_id;
} oaa_config;

typedef struct oaa_engine oaa_engine;

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                 */
/* ------------------------------------------------------------------------ */

OAA_API int32_t oaa_abi_version(void);
OAA_API const char *oaa_version_string(void);

/* Fills `cfg` with defaults. Call this before overriding fields, so that
 * adding a field to oaa_config does not silently leave it at zero in every
 * existing caller. */
OAA_API void oaa_config_defaults(oaa_config *cfg);

OAA_API oaa_engine *oaa_engine_create(const oaa_config *cfg);
OAA_API void oaa_engine_destroy(oaa_engine *engine);

OAA_API int32_t oaa_engine_start(oaa_engine *engine);
OAA_API int32_t oaa_engine_stop(oaa_engine *engine);

/* Clears every integrating measurement — integrated loudness, LRA, all the
 * "max since reset" peaks, the clip counters — and restarts the elapsed clock.
 * Momentary values are left alone; they describe the signal, not the session. */
OAA_API void oaa_engine_reset(oaa_engine *engine);

/* Reset automatically when the signal returns after a silence.
 *
 * This is the engine's whole contribution to the LUFS time modes, and it is
 * here rather than above the engine because silence is a property of audio and
 * not of a host: one implementation serves a plugin in a DAW and a sound card
 * both, and two would eventually disagree about when a track began. The three
 * other modes need a playhead, so they are the caller's business — `engine/`
 * does not learn what a DAW is.
 *
 * With this enabled, a block whose highest magnitude is below
 * OAA_SILENCE_FLOOR accumulates towards OAA_SILENCE_HOLD_SECONDS; the first
 * block above the floor once that has expired resets exactly as
 * oaa_engine_reset would, *before* that block is measured. Before rather than
 * after, because a track whose loudest sample is in its first block would
 * otherwise have that peak cleared by its own reset — a true-peak reading that
 * is wrong only for material that opens on a transient, which is most of it.
 *
 * Off by default, and off is what every existing caller wants: file analysis
 * measures a file whole, and a reset in the middle of one would report a
 * different programme than the one that was asked for.
 *
 * Idempotent, and safe to call while running. */
OAA_API void oaa_engine_set_silence_reset(oaa_engine *engine, int32_t enabled);

/* The floor a block's peak magnitude has to stay under to count as silence,
 * and how long it must stay there before the next signal starts a new
 * measurement.
 *
 * -60 dBFS rather than true zero: a DAW that has stopped feeding a plugin
 * sends exact zeroes, but a sound card with nothing playing sends its own noise
 * floor, and a converter idling at -85 dBFS would never once look silent. -60
 * is below anything anybody masters towards and above every idle input this has
 * been run against.
 *
 * Two seconds because it has to outlast a musical gap. A held pause between
 * movements is not the end of the programme, and a measurement that restarted
 * on one would report the second half of a piece as the whole of it. */
#define OAA_SILENCE_FLOOR 0.001f /* -60 dBFS */
#define OAA_SILENCE_HOLD_SECONDS 2.0

/* ------------------------------------------------------------------------ */
/* The per-frame path                                                        */
/* ------------------------------------------------------------------------ */

/*
 * The stable address of this engine's snapshot. Valid from create() until
 * destroy(), and it never moves. Call it once and keep the pointer; the
 * contents are only meaningful after oaa_snapshot_acquire().
 */
OAA_API const oaa_snapshot *oaa_snapshot_buffer(oaa_engine *engine);

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
OAA_API uint64_t oaa_snapshot_acquire(oaa_engine *engine);

/* ------------------------------------------------------------------------ */
/* Pushing audio                                                             */
/* ------------------------------------------------------------------------ */

/*
 * Measure `frames` frames of interleaved float audio and publish the result.
 *
 * Only valid when the engine was created with OAA_SOURCE_PUSH; anything else
 * returns OAA_ERR_WRONG_STATE rather than quietly mixing pushed audio into a
 * stream that a device is already driving.
 *
 * Synchronous: on return the snapshot reflects these samples. Any block size is
 * accepted, and the measurements do not depend on it — the 400 ms and 3 s
 * windows are counted in samples internally, so pushing an hour in one call and
 * pushing it in 512-frame chunks produce identical readings. The conformance
 * suite relies on exactly that.
 */
OAA_API int32_t oaa_engine_push(oaa_engine *engine, const float *interleaved,
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
OAA_API const float *oaa_snapshot_peak(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_rms(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_vu(const oaa_snapshot *snapshot);
OAA_API const uint32_t *oaa_snapshot_clip(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_spectrum(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_spectrum_peak(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_spectrum_pan(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_scope(const oaa_snapshot *snapshot);
OAA_API const float *oaa_snapshot_histogram(const oaa_snapshot *snapshot);

/* ------------------------------------------------------------------------ */
/* Files                                                                     */
/* ------------------------------------------------------------------------ */

/*
 * Decoding a file into blocks of samples, for offline analysis.
 *
 * There is deliberately no `oaa_analyse_file()` here. The caller opens a file,
 * creates a OAA_SOURCE_PUSH engine configured to match it, and loops: read a
 * block, push it, read the snapshot. That is more code at the call site than a
 * single function would be, and it buys two things worth more than the
 * brevity.
 *
 * The first is that offline analysis is not a second implementation. It runs
 * the identical `oaa_analyse` over identical buffers, so "the offline number
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
  OAA_FILE_FORMAT_UNKNOWN = 0,
  OAA_FILE_FORMAT_WAV = 1,  /* RIFF or RIFX */
  OAA_FILE_FORMAT_AIFF = 2,
  OAA_FILE_FORMAT_RF64 = 3, /* RIFF's 64-bit successor, for files over 4 GB */
  OAA_FILE_FORMAT_W64 = 4,  /* Sony Wave64 */
  OAA_FILE_FORMAT_FLAC = 5,
  OAA_FILE_FORMAT_MP3 = 6
} oaa_file_format;

typedef struct oaa_file_info {
  uint32_t sample_rate;
  uint32_t channels;

  /* Total frames in the file, or 0 when the decoder could not determine it.
   * Zero means unknown, never empty: treat it as an indeterminate length
   * rather than as a file with nothing in it. */
  uint64_t frames;

  /* frames / sample_rate. Zero when `frames` is unknown. */
  double duration_seconds;

  uint32_t format; /* oaa_file_format */

  /* Bits per sample in the source encoding, or 0 for a lossy format where the
   * question has no answer. Reported so a file report can describe its input;
   * the samples themselves always arrive as float regardless. */
  uint32_t bits_per_sample;
} oaa_file_info;

typedef struct oaa_file oaa_file;

/*
 * Opens `path`, a UTF-8 filename, and identifies its format. Returns NULL if
 * the file cannot be read or is not a format this build decodes — which is a
 * normal outcome for a user dropping an arbitrary file on the window, not an
 * error worth crashing over. Close with oaa_file_close.
 *
 * The file is reported at its own sample rate and channel count, and nothing
 * resamples or remixes it: resampling in front of a measurement changes the
 * measurement. Configure the engine from oaa_file_get_info rather than the
 * other way round. A file with more than OAA_MAX_CHANNELS channels opens
 * successfully and reports its true channel count, so that the caller can say
 * what it found instead of guessing; the engine will refuse it.
 */
OAA_API oaa_file *oaa_file_open(const char *path);

OAA_API int32_t oaa_file_get_info(const oaa_file *file, oaa_file_info *out);

/*
 * Reads up to `frames` frames of interleaved float samples into `interleaved`,
 * which must have room for `frames * channels` floats. Returns the number of
 * frames actually read; 0 means end of file.
 *
 * Sample values are not clamped. A float WAV may legitimately contain values
 * outside ±1.0, and clamping them here would destroy exactly the overshoots
 * true-peak metering exists to find.
 */
OAA_API uint64_t oaa_file_read(oaa_file *file, float *interleaved,
                               uint64_t frames);

/*
 * Seeks to `frame`. Returns OAA_ERR_UNSUPPORTED if the decoder could not seek,
 * which some malformed or streamed files will do.
 *
 * Analysis never uses this — an integrating measurement over a file that was
 * seeked through is a measurement of a programme nobody played. It exists for
 * a future waveform view that needs to read a region without re-reading the
 * whole file.
 */
OAA_API int32_t oaa_file_seek(oaa_file *file, uint64_t frame);

OAA_API void oaa_file_close(oaa_file *file);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OAA_H */
