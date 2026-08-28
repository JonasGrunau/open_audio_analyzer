/// Dart access to the Open Audio Analyzer measurement engine.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
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

/// The band-to-frequency mapping, which now lives in `oaa_core` beside
/// `MeterShape` — the fourteen modules draw a frequency axis from it and must
/// not import this library to do so, because the remote display runs the same
/// modules with no engine at all. Re-exported rather than moved silently so
/// that the CLI, the plugin and this package's own tests keep reading it where
/// they always have, and so there is still exactly one definition.
export 'package:oaa_core/oaa_core.dart'
    show SpectrumSource, bandCentreHz, bandOfHz;

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

  /// True only when this device certainly captures the system's own output.
  ///
  /// Set for WASAPI's loopback devices, which report it natively, and for the
  /// macOS process tap. It stays false for a *virtual* loopback — BlackHole, a
  /// PipeWire monitor — which is indistinguishable from a real input, so a
  /// false here says nothing about whether some other device in the list also
  /// captures system output.
  final bool isLoopback;

  /// True for the macOS Core Audio process tap, which is not a piece of
  /// hardware: it captures whatever is being sent to the default output device,
  /// with no driver installed and without rerouting the audio away from the
  /// speakers.
  ///
  /// Present only on macOS 14.2 and later. Everywhere else the entry is simply
  /// absent from [OaaEngine.devices] — on Windows because WASAPI loopback
  /// already appears as an ordinary capture device, and on Linux because a
  /// PipeWire or PulseAudio monitor source does.
  bool get isSystemOutput => id == kOaaSystemOutputDeviceId;

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

