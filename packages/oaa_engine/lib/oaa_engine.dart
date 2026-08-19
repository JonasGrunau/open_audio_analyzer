/// Dart access to the Open Audio Analyzer measurement engine.
///
/// SPDX-License-Identifier: MIT
///
/// The shape of this library is dictated by one constraint: reading
/// measurements must cost nothing measurable on the frame the UI is about to
/// paint. Everything that looks unusual here follows from that.
///
///   - [OaaEngine.refresh] is the only method called per frame.
///   - The typed lists are built once, in the constructor, as views over native
///     memory that never moves. They are not copies and not defensive — writing
///     to one would corrupt the engine's snapshot, which is why they are
///     documented as read-only rather than wrapped in something that would
///     allocate.
///   - There is no `Stream`, no `ValueNotifier` and no isolate. A stream of
///     measurements would allocate an event per update and deliver it a
///     microtask late, which is exactly one frame of latency for no benefit.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:ffi/ffi.dart';

import 'oaa_engine_bindings_generated.dart' as native;
import 'src/oaa_ffi.dart';

/// Decoding files for offline analysis. Kept in its own file because it shares
/// nothing with the per-frame path this library is otherwise entirely about —
/// see the note at the top of `src/oaa_file.dart`.
export 'src/oaa_file.dart';

/// Driving a whole file through the engine. Lives here rather than in the app
/// or the CLI because both need it and neither can import the other.
export 'src/offline.dart';

/// Widest channel layout the engine carries (7.1).
const int kOaaMaxChannels = 8;

/// Number of log-spaced spectrum bands published to the UI.
const int kOaaSpectrumBands = 512;

/// The frequency range those bands span, log-spaced, at every sample rate.
///
/// Fixed rather than derived from Nyquist: an analyser whose axis moves when
/// you change interface is one you cannot compare two readings on. Bands above
/// Nyquist read [kOaaDbFloor].
const double kOaaSpectrumHzLow = 20.0;
const double kOaaSpectrumHzHigh = 20000.0;

/// Stereo sample pairs published for the phase scope. One analysis block at the
/// default settings, so at 48 kHz the scope sees every sample.
const int kOaaScopePoints = 1024;

/// Bins in the published short-term loudness distribution, and the range they
/// span in LUFS.
const int kOaaHistogramBins = 120;
const double kOaaHistogramMinLufs = -60.0;
const double kOaaHistogramMaxLufs = 0.0;

/// The floor every dB reading clamps to. Mirrors `OAA_DB_FLOOR` in `oaa.h`.
const double kOaaDbFloor = -144.0;

/// The geometric centre frequency of spectrum band [band], in Hz.
///
/// Declared here beside the constants it is derived from rather than
/// rediscovered by each painter that draws a frequency axis. Two modules that
/// disagree by one band about where 1 kHz is are two modules whose graticules
/// do not line up when they sit side by side.
double bandCentreHz(int band) =>
    kOaaSpectrumHzLow *
    math.pow(
      kOaaSpectrumHzHigh / kOaaSpectrumHzLow,
      (band + 0.5) / kOaaSpectrumBands,
    );

/// The band a frequency falls in — the inverse of [bandCentreHz], for placing
/// an axis label or a cursor. Not clamped: a caller asking about 30 kHz gets an
/// index past the end, which is the honest answer.
double bandOfHz(double hz) =>
    kOaaSpectrumBands *
        math.log(hz / kOaaSpectrumHzLow) /
        math.log(kOaaSpectrumHzHigh / kOaaSpectrumHzLow) -
    0.5;

/// Where the engine takes its signal from.
enum OaaSource {
  /// Digital black.
  silence(0),

  /// The built-in 1 kHz test signal. See `engine/src/oaa_source.c` for the
  /// exact readings it must produce.
  testTone(1),

