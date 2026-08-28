// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

import 'quantise.dart';
import 'snapshot_codec.dart';

/// A [MeterSource] whose measurements arrived over a socket.
///
/// The other implementation of [MeterSource] is `OaaEngine`, where every array
/// is a window onto memory a C analysis thread owns. This one owns ordinary
/// Dart lists and fills them from decoded frames — but it meets the same
/// contract, and the important half of that contract is that **the arrays are
/// allocated once and never replaced**. A decode overwrites their contents. A
/// painter that held `spectrum` across a frame still holds the right list, and
/// nothing on the paint path allocates.
///
/// That is what makes the fourteen modules run unmodified on a tablet with no
/// engine in it, which is the entire point of the remote display: the meters
/// are not reimplemented, so they cannot disagree with the desktop's.
class WireSnapshot implements MeterSource {
  /// Starts stale, because it is: nothing has arrived yet, and a display that
  /// has not heard from a host must not open on a screen of zeroes that look
  /// like a measured silence.
  WireSnapshot() {
    _clear();
  }

  @override
  final Float32List peak = Float32List(MeterShape.maxChannels);

  @override
  final Float32List rms = Float32List(MeterShape.maxChannels);

  @override
  final Float32List vu = Float32List(MeterShape.maxChannels);

  @override
  final Uint32List clip = Uint32List(MeterShape.maxChannels);

  @override
  final Float32List spectrum = Float32List(MeterShape.spectrumBands);

  @override
  final Float32List spectrumPeak = Float32List(MeterShape.spectrumBands);

  @override
  final Float32List spectrumPan = Float32List(MeterShape.spectrumBands);

  @override
  /// Allocated at the largest a frame may carry, and only partly filled — read
  /// [scopeFrames], never `scope.length`. Allocated once like every array here,
  /// because a painter may hold it across a frame.
  final Float32List scope = Float32List(MeterShape.maxScopeFrames * 2);

  @override
  int get scopeFrames => _scopeFrames;
  int _scopeFrames = 0;

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  /// The playhead of the DAW behind whoever is sending these measurements.
  ///
  /// **Set from outside, because it does not ride in the snapshot frame.** The
  /// transport is its own frame type — `0x0010`, see `docs/WIRE.md` — sent by
  /// a plugin producer and forwarded to displays, and a source that is an audio
  /// device never sends one at all. Whoever decodes that frame writes it here;
  /// [markStale] takes it away again, because a link that has gone quiet is not
  /// a link whose playhead is parked.
  @override
  Transport transport = Transport.none;

  int _generation = 0;
  int _seenGeneration = 0;

  double _elapsedSeconds = 0;
  int _sampleRate = 0;
  int _channels = 0;
  int _flags = 0;
  int _droppedFrames = 0;

  double _lufsMomentary = double.nan;
  double _lufsShort = double.nan;
  double _lufsIntegrated = double.nan;
  double _lra = double.nan;
  double _lraLow = double.nan;
  double _lraHigh = double.nan;
  double _lraGate = double.nan;

  double _truePeak = double.nan;
  double _truePeakMax = double.nan;
  double _samplePeakMax = double.nan;

  double _crest = double.nan;
  double _plr = double.nan;
  double _psr = double.nan;

  double _correlation = double.nan;
  double _balance = double.nan;

  /// Whether the link has gone quiet. See [markStale].
  bool get isStale => _stale;
  bool _stale = true;

