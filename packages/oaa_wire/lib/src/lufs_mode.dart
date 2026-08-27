// SPDX-License-Identifier: GPL-3.0-or-later

/// `0x0020 SET_LUFS_MODE` — the first frame that travels from consumer to
/// producer.
///
/// The byte table is frozen at protocol version 3 and lives in `docs/WIRE.md`,
/// which is normative. This file and `plugin/src/OaaWire.h` are two
/// implementations of that table and neither was written against the other; the
/// golden in `test/` is what holds them together byte for byte.
///
/// **Ingest port only.** The reasoning is in `docs/WIRE.md` under *They do not
/// have the same trust boundary*, and it is not a detail: the display port
/// binds every interface, so a control channel there would mean anyone on the
/// venue Wi-Fi could restart the engineer's integrated reading — a measurement
/// that is then wrong with nothing on screen saying so. The ingest port binds
/// loopback, where whatever connects is already running as this user. The
/// asymmetry is the whole security model.
library;

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

import 'frame.dart';

/// Encodes and decodes the mode frame.
abstract final class LufsModeCodec {
  /// `mode u32 | flags u32 | region_start f64 | region_end f64`.
  static const int payloadBytes = 24;

  /// The region fields carry a region. Clear means they are zero and ignored.
  static const int flagHasRegion = 1 << 0;

  static const int _offsetMode = 0;
  static const int _offsetFlags = 4;
  static const int _offsetStart = 8;
  static const int _offsetEnd = 16;

  /// The protocol version that defined this frame.
  ///
  /// A producer older than this never reads its socket, so sending it one is
  /// not an error it can report — it is silence. Check a peer's
  /// [FrameReader.version] against this before sending, and report the
  /// transport-driven modes unavailable rather than requesting them.
  static const int requiresVersion = 3;

  static Uint8List encodeFrame(LufsTimeMode mode, {LufsRegion? region}) {
    final payload = ByteData(payloadBytes);
    payload.setUint32(_offsetMode, mode.wireValue, Endian.little);

    final hasRegion = region != null && region.isValid;
    payload.setUint32(
      _offsetFlags,
      hasRegion ? flagHasRegion : 0,
      Endian.little,
    );
    payload.setFloat64(
      _offsetStart,
      hasRegion ? region.startSeconds : 0.0,
      Endian.little,
    );
    payload.setFloat64(
      _offsetEnd,
      hasRegion ? region.endSeconds : 0.0,
      Endian.little,
    );

    return WireFrame.encode(
      WireFrameType.setLufsMode,
      payload.buffer.asUint8List(),
    );
  }

  /// Decodes a payload, or returns null for one this build cannot honour.
  ///
  /// Null rather than an exception, and null rather than a default. A frame
  /// naming a mode from a newer build, or naming `TIMECODE` with no region, is
  /// not a broken connection — it is one instruction that cannot be carried
  /// out, and the producer's answer is to keep the mode it already had. A
  /// default would be worse than either: it would silently measure something
  /// nobody asked for, which is the failure this whole protocol is written to
  /// avoid.
  static LufsModeRequest? decode(ByteData payload, {int offset = 0}) {
    if (payload.lengthInBytes - offset < payloadBytes) return null;

    final mode = LufsTimeMode.fromWireValue(
      payload.getUint32(offset + _offsetMode, Endian.little),
    );
    if (mode == null) return null;

    final flags = payload.getUint32(offset + _offsetFlags, Endian.little);
    final hasRegion = (flags & flagHasRegion) != 0;

    LufsRegion? region;
    if (hasRegion) {
      region = LufsRegion(
        payload.getFloat64(offset + _offsetStart, Endian.little),
        payload.getFloat64(offset + _offsetEnd, Endian.little),
      );
      if (!region.isValid) return null;
    }

    // A region is required for this mode and there is no sane substitute.
    if (mode.needsRegion && region == null) return null;

    return LufsModeRequest(mode, region);
  }
}

/// What a decoded `0x0020` asks for.
class LufsModeRequest {
  const LufsModeRequest(this.mode, this.region);

  final LufsTimeMode mode;

  /// Present exactly when [LufsTimeMode.needsRegion] is true.
  final LufsRegion? region;

  /// Whether this request is the one already in force.
  ///
  /// A producer that reset on every arrival would let a redundant resend
  /// silently restart a measurement somebody was in the middle of taking, so
  /// the comparison covers the region as well as the mode — a moved region in
  /// the same mode *is* a change and does re-arm.
  bool sameAs(LufsModeRequest? other) =>
      other != null && other.mode == mode && other.region == region;

  @override
  bool operator ==(Object other) => other is LufsModeRequest && sameAs(other);

  @override
  int get hashCode => Object.hash(mode, region);

  @override
  String toString() =>
      'LufsModeRequest(${mode.id}${region == null ? '' : ', $region'})';
}