  /// A hardware or loopback capture device, chosen with `deviceId`.
  ///
  /// The engine adopts the device's own sample rate and channel count rather
  /// than converting to a requested format — a resampler in front of the
  /// measurement would move inter-sample peaks and shift the K-weighted
  /// energy. Read [OaaEngine.sampleRate] and [OaaEngine.channels] back to find
  /// out what it settled on.
  device(2),

  /// Reserved. File analysis does **not** use this — it decodes with [OaaFile]
  /// and drives the engine through [push], so that offline and realtime share
  /// one `oaa_analyse` rather than one having a path of its own. See
  /// [analyseFile].
  file(3),

  /// The caller supplies audio through [OaaEngine.push]. No thread, no clock,
  /// no device — the engine becomes a pure function of the samples given to
  /// it, which is what the conformance suite needs and what file analysis is
  /// built on.
  push(4);

  const OaaSource(this.value);
  final int value;
}

/// A capture device the system is offering.
class OaaDevice {
  OaaDevice._(native.oaa_device_info info)
    : id = _readString(info.id, kOaaDeviceIdMax),
      name = _readString(info.name, kOaaDeviceNameMax),
      channels = info.channels,
      sampleRate = info.sample_rate,
      isDefault = info.is_default != 0,
      isLoopback = info.is_loopback != 0;

  /// Opaque and platform-specific, but stable enough to store in a preset.
  /// Pass to [OaaEngine.start].
  final String id;

  /// What to show a human.
  final String name;

  /// Native format, where the backend reports it. Zero means it would not say
  /// before the device is opened — reporting zero beats reporting a guess.
  final int channels;
  final int sampleRate;

  final bool isDefault;

  /// True only when the backend says this device captures system output.
  /// Windows/WASAPI reports it; elsewhere a virtual loopback is
  /// indistinguishable from a real input, so this stays false and must not be
  /// read as "loopback is impossible here".
  final bool isLoopback;

  @override
  String toString() => 'OaaDevice($name, $channels ch @ $sampleRate Hz)';
}

