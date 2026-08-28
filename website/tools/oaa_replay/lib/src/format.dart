// SPDX-License-Identifier: GPL-3.0-or-later

/// The recording format: what the engine measured, frame by frame.
///
/// ---------------------------------------------------------------------------
/// Why a format at all
///
/// The website's demos used to play a synthetic programme — plausible numbers,
/// invented. They were invented for a good reason (`dart:ffi` has no web
/// implementation, so there can be no engine in a browser) and they were still
/// invented, and it showed: a spectrum built from noise fields does not look
/// like music because it is not music.
///
/// So the engine measures a real track *here*, once, and the browser replays
/// what it measured. The numbers on the website are then the engine's own
/// numbers, on real material, rather than a second implementation's idea of
/// them. That is the same argument as `MeterSource` itself: one set of readings
/// with several ways of reaching them, never several sets.
///
/// ---------------------------------------------------------------------------
/// How it is laid out, and why that layout
///
/// Two decisions carry the file size, which matters because a browser fetches
/// this.
///
/// **The three spectrum arrays are frame-major, and delta-coded along the band
/// axis.** That is: all 512 bands of frame 0, then all 512 of frame 1, with
/// each frame storing the difference from the band below it rather than the
/// band itself. Those arrays are almost the whole file, so it was worth
/// measuring rather than guessing — on 45 seconds of this track at 20 fps, the
/// spectrum plane gzips to:
///
///     band-major (all frames of one band together)      351 kB
///     band-major, delta over time                       329 kB
///     frame-major                                       338 kB
///     frame-major, delta along the bands                272 kB
///
/// The intuition that a single band's level over time is the smooth series
/// turns out to be wrong at this cadence: 512 log-spaced bands put neighbours
/// a fraction of a semitone apart, so a spectrum is smoother *across* itself
/// than it is across 50 ms of music. Frame-major is also the layout a reader
/// wants — a frame is contiguous — so the two arguments agree.
///
/// Everything else stays series-major, one quantity's whole timeline at a
/// time, and is small enough that the choice does not matter: the scalars are
/// 60 kB and the histogram gzips to 9 kB either way.
///
/// **Quantised.** A spectrum band is stored as one byte over a 120 dB range,
/// so half a decibel. Nothing on screen resolves better than that — the
/// spectrum module draws a shape, not a value to be read off. The scalars are
/// *not* quantised: they are read as numbers, `-14.1` is printed to a tenth
/// and a validator turns it into PASS or FAIL, so they stay float32 and the
/// seventeen of them cost 4 bytes each per frame.
///
/// ---------------------------------------------------------------------------
/// What is not in here
///
/// The scope: the last 1024 stereo frames, which is to say the audio itself,
/// undecorated. Storing it would be storing a second copy of the track at
/// 8 kB a frame — larger than everything else in the file put together — and
/// the browser already has the audio, because it is playing it. See
/// `ReplaySource.attachPcm`.
library;

import 'dart:typed_data';

/// `OAAREC` and a format version, so a stale file fails loudly.
const int recordingMagic0 = 0x4141_4F; // 'OAA'
const int recordingVersion = 1;

/// Which optional arrays a file carries.
///
/// A recording made for the module catalogue carries every array; the one the
/// website ships leaves out what the eight modules on that canvas never read.
/// A flag rather than two formats: the reader does not care which it was given.
abstract final class RecordingParts {
  static const int spectrum = 1 << 0;
  static const int spectrumPeak = 1 << 1;
  static const int spectrumPan = 1 << 2;
  static const int histogram = 1 << 3;
  static const int clip = 1 << 4;

  static const int all =
      spectrum | spectrumPeak | spectrumPan | histogram | clip;
}

/// The scalars, in the order they are stored.
///
/// A list rather than a struct because the file is planar: each of these is
/// `frames` floats, one series after another. Adding a quantity means adding it
/// at the end and bumping [recordingVersion].
enum Scalar {
  lufsMomentary,
  lufsShort,
  lufsIntegrated,
  loudnessRange,
  loudnessRangeLow,
  loudnessRangeHigh,
  loudnessRangeGate,
  truePeak,
  truePeakMax,
  samplePeakMax,
  dynamicRangeShort,
  dynamicRangeIntegrated,
  crestFactor,
  odrIntegrated,
  odrShort,
  correlation,
  balance;

