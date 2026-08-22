// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

import 'frame.dart';
import 'quantise.dart';

/// Byte offsets of the `0x0003 SNAPSHOT` payload, and the encoder that writes
/// it. `docs/WIRE.md` holds the normative table; this is that table as code.
///
/// The layout was derived mechanically from `oaa_snapshot` in
/// `engine/include/oaa/oaa.h`, as that struct stood when the protocol was
/// first written — declaration order, top to bottom, every member including
/// the `reservedN` padding members, natural widths, little-endian, no alignment
/// padding. Deriving it that way is what lets a C++ sender written by somebody
/// who never read this file produce the same bytes.
///
/// **But the derivation is not the definition.** The table was frozen at
/// protocol version 1 and version 2 carries it unchanged — only the magic
/// moved, with the application's name. `oaa_snapshot` will grow fields and bump
/// `OAA_ABI_VERSION`, which is a private matter between the engine and the
/// things that link it; the wire layout moves only when the protocol version
/// moves. Were they the same thing, every engine change would break every
/// display in the field — and break it by drawing wrong numbers rather than by
/// failing, which is worse.
///
/// The offsets below are computed from [MeterShape] rather than written out, so
/// that they cannot drift *among themselves*. `test/snapshot_codec_test.dart`
/// pins the resulting total against the frozen constant, so a change to
/// [MeterShape] fails a test here instead of confusing a tablet later.
abstract final class SnapshotWire {
  static const int _f32 = 4;

  static const int offsetGeneration = 0;
  static const int offsetElapsedSeconds = 8;
  static const int offsetSampleRate = 16;
  static const int offsetChannels = 20;
  static const int offsetFlags = 24;
  static const int offsetDroppedFrames = 28;

  static const int offsetLufsMomentary = 32;
  static const int offsetLufsShort = 36;
  static const int offsetLufsIntegrated = 40;
  static const int offsetLra = 44;

  static const int offsetTruePeak = 48;
  static const int offsetTruePeakMax = 52;
  static const int offsetSamplePeakMax = 56;
  static const int offsetReserved1 = 60;

  static const int offsetDrShort = 64;
  static const int offsetDrIntegrated = 68;
  static const int offsetCrest = 72;
  static const int offsetPlr = 76;
  static const int offsetPsr = 80;
  static const int offsetReserved2 = 84;

  static const int offsetCorrelation = 88;
  static const int offsetBalance = 92;

  static const int _i16 = 2;

  static const int _channelBytes = MeterShape.maxChannels * _f32;

  /// A band is two bytes at protocol version 4 and was four at 1–3. See
  /// [Quantise] for what the two bytes mean and why they are enough.
  static const int _bandBytes = MeterShape.spectrumBands * _i16;

  static const int offsetPeak = 96;
  static const int offsetRms = offsetPeak + _channelBytes;
  static const int offsetVu = offsetRms + _channelBytes;
  static const int offsetClip = offsetVu + _channelBytes;

  static const int offsetSpectrum = offsetClip + _channelBytes;
  static const int offsetSpectrumPeak = offsetSpectrum + _bandBytes;

  static const int offsetLraLow = offsetSpectrumPeak + _bandBytes;
  static const int offsetLraHigh = offsetLraLow + _f32;
  static const int offsetLraGate = offsetLraHigh + _f32;
  static const int offsetReserved3 = offsetLraGate + _f32;

  static const int offsetSpectrumPan = offsetReserved3 + _f32;
  static const int offsetHistogram = offsetSpectrumPan + _bandBytes;

  /// How many stereo pairs of [offsetScope] are this measurement's.
  static const int offsetScopeFrames =
      offsetHistogram + MeterShape.histogramBins * _i16;

  /// **Last, and the only variable-length section in the protocol.** A frame
  /// carries the audio that actually elapsed since the previous one rather
  /// than a fixed block — see `MeterSource.scopeFrames` for what a fixed block
  /// does to an oscilloscope at a link rate slower than the engine's. Last so
  /// that a variable length moves no other offset.
  static const int offsetScope = offsetScopeFrames + 4;

  /// Everything up to and including the scope count. A payload is this plus
  /// four bytes per stereo pair.
  static const int baseBytes = offsetScope;

  static int payloadBytesFor(int scopeFrames) =>
      baseBytes + scopeFrames * 2 * _i16;

  /// The largest payload that can legally arrive.
  static const int maxPayloadBytes =
      baseBytes + MeterShape.maxScopeFrames * 2 * _i16;

  /// What a producer publishing one analysis block per frame sends, which is
  /// every producer that is not relaying — the plugin, and the app's own
  /// engine. It is the number `HELLO` advertises, so that two builds still
  /// compare one integer rather than a range.
  static const int payloadBytes = baseBytes + MeterShape.scopePoints * 2 * _i16;

  // The `OAA_FLAG_*` bits, which is the one place the wire reproduces a
  // detail of the C ABI rather than the interface above it. Reproduced because
  // both ends need the same bit for the same fact, and a `bool` has no bit.
  static const int flagRunning = 1 << 0;
  static const int flagLoudnessUnavailable = 1 << 1;
  static const int flagSpectrumUnavailable = 1 << 2;
  static const int flagOverrun = 1 << 3;