/// Mirrors `OAA_DEVICE_ID_SYSTEM_OUTPUT` — the one device id that is a reserved
/// word rather than a hex-encoded platform handle.
///
/// Pass it as `deviceId` to meter the system's own output. [OaaEngine.devices]
/// offers it only where it works, so callers should look for it in the list
/// rather than hard-coding it into a source menu; see [OaaDevice.isSystemOutput].
const String kOaaSystemOutputDeviceId = 'system-output';

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
      _spectrumLeft = _sourceView(snapshot, SpectrumSource.left),
      _spectrumLeftPeak = _sourcePeakView(snapshot, SpectrumSource.left),
      _spectrumRight = _sourceView(snapshot, SpectrumSource.right),
      _spectrumRightPeak = _sourcePeakView(snapshot, SpectrumSource.right),
      _spectrumMid = _sourceView(snapshot, SpectrumSource.mid),
      _spectrumMidPeak = _sourcePeakView(snapshot, SpectrumSource.mid),
      _spectrumSide = _sourceView(snapshot, SpectrumSource.side),
      _spectrumSidePeak = _sourcePeakView(snapshot, SpectrumSource.side),
      scope = native
          .oaa_snapshot_scope(snapshot)
          .asTypedList(kOaaScopePoints * 2),
      histogram = native
          .oaa_snapshot_histogram(snapshot)
          .asTypedList(kOaaHistogramBins);

  /// The ABI this Dart code was written against. Mirrors `OAA_ABI_VERSION`.
  static const int expectedAbiVersion = 6;

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

  /// [spectrum] and [spectrumPeak] on each of the four signals a stereo pair
  /// can be read as. Views like the rest, built once from the accessors the
  /// header exports for them — NaN throughout on a one-channel engine for
  /// the three it cannot make, which [spectrumOf]'s contract promises.
  final Float32List _spectrumLeft;
  final Float32List _spectrumLeftPeak;
  final Float32List _spectrumRight;
  final Float32List _spectrumRightPeak;
  final Float32List _spectrumMid;
  final Float32List _spectrumMidPeak;
  final Float32List _spectrumSide;
  final Float32List _spectrumSidePeak;

  @override
  Float32List spectrumOf(SpectrumSource source) => switch (source) {
    SpectrumSource.all => spectrum,
    SpectrumSource.left => _spectrumLeft,
    SpectrumSource.right => _spectrumRight,
    SpectrumSource.mid => _spectrumMid,
    SpectrumSource.side => _spectrumSide,
  };

  @override
  Float32List spectrumPeakOf(SpectrumSource source) => switch (source) {
    SpectrumSource.all => spectrumPeak,
    SpectrumSource.left => _spectrumLeftPeak,
    SpectrumSource.right => _spectrumRightPeak,
    SpectrumSource.mid => _spectrumMidPeak,
    SpectrumSource.side => _spectrumSidePeak,
  };

  /// The C constant for [source] — `oaa_spectrum_source`, which the header
  /// carries as an `int32_t` so that the width of an enum never reaches the
  /// ABI. The two enums are kept in the same order, and this is the one
  /// place that order is relied on.
  static int _sourceCode(SpectrumSource source) => switch (source) {
    SpectrumSource.all => native.oaa_spectrum_source.OAA_SPECTRUM_ALL.value,
    SpectrumSource.left => native.oaa_spectrum_source.OAA_SPECTRUM_LEFT.value,
    SpectrumSource.right => native.oaa_spectrum_source.OAA_SPECTRUM_RIGHT.value,
    SpectrumSource.mid => native.oaa_spectrum_source.OAA_SPECTRUM_MID.value,
    SpectrumSource.side => native.oaa_spectrum_source.OAA_SPECTRUM_SIDE.value,
  };

  static Float32List _sourceView(
    Pointer<native.oaa_snapshot> snapshot,
    SpectrumSource source,
  ) => native
      .oaa_snapshot_spectrum_of(snapshot, _sourceCode(source))
      .asTypedList(kOaaSpectrumBands);

  static Float32List _sourcePeakView(
    Pointer<native.oaa_snapshot> snapshot,
    SpectrumSource source,
  ) => native
      .oaa_snapshot_spectrum_peak_of(snapshot, _sourceCode(source))
      .asTypedList(kOaaSpectrumBands);

  /// The last [kOaaScopePoints] stereo frames, interleaved x=left, y=right,
  /// oldest first.
  ///
  /// Raw sample values, not rotated into goniometer axes — that rotation is a
  /// display choice and belongs in the painter's transform, where it costs
  /// nothing.
  @override
  final Float32List scope;

  /// Always one analysis block: an engine publishes a snapshot per block, so
  /// the whole of [scope] is always this measurement's. It varies only over a
  /// wire — see `MeterSource.scopeFrames`.
  @override
  int get scopeFrames => MeterShape.scopePoints;

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
  /// Metering the system's own output needs no setup on any current desktop,
  /// and the entry to look for differs by platform. On Windows, WASAPI's
  /// loopback devices appear here directly. On macOS 14.2 and later a Core
  /// Audio process tap appears as [OaaDevice.isSystemOutput], first in the
  /// list. On Linux a PulseAudio or PipeWire monitor source appears like any
  /// other input.
  ///
  /// What is left uncovered is macOS below 14.2, where it still takes a virtual
  /// loopback device — BlackHole, Loopback — which then appears here like any
  /// other input and cannot be told apart from one.
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
    // A disposed engine publishes nothing and reads as unavailable. It is not
    // defensive tidying: the handle is freed, so acquiring through it is a read
    // of returned heap that would land plausible wrong numbers on screen rather
    // than crashing. Somebody *will* hold this object one frame too long — the
    // remote display's publish timer did, across a device change — and the
    // difference between em dashes and 15 kB of reused memory is worth one
    // comparison per frame.
    if (_disposed) return false;

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
    if (_disposed) {
      throw const OaaEngineException('this engine has been disposed');
    }
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
  void reset() {
    if (_disposed) return;
    native.oaa_engine_reset(_handle);
  }

  /// Reset automatically when the signal returns after a silence.
  ///
  /// This is what [LufsTimeMode.system] is made of, and the engine is where it
  /// lives so that a plugin in a DAW and a sound card get one implementation of
  /// "when did this track begin" rather than two. The other three modes need a
  /// playhead and are decided above the engine — see `docs/WIRE.md` `0x0020`.
  ///
  /// Off unless somebody asks. File analysis in particular must never have it
  /// on: a reset partway through would report a different programme than the
  /// one that was measured.
  set silenceReset(bool enabled) {
    if (_disposed) return;
    native.oaa_engine_set_silence_reset(_handle, enabled ? 1 : 0);
  }

  // --- Readings ------------------------------------------------------------
  //
  // A value the current build does not measure is NaN. Callers must check —
  // see [hasLoudness]. Zero is a legitimate reading for correlation, balance
  // and several dB quantities, so it cannot double as "no data".

  @override
  int get sampleRate => _disposed ? 0 : _snapshot.sample_rate;
  @override
  int get channels => _disposed ? 0 : _snapshot.channels;
  @override
  double get elapsedSeconds => _disposed ? 0 : _snapshot.elapsed_seconds;

  @override
  bool get isRunning => !_disposed && _snapshot.flags & 1 != 0;

  /// Frames of audio that never reached the measurement, since the last reset.
  ///
  /// Not a diagnostic. Integrated loudness averages every block since the
  /// reset, so lost audio does not make the reading stale — it makes it an
  /// average of a different programme than the one that played. Non-zero means
  /// the integrated reading cannot be trusted, and the UI has to say so.
  ///
  /// Counts both audio the capture callback had to discard because analysis
  /// fell behind, and audio missed while the source was stopped — see
  /// [isSourceStopped]. The second is derived from a clock rather than counted
  /// by the ring, so it is approximate; a gap reported as zero frames would be
  /// a gap nobody is told about.
  @override
  int get droppedFrames => _disposed ? 0 : _snapshot.dropped_frames;

  /// Whether any audio has been lost since the last reset. Sticky until reset.
  @override
  bool get hasOverrun => !_disposed && _snapshot.flags & (1 << 3) != 0;

  /// Whether the capture source has stopped producing audio.
  ///
  /// Not on [MeterSource], and that is deliberate. The two things that can act
  /// on this — reopening the source, or telling the user which device went
  /// away — are things only the machine holding the device can do; a remote
  /// display has no device, no source menu and nothing it could offer. What a
  /// display sees is what it should see: the desktop reopening the source, and
  /// em dashes if that fails.
  ///
  /// Live rather than sticky, unlike [hasOverrun]: it describes the source now.
  /// The audio the outage cost stays in [droppedFrames] after it clears.
  ///
  /// Only ever true for [OaaSource.device]. Nothing else has a producer that
  /// can leave.
  bool get isSourceStopped => !_disposed && _snapshot.flags & (1 << 4) != 0;

  /// Whether the loudness readings are measured in this build.
  ///
  /// True since Phase 1. Kept because it is how a future source that cannot
  /// produce loudness says so, and because an individual reading can still be
  /// NaN when it is not yet *defined* — momentary loudness needs 400 ms of
  /// signal before it means anything.
  @override
  bool get hasLoudness => !_disposed && _snapshot.flags & (1 << 1) == 0;

  /// Whether [spectrum] holds measured data.
  ///
  /// False for the first full transform window — about 85 ms — during which
  /// the bands sit at the floor and are indistinguishable from silence.
  @override
  bool get hasSpectrum => !_disposed && _snapshot.flags & (1 << 2) == 0;

  @override
  /// Always [Transport.none]. An audio device has no playhead, and the engine
  /// must not learn what one is — the DAW's transport reaches the application
  /// over the wire, beside the measurements rather than inside them.
  @override
  Transport get transport => Transport.none;

  @override
  double get lufsMomentary => _disposed ? double.nan : _snapshot.lufs_momentary;
  @override
  double get lufsShort => _disposed ? double.nan : _snapshot.lufs_short;
  @override
  double get lufsIntegrated =>
      _disposed ? double.nan : _snapshot.lufs_integrated;
  @override
  double get loudnessRange => _disposed ? double.nan : _snapshot.lra;

  /// The 10th and 95th percentiles [loudnessRange] is the difference of, and
  /// the relative gate they were taken above. All three are NaN exactly when
  /// [loudnessRange] is.
  ///
  /// A histogram of the distribution without these is a picture rather than a
  /// measurement: the question anybody asks of an LRA of 9 LU is *which* 9 LU.
  @override
  double get loudnessRangeLow => _disposed ? double.nan : _snapshot.lra_low;
  @override
  double get loudnessRangeHigh => _disposed ? double.nan : _snapshot.lra_high;
  @override
  double get loudnessRangeGate => _disposed ? double.nan : _snapshot.lra_gate;

  @override
  double get truePeak => _disposed ? double.nan : _snapshot.true_peak;
  @override
  double get truePeakMax => _disposed ? double.nan : _snapshot.true_peak_max;
  @override
  double get samplePeakMax =>
      _disposed ? double.nan : _snapshot.sample_peak_max;

  @override
  double get crestFactor => _disposed ? double.nan : _snapshot.crest;
  @override
  double get odrIntegrated => _disposed ? double.nan : _snapshot.plr;
  @override
  double get odrShort => _disposed ? double.nan : _snapshot.psr;

  /// −1 fully out of phase, +1 mono.
  @override
  double get correlation => _disposed ? double.nan : _snapshot.correlation;

  /// −1 hard left, +1 hard right.
  @override
  double get balance => _disposed ? double.nan : _snapshot.balance;

  /// Stop the analysis thread and release the engine.
  ///
  /// Idempotent. Afterwards every scalar reading reports itself unavailable —
  /// NaN, false, zero — and [refresh] returns false forever, so a holder that
  /// keeps this object one frame too long draws em dashes instead of numbers
  /// taken from freed memory. That guard is one comparison per read and it is
  /// there because the mistake is easy: an engine is replaced whenever the
  /// source changes, and anything still pointing at the old one is pointing at
  /// returned heap.
  ///
  /// **The array views cannot be guarded and are invalid the instant this
  /// returns.** [peak], [spectrum], [scope] and the rest are windows onto the
  /// snapshot inside the native allocation, and a `Float32List` has no way to
  /// revoke itself; the contract that their identity never changes is what
  /// makes them free to read on the paint path, and it is also what stops them
  /// being swapped for something inert here. So a disposed engine must not be
  /// held at all. Drop the reference in the same frame that disposes it.
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
