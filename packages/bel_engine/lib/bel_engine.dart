/// Dart access to the Bel measurement engine.
///
/// SPDX-License-Identifier: MIT
///
/// The shape of this library is dictated by one constraint: reading
/// measurements must cost nothing measurable on the frame the UI is about to
/// paint. Everything that looks unusual here follows from that.
///
///   - [BelEngine.refresh] is the only method called per frame.
///   - The typed lists are built once, in the constructor, as views over native
///     memory that never moves. They are not copies and not defensive — writing
///     to one would corrupt the engine's snapshot, which is why they are
///     documented as read-only rather than wrapped in something that would
///     allocate.
///   - There is no `Stream`, no `ValueNotifier` and no isolate. A stream of
///     measurements would allocate an event per update and deliver it a
///     microtask late, which is exactly one frame of latency for no benefit.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bel_engine_bindings_generated.dart' as native;
import 'src/bel_ffi.dart';

/// Widest channel layout the engine carries (7.1).
const int kBelMaxChannels = 8;

/// Number of log-spaced spectrum bands published to the UI.
const int kBelSpectrumBands = 512;

/// The floor every dB reading clamps to. Mirrors `BEL_DB_FLOOR` in `bel.h`.
const double kBelDbFloor = -144.0;

/// Where the engine takes its signal from.
enum BelSource {
  /// Digital black.
  silence(0),

  /// The built-in 1 kHz test signal. See `engine/src/bel_source.c` for the
  /// exact readings it must produce.
  testTone(1),

  /// A capture device. Not implemented yet; [BelEngine.start] throws.
  device(2),

  /// A decoded file, run as fast as the CPU allows. Not implemented yet.
  file(3),

  /// The caller supplies audio through [BelEngine.push]. No thread, no clock,
  /// no device — the engine becomes a pure function of the samples given to
  /// it, which is what the conformance suite needs and what file analysis will
  /// be built on.
  push(4);

  const BelSource(this.value);
  final int value;
}

/// Thrown when the engine cannot be created or started.
class BelEngineException implements Exception {
  const BelEngineException(this.message);
  final String message;
  @override
  String toString() => 'BelEngineException: $message';
}

/// A running measurement engine.
///
/// Create one with [BelEngine.start] and [dispose] it when done. Instances own
/// a native thread, so leaking one leaks a thread.
class BelEngine {
  BelEngine._(
    this._handle,
    Pointer<native.bel_snapshot> snapshot,
    this._channels,
  ) : _snapshot = snapshot.ref,
      peak = native.bel_snapshot_peak(snapshot).asTypedList(kBelMaxChannels),
      rms = native.bel_snapshot_rms(snapshot).asTypedList(kBelMaxChannels),
      vu = native.bel_snapshot_vu(snapshot).asTypedList(kBelMaxChannels),
      clip = native.bel_snapshot_clip(snapshot).asTypedList(kBelMaxChannels),
      spectrum = native
          .bel_snapshot_spectrum(snapshot)
          .asTypedList(kBelSpectrumBands),
      spectrumPeak = native
          .bel_snapshot_spectrum_peak(snapshot)
          .asTypedList(kBelSpectrumBands);

  /// The ABI this Dart code was written against. Mirrors `BEL_ABI_VERSION`.
  static const int expectedAbiVersion = 1;

  final Pointer<native.bel_engine> _handle;

  /// The snapshot struct view. Cached rather than re-derived from the pointer,
  /// because `Pointer.ref` allocates a fresh view object each time it is read
  /// and this one is read many times per frame.
  final native.bel_snapshot _snapshot;

  bool _disposed = false;
  int _generation = 0;

  // --- Zero-copy views over the snapshot's arrays --------------------------
  //
  // Built once. Each is a window onto native memory, not a copy: reading is a
  // raw load, and they can be handed straight to `Canvas.drawRawPoints` or
  // `Vertices.raw` without any conversion. Treat them as read-only.

  /// Per-channel peak, dBFS, with meter hold applied.
  final Float32List peak;

  /// Per-channel RMS, dBFS, with meter decay applied.
  final Float32List rms;

  /// Per-channel VU deflection.
  final Float32List vu;

  /// Per-channel count of consecutive full-scale samples.
  final Uint32List clip;

  /// Spectrum magnitudes, dBFS per log-spaced band.
  final Float32List spectrum;

  /// Per-band peak hold for [spectrum].
  final Float32List spectrumPeak;

  /// The engine's version string.
  static String get versionString =>
      native.bel_version_string().cast<Utf8>().toDartString();

  /// The ABI version of the loaded native library.
  static int get abiVersion => native.bel_abi_version();