  /// Writes [source]'s current reading into [into] at [offset].
  ///
  /// Field by field rather than a bulk copy of the underlying buffers, and that
  /// is a deliberate trade. A `memcpy` would be faster and would also make this
  /// codec depend on the desktop engine's memory layout — which is exactly the
  /// coupling the wire exists to break, since the sender may be a plugin whose
  /// snapshot lives somewhere else entirely. At the publish rate this is a few
  /// thousand stores tens of times a second, which does not register next to
  /// the socket write that follows it.
  ///
  /// **NaN goes on the wire as NaN.** A field the producer did not measure must
  /// not be normalised to zero or to the dB floor on the way out: zero is a
  /// real reading for correlation, balance and several dB quantities, and a
  /// display that draws a substituted value is showing a number nobody took.
  /// Returns the number of payload bytes written, which varies with the scope
  /// run — see [offsetScope].
  ///
  /// [scope] and [scopeFrames] override what [source] holds, and exist for the
  /// one producer that is relaying rather than measuring: `DisplayHost`
  /// accumulates the audio measured between two sends, so that a link slower
  /// than the engine still carries a contiguous waveform. Everything else
  /// leaves them null and sends the source's own block.
  static int encode(
    MeterSource source,
    ByteData into, {
    int offset = 0,
    Float32List? scope,
    int? scopeFrames,
  }) {
    into.setUint64(offset + offsetGeneration, source.generation, Endian.little);
    into.setFloat64(
      offset + offsetElapsedSeconds,
      source.elapsedSeconds,
      Endian.little,
    );
    into.setUint32(offset + offsetSampleRate, source.sampleRate, Endian.little);
    into.setUint32(offset + offsetChannels, source.channels, Endian.little);

    var flags = 0;
    if (source.isRunning) flags |= flagRunning;
    if (!source.hasLoudness) flags |= flagLoudnessUnavailable;
    if (!source.hasSpectrum) flags |= flagSpectrumUnavailable;
    if (source.hasOverrun) flags |= flagOverrun;
    into.setUint32(offset + offsetFlags, flags, Endian.little);
    into.setUint32(
      offset + offsetDroppedFrames,
      source.droppedFrames,
      Endian.little,
    );

    void f32(int at, double value) =>
        into.setFloat32(offset + at, value, Endian.little);

    f32(offsetLufsMomentary, source.lufsMomentary);
    f32(offsetLufsShort, source.lufsShort);
    f32(offsetLufsIntegrated, source.lufsIntegrated);
    f32(offsetLra, source.loudnessRange);

    f32(offsetTruePeak, source.truePeak);
    f32(offsetTruePeakMax, source.truePeakMax);
    f32(offsetSamplePeakMax, source.samplePeakMax);
    f32(offsetReserved1, 0);

    f32(offsetDrShort, source.dynamicRangeShort);
    f32(offsetDrIntegrated, source.dynamicRangeIntegrated);
    f32(offsetCrest, source.crestFactor);
    f32(offsetPlr, source.peakToLoudnessRatio);
    f32(offsetPsr, source.peakToShortTermRatio);
    f32(offsetReserved2, 0);

    f32(offsetCorrelation, source.correlation);
    f32(offsetBalance, source.balance);

    f32(offsetLraLow, source.loudnessRangeLow);
    f32(offsetLraHigh, source.loudnessRangeHigh);
    f32(offsetLraGate, source.loudnessRangeGate);
    f32(offsetReserved3, 0);

    _writeFloats(into, offset + offsetPeak, source.peak);
    _writeFloats(into, offset + offsetRms, source.rms);
    _writeFloats(into, offset + offsetVu, source.vu);
    _writeUints(into, offset + offsetClip, source.clip);

    _writeDb(into, offset + offsetSpectrum, source.spectrum);
    _writeDb(into, offset + offsetSpectrumPeak, source.spectrumPeak);
    _writeUnits(into, offset + offsetSpectrumPan, source.spectrumPan);
    _writeFractions(into, offset + offsetHistogram, source.histogram);

    final run = scope ?? source.scope;
    var frames = scopeFrames ?? source.scopeFrames;
    if (frames > MeterShape.maxScopeFrames) frames = MeterShape.maxScopeFrames;
    if (frames * 2 > run.length) frames = run.length ~/ 2;
    if (frames < 0) frames = 0;

    into.setUint32(offset + offsetScopeFrames, frames, Endian.little);
    _writeSamples(into, offset + offsetScope, run, frames * 2);

    return payloadBytesFor(frames);
  }

  static void _writeDb(ByteData into, int at, Float32List values) {
    for (var i = 0; i < values.length; i++) {
      into.setUint16(at + i * _i16, Quantise.db(values[i]), Endian.little);
    }
  }

  static void _writeUnits(ByteData into, int at, Float32List values) {
    for (var i = 0; i < values.length; i++) {
      into.setInt16(at + i * _i16, Quantise.unit(values[i]), Endian.little);
    }
  }

