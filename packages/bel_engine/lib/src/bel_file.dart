/// Reading audio files, for offline analysis.
///
/// SPDX-License-Identifier: MIT
///
/// This is the Dart half of `engine/src/bel_decode.c`. It hands out blocks of
/// interleaved float samples and nothing else — there is no analysis here, and
/// deliberately no "analyse this file" convenience that would hide the loop.
///
/// The loop is the point. Offline analysis pushes decoded blocks through
/// `BelEngine.push`, which is the same `bel_analyse` a capture device drives,
/// so the claim that a file report matches what the meters showed in realtime
/// is true by construction. A decoder that also analysed would be a second
/// path, and a second path is a second set of numbers waiting to disagree.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bel_engine_bindings_generated.dart' as native;

/// The container a file was found in.
///
/// Reported rather than inferred from the filename: an extension is a claim
/// somebody typed, and a report that describes its own input wrongly is worse
/// than one that does not describe it at all.
enum BelFileFormat {
  unknown(0, 'Unknown'),
  wav(1, 'WAV'),
  aiff(2, 'AIFF'),
  rf64(3, 'RF64'),
  w64(4, 'Wave64'),
  flac(5, 'FLAC'),
  mp3(6, 'MP3');

  const BelFileFormat(this.value, this.label);

  final int value;

  /// What a report prints.
  final String label;

  /// True when the encoding discards information, which is why
  /// [BelFileInfo.bitsPerSample] has no answer for it.
  bool get isLossy => this == BelFileFormat.mp3;

  static BelFileFormat fromValue(int value) {
    for (final format in BelFileFormat.values) {
      if (format.value == value) return format;
    }
    return BelFileFormat.unknown;
  }
}

/// What a file turned out to contain.
class BelFileInfo {
  const BelFileInfo({
    required this.sampleRate,
    required this.channels,
    required this.frames,
    required this.durationSeconds,
    required this.format,
    required this.bitsPerSample,
  });

  final int sampleRate;
  final int channels;

  /// Total frames, or 0 when the decoder could not determine it.
  ///
  /// Zero means *unknown*, never empty. A truncated MP3 whose frame scan fails
  /// still contains audio; treating the length as indeterminate is honest,
  /// treating it as nothing is not.
  final int frames;

  /// [frames] divided by [sampleRate], or 0 when the length is unknown.
  final double durationSeconds;

  final BelFileFormat format;

  /// Source bit depth, or 0 for a lossy format where the question has no
  /// answer. The samples themselves always arrive as float regardless.
  final int bitsPerSample;

  /// Whether the length is known. See [frames].
  bool get hasKnownLength => frames > 0;

  /// How this file is described in a report: `WAV 24-bit 48000 Hz, stereo`.
  String describe() {
    final depth = bitsPerSample > 0 ? ' $bitsPerSample-bit' : '';
    final layout = switch (channels) {
      1 => 'mono',
      2 => 'stereo',
      final n => '$n channels',
    };
    return '${format.label}$depth $sampleRate Hz, $layout';
  }

  @override
  String toString() => 'BelFileInfo(${describe()})';
}

/// Thrown when a file cannot be opened or decoded.
class BelFileException implements Exception {
  const BelFileException(this.message, [this.path]);

  final String message;
  final String? path;

  @override
  String toString() => path == null
      ? 'BelFileException: $message'
      : 'BelFileException: $message ($path)';
}

/// An open audio file, read one block at a time.
///
/// Owns a native decoder and a native read buffer, so it must be [close]d.
class BelFile {
  BelFile._(this._handle, this.info, this._blockFrames)
    : _buffer = calloc<Float>(_blockFrames * info.channels) {
    _view = _buffer.asTypedList(_blockFrames * info.channels);
  }