  /// Create and start an engine.
  ///
  /// Throws [BelEngineException] rather than returning null, because every
  /// failure here is a programming error or a missing platform feature and
  /// none of them are recoverable at the call site.
  static BelEngine start({
    BelSource source = BelSource.testTone,
    int sampleRate = 48000,
    int channels = 2,
    int blockFrames = 0,
  }) {
    // A mismatch means the compiled library and these bindings disagree about
    // the layout of the snapshot. That does not crash — it silently reads the
    // wrong bytes and renders numbers that look entirely plausible. Checking
    // costs one call at startup and is the cheapest insurance in the project.
    final actual = abiVersion;
    if (actual != expectedAbiVersion) {
      throw BelEngineException(
        'engine ABI $actual, expected $expectedAbiVersion — '
        'the native library is stale, rebuild it',
      );
    }

    final config = calloc<native.bel_config>();
    try {
      native.bel_config_defaults(config);
      config.ref
        ..sample_rate = sampleRate
        ..channels = channels
        ..source = source.value
        ..block_frames = blockFrames;

      final handle = native.bel_engine_create(config);
      if (handle == nullptr) {
        throw BelEngineException(
          'could not create engine (source: ${source.name}, '
          '$channels ch @ $sampleRate Hz)',
        );
      }

      final snapshot = native.bel_snapshot_buffer(handle);
      final engine = BelEngine._(handle, snapshot, channels);

      final status = native.bel_engine_start(handle);
      if (status != 0) {
        native.bel_engine_destroy(handle);
        throw BelEngineException('could not start analysis thread ($status)');
      }
      return engine;
    } finally {
      calloc.free(config);
    }
  }

  /// Pull the latest measurements across.
  ///
  /// The only call on the per-frame path. Returns `true` when the engine has
  /// published something new since the previous call — at 120 fps against a
  /// ~47 Hz measurement rate, most frames have nothing new to show, and
  /// skipping those is free.
  bool refresh() {
    final generation = belSnapshotAcquireLeaf(_handle);
    if (generation == _generation) {
      return false;
    }
    _generation = generation;
    return true;
  }

  /// Measure [interleaved] and publish the result, synchronously.
  ///
  /// Only valid for [BelSource.push]. On return the readings reflect these
  /// samples — there is no thread and no clock, which is what makes a pushed
  /// engine a pure function of the audio it was given.
  ///
  /// Block size does not affect the result. The gating windows are counted in
  /// samples internally, so pushing an hour in one call and pushing it in
  /// 512-frame chunks produce identical numbers; the conformance suite pushes
  /// in one-second chunks purely to keep peak memory down.
  void push(Float32List interleaved) {
    if (interleaved.isEmpty) return;

    // Grown rather than allocated per call. A conformance run pushes a few
    // hundred blocks and an offline file analysis will push tens of thousands,
    // and none of them should be paying for a malloc and a free each time.
    if (_pushCapacity < interleaved.length) {
      if (_pushBuffer != nullptr) calloc.free(_pushBuffer);
      _pushBuffer = calloc<Float>(interleaved.length);
      _pushCapacity = interleaved.length;
    }
    _pushBuffer.asTypedList(interleaved.length).setAll(0, interleaved);

    final frames = interleaved.length ~/ channelsRequested;
    final status = native.bel_engine_push(_handle, _pushBuffer, frames);
    if (status != 0) {
      throw BelEngineException(
        'push failed ($status) — is this engine BelSource.push?',
      );
    }
    refresh();
  }

  Pointer<Float> _pushBuffer = nullptr;
  int _pushCapacity = 0;

  /// The channel count this engine was created with.
  ///
  /// Read from the config rather than the snapshot, because [push] needs it to
  /// turn a sample count into a frame count *before* anything has been
  /// measured — and the snapshot's channel field is zero until then.
  int get channelsRequested => _channels;
  final int _channels;

  /// Clear every integrating measurement and restart the elapsed clock.
  void reset() => native.bel_engine_reset(_handle);

  // --- Readings ------------------------------------------------------------
  //
  // A value the current build does not measure is NaN. Callers must check —
  // see [hasLoudness]. Zero is a legitimate reading for correlation, balance
  // and several dB quantities, so it cannot double as "no data".

  int get sampleRate => _snapshot.sample_rate;
  int get channels => _snapshot.channels;
  double get elapsedSeconds => _snapshot.elapsed_seconds;

  bool get isRunning => _snapshot.flags & 1 != 0;

  /// Whether the loudness readings are measured in this build.
  ///
  /// False until Phase 1 lands K-weighting, R128 gating and the EBU
  /// conformance suite together. While false, [lufsIntegrated] and friends are
  /// NaN and the UI must show a dash — not a zero, and not a guess.
  bool get hasLoudness => _snapshot.flags & (1 << 1) == 0;

  /// Whether [spectrum] holds measured data.
  bool get hasSpectrum => _snapshot.flags & (1 << 2) == 0;

  double get lufsMomentary => _snapshot.lufs_momentary;
  double get lufsShort => _snapshot.lufs_short;
  double get lufsIntegrated => _snapshot.lufs_integrated;
  double get loudnessRange => _snapshot.lra;

  double get truePeak => _snapshot.true_peak;
  double get truePeakMax => _snapshot.true_peak_max;
  double get samplePeakMax => _snapshot.sample_peak_max;

  double get dynamicRangeShort => _snapshot.dr_short;
  double get dynamicRangeIntegrated => _snapshot.dr_integrated;
  double get crestFactor => _snapshot.crest;
  double get peakToLoudnessRatio => _snapshot.plr;
  double get peakToShortTermRatio => _snapshot.psr;

  /// −1 fully out of phase, +1 mono.
  double get correlation => _snapshot.correlation;

  /// −1 hard left, +1 hard right.
  double get balance => _snapshot.balance;

  /// Stop the analysis thread and release the engine.
  ///
  /// Idempotent. After this the typed list views point at freed memory, so
  /// nothing may read them — that is the reason [_disposed] is checked rather
  /// than trusted.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    native.bel_engine_destroy(_handle);
    if (_pushBuffer != nullptr) {
      calloc.free(_pushBuffer);
      _pushBuffer = nullptr;
      _pushCapacity = 0;
    }
  }
}