  /// Fills this snapshot from a `0x0003 SNAPSHOT` payload.
  ///
  /// Throws [ArgumentError] on a payload that is not the size this build
  /// expects. In practice the handshake has already refused such a producer —
  /// `HELLO` carries the payload size for exactly this reason — so reaching
  /// here means something ignored it, and decoding a differently shaped frame
  /// would produce a screen of plausible wrong numbers.
  void decode(ByteData payload, {int offset = 0}) {
    final available = payload.lengthInBytes - offset;

    // Which table this frame is written in. A version 1-3 producer — an older
    // plugin, which `WireFrame.minimumVersion` exists to keep working — sends
    // the 15,056-byte one, and the difference is visible in the length alone.
    // Dispatching on the size rather than on a remembered handshake keeps the
    // decision beside the bytes it is about.
    final legacy = available == SnapshotWireLegacy.payloadBytes;

    if (!legacy &&
        (available < SnapshotWire.baseBytes ||
            available > SnapshotWire.maxPayloadBytes ||
            (available - SnapshotWire.baseBytes) % 4 != 0)) {
      throw ArgumentError(
        'snapshot payload is $available bytes, which is neither the version '
        '1-3 size of ${SnapshotWireLegacy.payloadBytes} nor '
        '${SnapshotWire.baseBytes} plus four bytes a stereo pair',
      );
    }

    double f32(int at) => payload.getFloat32(offset + at, Endian.little);

    _generation = payload.getUint64(
      offset + SnapshotWire.offsetGeneration,
      Endian.little,
    );
    _elapsedSeconds = payload.getFloat64(
      offset + SnapshotWire.offsetElapsedSeconds,
      Endian.little,
    );
    _sampleRate = payload.getUint32(
      offset + SnapshotWire.offsetSampleRate,
      Endian.little,
    );
    _channels = payload.getUint32(
      offset + SnapshotWire.offsetChannels,
      Endian.little,
    );
    _flags = payload.getUint32(
      offset + SnapshotWire.offsetFlags,
      Endian.little,
    );
    _droppedFrames = payload.getUint32(
      offset + SnapshotWire.offsetDroppedFrames,
      Endian.little,
    );

    _lufsMomentary = f32(SnapshotWire.offsetLufsMomentary);
    _lufsShort = f32(SnapshotWire.offsetLufsShort);
    _lufsIntegrated = f32(SnapshotWire.offsetLufsIntegrated);
    _lra = f32(SnapshotWire.offsetLra);
    _lraLow = f32(
      legacy ? SnapshotWireLegacy.offsetLraLow : SnapshotWire.offsetLraLow,
    );
    _lraHigh = f32(
      legacy ? SnapshotWireLegacy.offsetLraHigh : SnapshotWire.offsetLraHigh,
    );
    _lraGate = f32(
      legacy ? SnapshotWireLegacy.offsetLraGate : SnapshotWire.offsetLraGate,
    );

    _truePeak = f32(SnapshotWire.offsetTruePeak);
    _truePeakMax = f32(SnapshotWire.offsetTruePeakMax);
    _samplePeakMax = f32(SnapshotWire.offsetSamplePeakMax);

    // `dr_short` and `dr_integrated` are read from nothing: the layout has two
    // slots per dynamics reading from when there were two names for each, and
    // every producer writes the same value to both. See the codec.
    _crest = f32(SnapshotWire.offsetCrest);
    _plr = f32(SnapshotWire.offsetPlr);
    _psr = f32(SnapshotWire.offsetPsr);

    _correlation = f32(SnapshotWire.offsetCorrelation);
    _balance = f32(SnapshotWire.offsetBalance);

    _readFloats(payload, offset + SnapshotWire.offsetPeak, peak);
    _readFloats(payload, offset + SnapshotWire.offsetRms, rms);
    _readFloats(payload, offset + SnapshotWire.offsetVu, vu);
    _readUints(payload, offset + SnapshotWire.offsetClip, clip);

    if (legacy) {
      _readFloats(
        payload,
        offset + SnapshotWireLegacy.offsetSpectrum,
        spectrum,
      );
      _readFloats(
        payload,
        offset + SnapshotWireLegacy.offsetSpectrumPeak,
        spectrumPeak,
      );
      _readFloats(
        payload,
        offset + SnapshotWireLegacy.offsetSpectrumPan,
        spectrumPan,
      );
      _readFloats(
        payload,
        offset + SnapshotWireLegacy.offsetScope,
        scope,
        MeterShape.scopePoints * 2,
      );
      _scopeFrames = MeterShape.scopePoints;
      _readFloats(
        payload,
        offset + SnapshotWireLegacy.offsetHistogram,
        histogram,
      );
    } else {
      // Fixed-point at protocol version 4; see [Quantise] for the widths and
      // for how NaN survives them.
      _readDb(payload, offset + SnapshotWire.offsetSpectrum, spectrum);
      _readDb(payload, offset + SnapshotWire.offsetSpectrumPeak, spectrumPeak);
      _readUnits(payload, offset + SnapshotWire.offsetSpectrumPan, spectrumPan);
      _readFractions(payload, offset + SnapshotWire.offsetHistogram, histogram);

      // Trusted only as far as the length agrees with it. A count that does not
      // match the bytes is a producer this build does not understand, and
      // reading past the payload would draw whatever the last frame left there.
      var frames = payload.getUint32(
        offset + SnapshotWire.offsetScopeFrames,
        Endian.little,
      );
      if (SnapshotWire.payloadBytesFor(frames) != available) {
        throw ArgumentError(
          'snapshot says $frames stereo pairs, which is not $available bytes',
        );
      }
      if (frames > MeterShape.maxScopeFrames) {
        frames = MeterShape.maxScopeFrames;
      }
      _scopeFrames = frames;
      _readSamples(
        payload,
        offset + SnapshotWire.offsetScope,
        scope,
        frames * 2,
      );
    }

    _stale = false;
  }

  /// The link has gone quiet: no snapshot has arrived for long enough that
  /// nothing on screen can be claimed to be current.
  ///
  /// Every reading becomes NaN and both availability flags go false, so the
  /// modules render em dashes and "unavailable" the same way they would for a
  /// measurement this build cannot take. The last frame is **not** left on
  /// screen, and that is the whole reason this method exists: a frozen meter is
  /// indistinguishable from a quiet passage, so a display left running after
  /// its host slept would show a confident, detailed picture of a signal that
  /// stopped existing minutes ago.
  ///
  /// The arrays go to NaN rather than to the dB floor for the same reason —
  /// a spectrum flat along the bottom is a picture of silence, and silence is a
  /// measurement we did not take.
  void markStale() {
    if (_stale) return;
    _stale = true;

    // Bumped so that refresh() reports one more change and the meters repaint
    // into their unavailable state instead of holding the last good frame.
    _generation++;
    _clear();
  }

