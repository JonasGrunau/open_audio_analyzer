/*
 * oaa_decode.c — a file on disk, as blocks of float samples.
 *
 * SPDX-License-Identifier: MIT
 *
 * This is the whole of offline analysis on the C side, and it is deliberately
 * small: open a file, say what is in it, hand out interleaved float frames.
 * There is no analysis here at all. The caller reads a block and passes it to
 * `oaa_engine_push`, which runs the same DSP graph a capture device drives.
 *
 * ---------------------------------------------------------------------------
 * Why the decoder is in C rather than Dart
 *
 * Three consumers analyse files — the app's drag-and-drop panel, the `oaa`
 * CLI, and eventually the plugin's offline render — and a metering tool whose
 * three front ends disagree about what a file contains is worse than one that
 * cannot open files at all. One decoder means one answer.
 *
 * It also keeps the correctness claim intact. "Offline analysis produces the
 * same numbers as realtime" is only true if offline reaches the same
 * `oaa_analyse` through the same buffers, which is exactly what decoding into
 * OAA_SOURCE_PUSH does. A Dart-side decoder would be a second path, and a
 * second path is a second set of numbers waiting to diverge.
 *
 * ---------------------------------------------------------------------------
 * What this deliberately does not do
 *
 * **No resampling, and no channel conversion.** The file is reported and read
 * at its own sample rate and its own channel count, and the caller is expected
 * to configure the engine to match. This is the same rule the capture path
 * follows for the same reason: resampling in front of a measurement changes
 * the measurement. K-weighting coefficients are computed at the stream's
 * actual rate, so a 44.1 kHz file measured at 44.1 kHz is correct, and the
 * same file silently converted to 48 kHz first is a measurement of a different
 * signal.
 *
 * **No clamping.** Sample values from a float WAV may exceed ±1.0, and they
 * are passed through untouched. Clamping here would quietly destroy the
 * overshoots true-peak metering exists to find.
 *
 * ---------------------------------------------------------------------------
 * Two things about this file that look accidental and are not
 *
 * 1. **MP3 is tried last.** dr_mp3 identifies a file by scanning for something
 *    that parses as an MP3 frame, and arbitrary binary data contains such
 *    sequences often enough to matter. Given first refusal it will cheerfully
 *    "open" a FLAC file and decode noise. dr_wav and dr_flac both check a
 *    magic number at offset zero and reject anything else, so they are safe to
 *    ask first, and MP3 becomes the fallback rather than the default.
 *
 * 2. **This is a separate translation unit from oaa_device.c on purpose.**
 *    That file defines `MA_NO_DECODING` before including miniaudio, which is
 *    what stops miniaudio compiling its own bundled copies of dr_wav, dr_flac
 *    and dr_mp3. Those copies would collide with the ones compiled here at
 *    link time. The define is load-bearing twice over — it is also what
 *    guarantees the capture path cannot silently convert a format — so if a
 *    duplicate-symbol error ever appears, the fix is not to remove it.
 */

#include "oaa/oaa.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#endif

/* The single-header libraries are compiled here, exactly once in the whole
 * engine. Everything else that needs them just calls through oaa_file_*. */
#define DR_WAV_IMPLEMENTATION
#define DR_FLAC_IMPLEMENTATION
#define DR_MP3_IMPLEMENTATION

#include "dr_flac.h"
#include "dr_mp3.h"
#include "dr_wav.h"

/* ------------------------------------------------------------------------ */
/* The handle                                                                */
/* ------------------------------------------------------------------------ */

/*
 * Which of the three decoders is live is recorded in `backend` rather than
 * inferred from `info.format`, because the format is a *description of the
 * file* that the caller reads, and the backend is an implementation detail
 * this file switches on. Deriving one from the other would mean a new
 * container that dr_wav learns to open — AIFC, say — silently dispatching to
 * the wrong reader.
 */
typedef enum {
  OAA_BACKEND_WAV = 0,
  OAA_BACKEND_FLAC = 1,
  OAA_BACKEND_MP3 = 2
} oaa_backend;

struct oaa_file {
  oaa_backend backend;
  oaa_file_info info;

