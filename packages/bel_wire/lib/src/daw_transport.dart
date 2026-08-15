/// Decoding for frame type `0x0010`, DAW transport.
///
/// SPDX-License-Identifier: MIT
///
/// `docs/WIRE.md` is normative; this is one implementation of it, and the
/// plugin's `plugin/src/BelWire.cpp` is the other. The two are written against
/// the document rather than against each other, so a change made here that is
/// not made there produces silence rather than an error — which is why the
/// byte-for-byte fixture test exists.
///
/// The producer of these frames is always a plugin: a desktop capturing from an
/// audio device has no transport to report. A consumer that never sees one is
/// therefore in a completely ordinary state, not a degraded one.
library;

import 'dart:typed_data';

import 'package:bel_core/bel_core.dart';

import 'frame.dart';

/// Reads a [Transport] out of a `0x0010` payload.
abstract final class DawTransportCodec {
  /// Payload size, frozen at protocol version 1.
  static const int payloadBytes = 88;

  static const int _offsetFlags = 0;
  static const int _offsetFrameRate = 4;
  static const int _offsetTimeSeconds = 8;
  static const int _offsetPpqPosition = 16;
  static const int _offsetPpqBarStart = 24;
  static const int _offsetBpm = 32;
  static const int _offsetEditOrigin = 40;
  static const int _offsetLoopStart = 48;
  static const int _offsetLoopEnd = 56;
  static const int _offsetTimeSamples = 64;
  static const int _offsetTimeSigNumerator = 72;
  static const int _offsetTimeSigDenominator = 76;
  static const int _offsetHostFrames = 80;

  /// Decodes one transport frame's payload.
  ///
  /// Throws [WireFormatException] on a short payload rather than reading past
  /// it. A frame that is the wrong length means the two ends disagree about the
  /// protocol, and the failure mode of guessing is a plausible-looking playhead
  /// assembled from the wrong bytes.
  static Transport decode(ByteData payload, {int offset = 0}) {
    if (payload.lengthInBytes - offset < payloadBytes) {
      throw WireFormatException(
        'A DAW transport frame needs $payloadBytes bytes, got '
        '${payload.lengthInBytes - offset}.',
      );
    }

    double f64(int at) => payload.getFloat64(offset + at, Endian.little);
    int u32(int at) => payload.getUint32(offset + at, Endian.little);

    return Transport(
      flags: u32(_offsetFlags),
      frameRate: TimecodeFrameRate.fromWire(u32(_offsetFrameRate)),
      timeSeconds: f64(_offsetTimeSeconds),
      ppqPosition: f64(_offsetPpqPosition),
      ppqBarStart: f64(_offsetPpqBarStart),
      bpm: f64(_offsetBpm),
      editOriginSeconds: f64(_offsetEditOrigin),
      loopStartPpq: f64(_offsetLoopStart),
      loopEndPpq: f64(_offsetLoopEnd),
      timeSamples: payload.getInt64(offset + _offsetTimeSamples, Endian.little),
      timeSigNumerator: u32(_offsetTimeSigNumerator),
      timeSigDenominator: u32(_offsetTimeSigDenominator),
      hostFrames: u32(_offsetHostFrames),
    );
  }

  /// Encodes a [Transport] as a complete frame, envelope included.
  ///
  /// The app never sends one of these to a plugin — the link is one-directional
  /// — but a desktop relaying a plugin's session to a tablet does, and the
  /// round trip is what the codec test asserts on.
  static Uint8List encodeFrame(Transport transport) {
    final payload = ByteData(payloadBytes);

    payload
      ..setUint32(_offsetFlags, transport.flags, Endian.little)
      ..setUint32(
        _offsetFrameRate,
        transport.frameRate.wireValue,
        Endian.little,
      )
      ..setFloat64(_offsetTimeSeconds, transport.timeSeconds, Endian.little)
      ..setFloat64(_offsetPpqPosition, transport.ppqPosition, Endian.little)
      ..setFloat64(_offsetPpqBarStart, transport.ppqBarStart, Endian.little)
      ..setFloat64(_offsetBpm, transport.bpm, Endian.little)
      ..setFloat64(
        _offsetEditOrigin,
        transport.editOriginSeconds,
        Endian.little,
      )
      ..setFloat64(_offsetLoopStart, transport.loopStartPpq, Endian.little)
      ..setFloat64(_offsetLoopEnd, transport.loopEndPpq, Endian.little)
      ..setInt64(_offsetTimeSamples, transport.timeSamples, Endian.little)
      ..setUint32(
        _offsetTimeSigNumerator,
        transport.timeSigNumerator,
        Endian.little,
      )
      ..setUint32(
        _offsetTimeSigDenominator,
        transport.timeSigDenominator,
        Endian.little,
      )
      ..setUint32(_offsetHostFrames, transport.hostFrames, Endian.little);

    return WireFrame.encode(
      WireFrameType.dawTransport,
      payload.buffer.asUint8List(),
    );
  }
}