  void _clear() {
    transport = Transport.none;
    _elapsedSeconds = double.nan;
    _flags =
        SnapshotWire.flagLoudnessUnavailable |
        SnapshotWire.flagSpectrumUnavailable;

    _lufsMomentary = double.nan;
    _lufsShort = double.nan;
    _lufsIntegrated = double.nan;
    _lra = double.nan;
    _lraLow = double.nan;
    _lraHigh = double.nan;
    _lraGate = double.nan;
    _truePeak = double.nan;
    _truePeakMax = double.nan;
    _samplePeakMax = double.nan;
    _crest = double.nan;
    _plr = double.nan;
    _psr = double.nan;
    _correlation = double.nan;
    _balance = double.nan;

    peak.fillRange(0, peak.length, double.nan);
    rms.fillRange(0, rms.length, double.nan);
    vu.fillRange(0, vu.length, double.nan);
    clip.fillRange(0, clip.length, 0);
    spectrum.fillRange(0, spectrum.length, double.nan);
    spectrumPeak.fillRange(0, spectrumPeak.length, double.nan);
    spectrumPan.fillRange(0, spectrumPan.length, double.nan);
    scope.fillRange(0, scope.length, double.nan);
    // A block's worth of NaN rather than nothing, so the trail-keeping modules
    // are handed the unavailable state and clear rather than holding their last
    // picture — which is the whole point of going stale. See [markStale].
    _scopeFrames = MeterShape.scopePoints;
    histogram.fillRange(0, histogram.length, double.nan);
  }

  static void _readDb(ByteData from, int at, Float32List into) {
    for (var i = 0; i < into.length; i++) {
      into[i] = Quantise.dbBack(from.getUint16(at + i * 2, Endian.little));
    }
  }

  static void _readUnits(ByteData from, int at, Float32List into) {
    for (var i = 0; i < into.length; i++) {
      into[i] = Quantise.unitBack(from.getInt16(at + i * 2, Endian.little));
    }
  }

  static void _readSamples(
    ByteData from,
    int at,
    Float32List into, [
    int? count,
  ]) {
    for (var i = 0; i < (count ?? into.length); i++) {
      into[i] = Quantise.sampleBack(from.getInt16(at + i * 2, Endian.little));
    }
  }

  static void _readFractions(ByteData from, int at, Float32List into) {
    for (var i = 0; i < into.length; i++) {
      into[i] = Quantise.fractionBack(
        from.getUint16(at + i * 2, Endian.little),
      );
    }
  }

  static void _readFloats(
    ByteData from,
    int at,
    Float32List into, [
    int? count,
  ]) {
    for (var i = 0; i < (count ?? into.length); i++) {
      into[i] = from.getFloat32(at + i * 4, Endian.little);
    }
  }

  static void _readUints(ByteData from, int at, Uint32List into) {
    for (var i = 0; i < into.length; i++) {
      into[i] = from.getUint32(at + i * 4, Endian.little);
    }
  }

  @override
  bool refresh() {
    if (_generation == _seenGeneration) return false;
    _seenGeneration = _generation;
    return true;
  }

  @override
  int get generation => _generation;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get channels => _channels;

  @override
  double get elapsedSeconds => _elapsedSeconds;

  @override
  bool get isRunning => !_stale && _flags & SnapshotWire.flagRunning != 0;

  @override
  int get droppedFrames => _droppedFrames;

  @override
  bool get hasOverrun => _flags & SnapshotWire.flagOverrun != 0;

  @override
  bool get hasLoudness => _flags & SnapshotWire.flagLoudnessUnavailable == 0;

  @override
  bool get hasSpectrum => _flags & SnapshotWire.flagSpectrumUnavailable == 0;

  @override
  double get lufsMomentary => _lufsMomentary;

  @override
  double get lufsShort => _lufsShort;

  @override
  double get lufsIntegrated => _lufsIntegrated;

  @override
  double get loudnessRange => _lra;

  @override
  double get loudnessRangeLow => _lraLow;

  @override
  double get loudnessRangeHigh => _lraHigh;

  @override
  double get loudnessRangeGate => _lraGate;

  @override
  double get truePeak => _truePeak;

  @override
  double get truePeakMax => _truePeakMax;

  @override
  double get samplePeakMax => _samplePeakMax;

  @override
  double get crestFactor => _crest;

  @override
  double get odrIntegrated => _plr;

  @override
  double get odrShort => _psr;

  @override
  double get correlation => _correlation;

  @override
  double get balance => _balance;
}