  /* Only the member named by `backend` is initialised. dr_flac hands back a
   * pointer it allocated itself; the other two initialise in place. */
  drwav wav;
  drflac *flac;
  drmp3 mp3;
};

/* ------------------------------------------------------------------------ */
/* Opening                                                                   */
/* ------------------------------------------------------------------------ */

#if defined(_WIN32)
/*
 * UTF-8 to UTF-16 for the Windows file APIs.
 *
 * dr_libs' plain `_init_file` functions go through `fopen`, which on Windows
 * interprets the path in the process's ANSI code page rather than as UTF-8.
 * The result is that a path containing any non-ASCII character — an umlaut in
 * a user name is enough — fails to open, on one platform only, with an error
 * that says nothing about encoding. The `_w` variants take UTF-16 and are the
 * only way to open such a file reliably. Same class of bug as the device-name
 * decoding in the Dart bindings, found the same way.
 *
 * Returns NULL on failure; the caller treats that as "cannot open".
 */
static wchar_t *oaa_widen(const char *utf8) {
  const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  if (needed <= 0) {
    return NULL;
  }

  wchar_t *wide = (wchar_t *)calloc((size_t)needed, sizeof(wchar_t));
  if (wide == NULL) {
    return NULL;
  }

  if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, needed) <= 0) {
    free(wide);
    return NULL;
  }
  return wide;
}
#endif

/* Maps dr_wav's container tag onto the public format enum. AIFF is called out
 * separately from RIFF because a report that says "WAV" about an AIFF file is
 * a report that misdescribes its own input. */
static uint32_t oaa_format_from_container(drwav_container container) {
  switch (container) {
    case drwav_container_aiff:
      return OAA_FILE_FORMAT_AIFF;
    case drwav_container_w64:
      return OAA_FILE_FORMAT_W64;
    case drwav_container_rf64:
      return OAA_FILE_FORMAT_RF64;
    case drwav_container_riff:
    case drwav_container_rifx:
    default:
      return OAA_FILE_FORMAT_WAV;
  }
}

static int oaa_try_wav(oaa_file *file, const char *path) {
#if defined(_WIN32)
  wchar_t *wide = oaa_widen(path);
  if (wide == NULL) {
    return 0;
  }
  const int opened = drwav_init_file_w(&file->wav, wide, NULL) != 0;
  free(wide);
  if (!opened) {
    return 0;
  }
#else
  if (!drwav_init_file(&file->wav, path, NULL)) {
    return 0;
  }
#endif

  file->backend = OAA_BACKEND_WAV;
  file->info.sample_rate = file->wav.sampleRate;
  file->info.channels = file->wav.channels;
  file->info.frames = file->wav.totalPCMFrameCount;
  file->info.bits_per_sample = file->wav.bitsPerSample;
  file->info.format = oaa_format_from_container(file->wav.container);
  return 1;
}

static int oaa_try_flac(oaa_file *file, const char *path) {
#if defined(_WIN32)
  wchar_t *wide = oaa_widen(path);
  if (wide == NULL) {
    return 0;
  }
  file->flac = drflac_open_file_w(wide, NULL);
  free(wide);
#else
  file->flac = drflac_open_file(path, NULL);
#endif

  if (file->flac == NULL) {
    return 0;
  }

  file->backend = OAA_BACKEND_FLAC;
  file->info.sample_rate = file->flac->sampleRate;
  file->info.channels = file->flac->channels;
  file->info.frames = file->flac->totalPCMFrameCount;
  file->info.bits_per_sample = file->flac->bitsPerSample;
  file->info.format = OAA_FILE_FORMAT_FLAC;
  return 1;
}