/// Reads a fixed-size C char array up to its NUL, as UTF-8.
///
/// Two details that are easy to get wrong and both bite immediately on a real
/// machine:
///
///   - `Char` is **signed**, so every byte above 0x7F arrives negative. The
///     mask is not defensive tidying; without it the first device with an
///     accented character in its name throws.
///   - The bytes are UTF-8, not code units. macOS named a device
///     `Mikrofon von "Jonas iPhone"` using typographic quotes, which is three
///     bytes that mean one character — treating them as code points would have
///     produced mojibake rather than a crash, which is worse.
///
/// `allowMalformed` because a device name comes from a driver, and a metering
/// app must not fall over because somebody's interface has a broken string in
/// its firmware.
String _readString(Array<Char> array, int capacity) {
  final bytes = <int>[];
  for (var i = 0; i < capacity; i++) {
    final byte = array[i] & 0xFF;
    if (byte == 0) break;
    bytes.add(byte);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Mirrors `OAA_DEVICE_ID_MAX`.
const int kOaaDeviceIdMax = 256;

/// Mirrors `OAA_DEVICE_NAME_MAX`.
const int kOaaDeviceNameMax = 256;

/// Thrown when the engine cannot be created or started.
class OaaEngineException implements Exception {
  const OaaEngineException(this.message);
  final String message;
  @override
  String toString() => 'OaaEngineException: $message';
}

/// A running measurement engine.
///
/// Create one with [OaaEngine.start] and [dispose] it when done. Instances own
/// a native thread, so leaking one leaks a thread.
///
/// It `implements MeterSource`, which is the whole of what a meter module is
/// allowed to see: the readings and nothing else — no start, no stop, no reset,
/// no device. The other implementation of that interface decodes measurements
/// off a socket for a tablet that has no engine in it at all, and because the
/// modules are written against the interface rather than against this class,
/// the two screens draw from the same painters and cannot drift into
/// disagreeing about what the signal did.
///
/// The dependency points this way deliberately. `oaa_core` still knows nothing
/// about `dart:ffi`; this package knows about one pure-Dart interface.
class OaaEngine implements MeterSource {
  OaaEngine._(
    this._handle,
    Pointer<native.oaa_snapshot> snapshot,
    this._channels,
  ) : _snapshot = snapshot.ref,
      peak = native.oaa_snapshot_peak(snapshot).asTypedList(kOaaMaxChannels),
      rms = native.oaa_snapshot_rms(snapshot).asTypedList(kOaaMaxChannels),
      vu = native.oaa_snapshot_vu(snapshot).asTypedList(kOaaMaxChannels),
      clip = native.oaa_snapshot_clip(snapshot).asTypedList(kOaaMaxChannels),
      spectrum = native
          .oaa_snapshot_spectrum(snapshot)
          .asTypedList(kOaaSpectrumBands),
      spectrumPeak = native
          .oaa_snapshot_spectrum_peak(snapshot)
          .asTypedList(kOaaSpectrumBands),
      spectrumPan = native
          .oaa_snapshot_spectrum_pan(snapshot)
          .asTypedList(kOaaSpectrumBands),
      scope = native
          .oaa_snapshot_scope(snapshot)
          .asTypedList(kOaaScopePoints * 2),
      histogram = native
          .oaa_snapshot_histogram(snapshot)
          .asTypedList(kOaaHistogramBins);

  /// The ABI this Dart code was written against. Mirrors `OAA_ABI_VERSION`.
  static const int expectedAbiVersion = 4;

  final Pointer<native.oaa_engine> _handle;

  /// The snapshot struct view. Cached rather than re-derived from the pointer,
  /// because `Pointer.ref` allocates a fresh view object each time it is read
  /// and this one is read many times per frame.
  final native.oaa_snapshot _snapshot;

  bool _disposed = false;
  int _generation = 0;

  // --- Zero-copy views over the snapshot's arrays --------------------------
  //
  // Built once. Each is a window onto native memory, not a copy: reading is a
  // raw load, and they can be handed straight to `Canvas.drawRawPoints` or
  // `Vertices.raw` without any conversion. Treat them as read-only.

  /// Per-channel peak, dBFS, with meter hold applied.
  @override
  final Float32List peak;

  /// Per-channel RMS, dBFS, with meter decay applied.
  @override
  final Float32List rms;

  /// Per-channel VU deflection, dBFS.
  ///
  /// Average-responding and RMS-calibrated, through a second-order movement —
  /// so it reads below [rms] on peaky material and above nothing at all on a
  /// sine. **0 VU is not 0 dBFS**: the reference level is a property of the
  /// calibration, not of the signal, so the offset is applied where the meter
  /// is drawn.
  @override
  final Float32List vu;

  /// Per-channel count of consecutive full-scale samples.
  @override
  final Uint32List clip;

  /// Spectrum magnitudes, dBFS per log-spaced band.
  @override
  final Float32List spectrum;

  /// Per-band peak hold for [spectrum].
  ///
  /// Held in the engine rather than accumulated here, and that is not
  /// redundancy: a transform runs every hop but a publish carries only the last
  /// one, so a hold computed from what reaches Dart would miss every transient
  /// that landed between two publishes.
  @override
  final Float32List spectrumPeak;

  /// Per-band stereo position, −1 left to +1 right.
  ///
  /// Meaningless for a band with no energy in it — read [spectrum] first and
  /// skip bands at [kOaaDbFloor], because the pan of silence is not a
  /// direction.
  @override
  final Float32List spectrumPan;

  /// The last [kOaaScopePoints] stereo frames, interleaved x=left, y=right,
  /// oldest first.
  ///
  /// Raw sample values, not rotated into goniometer axes — that rotation is a
  /// display choice and belongs in the painter's transform, where it costs
  /// nothing.
  @override
  final Float32List scope;

  /// Fraction of the gated short-term loudness blocks in each of
  /// [kOaaHistogramBins] bins between [kOaaHistogramMinLufs] and
  /// [kOaaHistogramMaxLufs]. Sums to 1, or to 0 before anything is measured.
  @override
  final Float32List histogram;

  /// The engine's version string.
  static String get versionString =>
      native.oaa_version_string().cast<Utf8>().toDartString();

  /// The ABI version of the loaded native library.
  static int get abiVersion => native.oaa_abi_version();

  /// Create and start an engine.
  ///
  /// Throws [OaaEngineException] rather than returning null, because every
  /// failure here is a programming error or a missing platform feature and
  /// none of them are recoverable at the call site.
  static OaaEngine start({
    OaaSource source = OaaSource.testTone,
    int sampleRate = 48000,
    int channels = 2,
    int blockFrames = 0,
    String? deviceId,
  }) {
    // A mismatch means the compiled library and these bindings disagree about
    // the layout of the snapshot. That does not crash — it silently reads the
    // wrong bytes and renders numbers that look entirely plausible. Checking
    // costs one call at startup and is the cheapest insurance in the project.
    final actual = abiVersion;
    if (actual != expectedAbiVersion) {
      throw OaaEngineException(
        'engine ABI $actual, expected $expectedAbiVersion — '
        'the native library is stale, rebuild it',
      );
    }

    final config = calloc<native.oaa_config>();
    final nativeDeviceId = deviceId == null
        ? nullptr
        : deviceId.toNativeUtf8().cast<Char>();
    try {
      native.oaa_config_defaults(config);
      config.ref
        ..sample_rate = sampleRate
        ..channels = channels
        ..source = source.value
        ..block_frames = blockFrames
        ..device_id = nativeDeviceId;

      final handle = native.oaa_engine_create(config);
      if (handle == nullptr) {
        throw OaaEngineException(
          'could not create engine (source: ${source.name}, '
          '$channels ch @ $sampleRate Hz)',
        );
      }

      final snapshot = native.oaa_snapshot_buffer(handle);
      final engine = OaaEngine._(handle, snapshot, channels);

      final status = native.oaa_engine_start(handle);
      if (status != 0) {
        native.oaa_engine_destroy(handle);
        throw OaaEngineException('could not start analysis thread ($status)');
      }
      return engine;
    } finally {
      calloc.free(config);
      if (nativeDeviceId != nullptr) calloc.free(nativeDeviceId);
    }
  }

  /// The capture devices the system currently offers.
  ///
  /// A snapshot: devices come and go, and a stale entry simply fails to open.
  /// Returns empty when there is no audio backend at all, which is an ordinary
  /// state on a headless machine and not an error.
  ///
  /// On Windows, WASAPI can capture the system's own output, so metering
  /// whatever is playing needs no setup. On macOS and Linux an input is a
  /// microphone or line input, and metering system audio needs a virtual
  /// loopback device (BlackHole, Loopback, a PulseAudio/PipeWire monitor) which
  /// then appears here like any other input.
  static List<OaaDevice> devices() {
    final list = native.oaa_devices_enumerate();
    if (list == nullptr) return const [];
    try {
      final count = native.oaa_device_list_count(list);
      return [
        for (var i = 0; i < count; i++)
          if (native.oaa_device_list_at(list, i) case final info
              when info != nullptr)
            OaaDevice._(info.ref),
      ];
    } finally {
      native.oaa_device_list_free(list);
    }
  }

  /// Pull the latest measurements across.
  ///
  /// The only call on the per-frame path. Returns `true` when the engine has
  /// published something new since the previous call — at 120 fps against a
  /// ~47 Hz measurement rate, most frames have nothing new to show, and
  /// skipping those is free.
  @override
  bool refresh() {
    final generation = oaaSnapshotAcquireLeaf(_handle);
    if (generation == _generation) {
      return false;
    }
    _generation = generation;
    return true;
  }

  /// Increments once per published measurement.
  ///
  /// Modules that *accumulate* — a spectrogram column, an afterglow layer, an
  /// infinite peak hold — advance on a change in this rather than once per
  /// `paint`. A paint also happens on a resize, a theme change or an ancestor
  /// marking the subtree dirty, and a spectrogram that scrolled on those would
  /// invent time that no audio passed through.
  @override
  int get generation => _generation;

  /// Measure [interleaved] and publish the result, synchronously.
  ///
  /// Only valid for [OaaSource.push]. On return the readings reflect these
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
    final status = native.oaa_engine_push(_handle, _pushBuffer, frames);
    if (status != 0) {
      throw OaaEngineException(
        'push failed ($status) — is this engine OaaSource.push?',
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
  void reset() => native.oaa_engine_reset(_handle);

  // --- Readings ------------------------------------------------------------
  //
  // A value the current build does not measure is NaN. Callers must check —
  // see [hasLoudness]. Zero is a legitimate reading for correlation, balance
  // and several dB quantities, so it cannot double as "no data".

  @override
  int get sampleRate => _snapshot.sample_rate;
  @override
  int get channels => _snapshot.channels;
  @override
  double get elapsedSeconds => _snapshot.elapsed_seconds;

  @override
  bool get isRunning => _snapshot.flags & 1 != 0;

  /// Frames the capture callback had to discard because analysis fell behind.
  ///
  /// Not a diagnostic. Integrated loudness averages every block since the
  /// reset, so dropped audio does not make the reading stale — it makes it an
  /// average of a different programme than the one that played. Non-zero means
  /// the integrated reading cannot be trusted, and the UI has to say so.
  @override
  int get droppedFrames => _snapshot.dropped_frames;

  /// Whether any audio has been lost since the last reset. Sticky until reset.
  @override
  bool get hasOverrun => _snapshot.flags & (1 << 3) != 0;

  /// Whether the loudness readings are measured in this build.
  ///
  /// True since Phase 1. Kept because it is how a future source that cannot
  /// produce loudness says so, and because an individual reading can still be
  /// NaN when it is not yet *defined* — momentary loudness needs 400 ms of
  /// signal before it means anything.
  @override
  bool get hasLoudness => _snapshot.flags & (1 << 1) == 0;

  /// Whether [spectrum] holds measured data.
  ///
  /// False for the first full transform window — about 85 ms — during which
  /// the bands sit at the floor and are indistinguishable from silence.
  @override
  bool get hasSpectrum => _snapshot.flags & (1 << 2) == 0;

  @override
  double get lufsMomentary => _snapshot.lufs_momentary;
  @override
  double get lufsShort => _snapshot.lufs_short;
  @override
  double get lufsIntegrated => _snapshot.lufs_integrated;
  @override
  double get loudnessRange => _snapshot.lra;

  /// The 10th and 95th percentiles [loudnessRange] is the difference of, and
  /// the relative gate they were taken above. All three are NaN exactly when
  /// [loudnessRange] is.
  ///
  /// A histogram of the distribution without these is a picture rather than a
  /// measurement: the question anybody asks of an LRA of 9 LU is *which* 9 LU.
  @override
  double get loudnessRangeLow => _snapshot.lra_low;
  @override
  double get loudnessRangeHigh => _snapshot.lra_high;
  @override
  double get loudnessRangeGate => _snapshot.lra_gate;

  @override
  double get truePeak => _snapshot.true_peak;
  @override
  double get truePeakMax => _snapshot.true_peak_max;
  @override
  double get samplePeakMax => _snapshot.sample_peak_max;

  @override
  double get dynamicRangeShort => _snapshot.dr_short;
  @override
  double get dynamicRangeIntegrated => _snapshot.dr_integrated;
  @override
  double get crestFactor => _snapshot.crest;
  @override
  double get peakToLoudnessRatio => _snapshot.plr;
  @override
  double get peakToShortTermRatio => _snapshot.psr;

  /// −1 fully out of phase, +1 mono.
  @override
  double get correlation => _snapshot.correlation;

  /// −1 hard left, +1 hard right.
  @override
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
    native.oaa_engine_destroy(_handle);
    if (_pushBuffer != nullptr) {
      calloc.free(_pushBuffer);
      _pushBuffer = nullptr;
      _pushCapacity = 0;
    }
  }
}