  static const int count = 17;
}

/// dB quantisation for the spectrum arrays: one byte over 120 dB.
///
/// 0 is reserved for "below the floor", which includes NaN — a band the engine
/// has not measured and a band that is silent are both nothing to draw, and the
/// painters already treat the floor that way.
const double spectrumFloorDb = -120.0;
const double spectrumStepDb = 120.0 / 254.0;

int quantiseDb(double db) {
  if (db.isNaN || db <= spectrumFloorDb) return 0;
  if (db >= 0.0) return 255;
  return 1 + ((db - spectrumFloorDb) / spectrumStepDb).round().clamp(0, 254);
}

double dequantiseDb(int q) =>
    q == 0 ? spectrumFloorDb : spectrumFloorDb + (q - 1) * spectrumStepDb;

/// Delta-code one frame's bands in place, low band first.
///
/// Bytes wrap deliberately: the difference between two adjacent bands is small
/// almost everywhere and enormous at the two or three edges in a spectrum, and
/// letting those wrap costs one byte each while clamping them would lose the
/// edge — which is the part of a spectrum anybody is looking at.
void deltaEncodeBands(Uint8List frame) {
  var previous = 0;
  for (var band = 0; band < frame.length; band++) {
    final value = frame[band];
    frame[band] = (value - previous) & 0xFF;
    previous = value;
  }
}

/// A header, as it appears at the front of the file.
class RecordingHeader {
  const RecordingHeader({
    required this.parts,
    required this.frames,
    required this.fps,
    required this.channels,
    required this.sampleRate,
    required this.startSeconds,
    required this.spectrumBands,
    required this.histogramBins,
  });

  final int parts;
  final int frames;

  /// Frames of recording per second of programme. The file is a fixed cadence
  /// so that a position in the audio is an index, not a search.
  final double fps;

  final int channels;

  /// The rate the *track* was decoded at, which the engine adopted. Kept
  /// because the browser has to line the audio up with this, and a recording
  /// that does not say what it was made from cannot be checked.
  final int sampleRate;

  /// Where in the source file the recording starts.
  final double startSeconds;

  final int spectrumBands;
  final int histogramBins;

  double get seconds => frames / fps;

  bool has(int part) => parts & part != 0;

  /// 64 bytes, fixed, so the reader can slice the planes without parsing.
  static const int bytes = 64;

  Uint8List encode() {
    final out = ByteData(bytes);
    out.setUint8(0, 0x4F); // O
    out.setUint8(1, 0x41); // A
    out.setUint8(2, 0x41); // A
    out.setUint8(3, 0x52); // R
    out.setUint8(4, 0x45); // E
    out.setUint8(5, 0x43); // C
    out.setUint16(6, recordingVersion, Endian.little);
    out.setUint32(8, parts, Endian.little);
    out.setUint32(12, frames, Endian.little);
    out.setFloat32(16, fps, Endian.little);
    out.setUint16(20, channels, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setFloat32(28, startSeconds, Endian.little);
    out.setUint16(32, spectrumBands, Endian.little);
    out.setUint16(34, histogramBins, Endian.little);
    return out.buffer.asUint8List();
  }

  static RecordingHeader decode(ByteData data) {
    final magic = [
      data.getUint8(0),
      data.getUint8(1),
      data.getUint8(2),
      data.getUint8(3),
      data.getUint8(4),
      data.getUint8(5),
    ];
    const expected = [0x4F, 0x41, 0x41, 0x52, 0x45, 0x43];
    for (var i = 0; i < expected.length; i++) {
      if (magic[i] != expected[i]) {
        throw const FormatException('not an Open Audio Analyzer recording');
      }
    }
    final version = data.getUint16(6, Endian.little);
    if (version != recordingVersion) {
      throw FormatException(
        'recording is version $version, this build reads $recordingVersion — '
        'run `npm run record` again',
      );
    }
    return RecordingHeader(
      parts: data.getUint32(8, Endian.little),
      frames: data.getUint32(12, Endian.little),
      fps: data.getFloat32(16, Endian.little),
      channels: data.getUint16(20, Endian.little),
      sampleRate: data.getUint32(24, Endian.little),
      startSeconds: data.getFloat32(28, Endian.little),
      spectrumBands: data.getUint16(32, Endian.little),
      histogramBins: data.getUint16(34, Endian.little),
    );
  }
}