static int oaa_try_mp3(oaa_file *file, const char *path) {
#if defined(_WIN32)
  wchar_t *wide = oaa_widen(path);
  if (wide == NULL) {
    return 0;
  }
  const int opened = drmp3_init_file_w(&file->mp3, wide, NULL) != 0;
  free(wide);
  if (!opened) {
    return 0;
  }
#else
  if (!drmp3_init_file(&file->mp3, path, NULL)) {
    return 0;
  }
#endif

  file->backend = OAA_BACKEND_MP3;
  file->info.sample_rate = file->mp3.sampleRate;
  file->info.channels = file->mp3.channels;

  /* MP3 carries no frame count in its header, so this walks the file to count
   * frames and then seeks back to the start. It costs a pass over the data
   * before analysis begins, and it is worth paying: without it a long file
   * analyses behind a progress bar that cannot report progress, and the report
   * cannot state a duration. The scan parses frame headers rather than
   * decoding them, so it is far cheaper than the analysis pass that follows.
   *
   * A malformed file can still defeat it, in which case this reads 0 and the
   * caller is expected to treat the length as unknown rather than as empty. */
  file->info.frames = drmp3_get_pcm_frame_count(&file->mp3);

  /* Lossy: there is no source bit depth to report, and inventing one would put
   * a number in the report that describes nothing. */
  file->info.bits_per_sample = 0;
  file->info.format = OAA_FILE_FORMAT_MP3;
  return 1;
}

oaa_file *oaa_file_open(const char *path) {
  if (path == NULL || path[0] == '\0') {
    return NULL;
  }

  oaa_file *file = (oaa_file *)calloc(1, sizeof(oaa_file));
  if (file == NULL) {
    return NULL;
  }

  /* Order matters — see the note at the top of this file. */
  if (!oaa_try_wav(file, path) && !oaa_try_flac(file, path) &&
      !oaa_try_mp3(file, path)) {
    free(file);
    return NULL;
  }

  /* A decoder that reports no channels or no sample rate has told us it does
   * not know what it opened. Every division downstream — duration, progress,
   * the K-weighting coefficients — would be by zero, so refuse here instead of
   * producing a report full of infinities. */
  if (file->info.channels == 0 || file->info.sample_rate == 0) {
    oaa_file_close(file);
    return NULL;
  }

  file->info.duration_seconds =
      (double)file->info.frames / (double)file->info.sample_rate;

  return file;
}

/* ------------------------------------------------------------------------ */
/* Reading                                                                   */
/* ------------------------------------------------------------------------ */

int32_t oaa_file_get_info(const oaa_file *file, oaa_file_info *out) {
  if (file == NULL || out == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }
  *out = file->info;
  return OAA_OK;
}

uint64_t oaa_file_read(oaa_file *file, float *interleaved, uint64_t frames) {
  if (file == NULL || interleaved == NULL || frames == 0) {
    return 0;
  }

  switch (file->backend) {
    case OAA_BACKEND_WAV:
      return drwav_read_pcm_frames_f32(&file->wav, frames, interleaved);
    case OAA_BACKEND_FLAC:
      return drflac_read_pcm_frames_f32(file->flac, frames, interleaved);
    case OAA_BACKEND_MP3:
      return drmp3_read_pcm_frames_f32(&file->mp3, frames, interleaved);
    default:
      return 0;
  }
}

int32_t oaa_file_seek(oaa_file *file, uint64_t frame) {
  if (file == NULL) {
    return OAA_ERR_INVALID_ARGUMENT;
  }

  drwav_bool32 ok = 0;
  switch (file->backend) {
    case OAA_BACKEND_WAV:
      ok = drwav_seek_to_pcm_frame(&file->wav, frame);
      break;
    case OAA_BACKEND_FLAC:
      ok = drflac_seek_to_pcm_frame(file->flac, frame);
      break;
    case OAA_BACKEND_MP3:
      ok = drmp3_seek_to_pcm_frame(&file->mp3, frame);
      break;
    default:
      break;
  }

  return ok ? OAA_OK : OAA_ERR_UNSUPPORTED;
}

void oaa_file_close(oaa_file *file) {
  if (file == NULL) {
    return;
  }

  switch (file->backend) {
    case OAA_BACKEND_WAV:
      drwav_uninit(&file->wav);
      break;
    case OAA_BACKEND_FLAC:
      if (file->flac != NULL) {
        drflac_close(file->flac);
      }
      break;
    case OAA_BACKEND_MP3:
      drmp3_uninit(&file->mp3);
      break;
    default:
      break;
  }

  free(file);
}