  static void _writeSamples(
    ByteData into,
    int at,
    Float32List values, [
    int? count,
  ]) {
    final n = count ?? values.length;
    for (var i = 0; i < n; i++) {
      into.setInt16(at + i * _i16, Quantise.sample(values[i]), Endian.little);
    }
  }

  static void _writeFractions(ByteData into, int at, Float32List values) {
    for (var i = 0; i < values.length; i++) {
      into.setUint16(
        at + i * _i16,
        Quantise.fraction(values[i]),
        Endian.little,
      );
    }
  }

  static void _writeFloats(ByteData into, int at, Float32List values) {
    for (var i = 0; i < values.length; i++) {
      into.setFloat32(at + i * _f32, values[i], Endian.little);
    }
  }

  static void _writeUints(ByteData into, int at, Uint32List values) {
    for (var i = 0; i < values.length; i++) {
      into.setUint32(at + i * _f32, values[i], Endian.little);
    }
  }
}

/// The `0x0003 SNAPSHOT` table exactly as protocol versions 1 to 3 froze it.
///
/// **Decode only, and it is not dead weight.** `WireFrame.minimumVersion` is 2
/// because a plugin lives in the DAW's plugin folder across app upgrades, so an
/// app one version ahead of the plugin is the normal case and not an error —
/// `docs/WIRE.md` says so normatively. Version 4 changed the five plotted
/// arrays from `float32` to fixed point, which moves every offset after the
/// per-channel block, so honouring that promise means being able to read the
/// old table as well as write the new one.
///
/// Nothing writes this. A version 4 producer sends version 4; this is what a
/// version 4 *consumer* uses when the producer announced 15,056 bytes.
abstract final class SnapshotWireLegacy {
  static const int _f32 = 4;
  static const int _channelBytes = MeterShape.maxChannels * _f32;
  static const int _bandBytes = MeterShape.spectrumBands * _f32;

  // Everything up to the end of `clip` is identical to version 4 and is read
  // through `SnapshotWire`'s constants; only what follows moved.
  static const int offsetSpectrum = SnapshotWire.offsetClip + _channelBytes;
  static const int offsetSpectrumPeak = offsetSpectrum + _bandBytes;

  static const int offsetLraLow = offsetSpectrumPeak + _bandBytes;
  static const int offsetLraHigh = offsetLraLow + _f32;
  static const int offsetLraGate = offsetLraHigh + _f32;
  static const int offsetReserved3 = offsetLraGate + _f32;

  static const int offsetSpectrumPan = offsetReserved3 + _f32;
  static const int offsetScope = offsetSpectrumPan + _bandBytes;
  static const int offsetHistogram =
      offsetScope + MeterShape.scopePoints * 2 * _f32;

  /// 15,056 — the size a version 1 to 3 producer announces in its `HELLO`.
  static const int payloadBytes =
      offsetHistogram + MeterShape.histogramBins * _f32;
}

/// One reusable snapshot frame, header and all.
///
/// The host sends one of these tens of times a second forever, so it allocates
/// the buffer once and rewrites the payload in place. The header never changes
/// after construction — same magic, same version, same type, same length — so
/// it is written once too.
///
/// A caller must not hand the same instance to a socket twice before the first
/// write has flushed: `Socket.add` keeps the reference rather than copying, so
/// overwriting the payload underneath a pending write puts half of one
/// measurement and half of another on the wire. The host keeps a small ring of
/// these for exactly that reason — see `lib/src/remote/display_host.dart`.
class SnapshotFrame {
  SnapshotFrame();

  /// Allocated at the largest a frame may be and only partly used, because the
  /// scope run varies per frame and the host must not allocate on the send
  /// path. [wire] is the part to write.
  final Uint8List bytes = Uint8List(
    WireFrame.headerBytes + SnapshotWire.maxPayloadBytes,
  );

  late final ByteData _view = ByteData.view(bytes.buffer);

  int _length = 0;
  Uint8List? _wire;

  /// The bytes of the last [encode] — header and payload, ready for a socket.
  ///
  /// A view rather than a copy, rebuilt only when the length changes. A
  /// contiguous scope run is the same length frame after frame unless the link
  /// rate or the sample rate moves, so in the steady state this allocates
  /// nothing.
  Uint8List get wire => _wire ??= Uint8List.view(bytes.buffer, 0, _length);

  /// Overwrites the payload with [source]'s current reading.
  ///
  /// [scope] and [scopeFrames] are the relay case; see [SnapshotWire.encode].
  void encode(MeterSource source, {Float32List? scope, int? scopeFrames}) {
    final payload = SnapshotWire.encode(
      source,
      _view,
      offset: WireFrame.headerBytes,
      scope: scope,
      scopeFrames: scopeFrames,
    );

    // The header carries the length, so it is rewritten whenever that moves.
    WireFrame.writeHeader(_view, WireFrameType.snapshot, payload);

    final total = WireFrame.headerBytes + payload;
    if (total != _length) {
      _length = total;
      _wire = null;
    }
  }
}