  /// Opens [path] and identifies its format.
  ///
  /// [blockFrames] is how many frames [readBlock] returns at a time, and it
  /// should be the same block size the engine was created with. That is not
  /// arbitrary: the gated loudness measurements are sample-accurate and do not
  /// care, but RMS, crest and the VU ballistics are computed over each pushed
  /// block, so an offline run that pushes the whole file at once reports one
  /// RMS averaged across the entire programme and a VU needle that moves
  /// precisely once. Matching the realtime block size is what makes the
  /// offline and realtime readings the same numbers.
  ///
  /// Throws [BelFileException] if the file cannot be read or is not a format
  /// this build decodes.
  static BelFile open(String path, {int blockFrames = 1024}) {
    if (blockFrames <= 0) {
      throw ArgumentError.value(blockFrames, 'blockFrames', 'must be positive');
    }

    final nativePath = path.toNativeUtf8();
    final Pointer<native.bel_file> handle;
    try {
      handle = native.bel_file_open(nativePath.cast<Char>());
    } finally {
      calloc.free(nativePath);
    }

    if (handle == nullptr) {
      throw BelFileException(
        'not an audio file this build can decode — '
        'WAV, AIFF, RF64, Wave64, FLAC and MP3 are supported',
        path,
      );
    }

    final infoStruct = calloc<native.bel_file_info>();
    try {
      final status = native.bel_file_get_info(handle, infoStruct);
      if (status != 0) {
        native.bel_file_close(handle);
        throw BelFileException('could not read file information', path);
      }

      final ref = infoStruct.ref;
      final info = BelFileInfo(
        sampleRate: ref.sample_rate,
        channels: ref.channels,
        frames: ref.frames,
        durationSeconds: ref.duration_seconds,
        format: BelFileFormat.fromValue(ref.format),
        bitsPerSample: ref.bits_per_sample,
      );
      return BelFile._(handle, info, blockFrames);
    } finally {
      calloc.free(infoStruct);
    }
  }

  final Pointer<native.bel_file> _handle;
  final int _blockFrames;

  /// What the file contains. Read this before configuring an engine: nothing
  /// resamples or remixes, so the engine must be told the file's own sample
  /// rate and channel count.
  final BelFileInfo info;

  /// The native read buffer, allocated once and reused for every block.
  final Pointer<Float> _buffer;
  late final Float32List _view;

  bool _closed = false;
  int _framesRead = 0;

  /// Frames decoded so far. Divide by [BelFileInfo.frames] for progress.
  int get framesRead => _framesRead;

  /// How far through the file we are, 0..1, or `null` when the length is
  /// unknown. Null rather than a fabricated fraction, so a progress bar can
  /// show itself as indeterminate instead of lying about a position.
  double? get progress {
    if (!info.hasKnownLength) return null;
    final fraction = _framesRead / info.frames;
    return fraction.clamp(0.0, 1.0);
  }

  /// Decodes the next block, or returns `null` at end of file.
  ///
  /// The returned list is a **view over a reusable native buffer** — it is
  /// valid only until the next [readBlock] or [close], and it is not a copy.
  /// That is what keeps an hour-long analysis from allocating tens of
  /// thousands of buffers. Pass it straight to `BelEngine.push`, which copies
  /// what it needs; hold on to it and you are reading whatever the next block
  /// decoded into.
  Float32List? readBlock() {
    _checkOpen();

    final framesRead = native.bel_file_read(_handle, _buffer, _blockFrames);
    if (framesRead <= 0) return null;

    _framesRead += framesRead;

    // The full-size view is cached, because every block but the last one is
    // full and a fresh view object per block is the allocation this design
    // exists to avoid.
    if (framesRead == _blockFrames) return _view;
    return Float32List.sublistView(_view, 0, framesRead * info.channels);
  }

  /// Seeks to [frame].
  ///
  /// Analysis never uses this — an integrated measurement over a file that was
  /// seeked through describes a programme nobody played. It exists for a
  /// future waveform view that reads a region without re-reading the file.
  ///
  /// Returns false when the decoder could not seek.
  bool seek(int frame) {
    _checkOpen();
    final ok = native.bel_file_seek(_handle, frame) == 0;
    if (ok) _framesRead = frame;
    return ok;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    native.bel_file_close(_handle);
    calloc.free(_buffer);
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('BelFile has been closed');
    }
  }

  @override
  String toString() => 'BelFile(${info.describe()})';
}
