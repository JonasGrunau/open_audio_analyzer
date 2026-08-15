// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Constants of the framing layer. See `docs/WIRE.md`.
abstract final class WireFrame {
  /// The ASCII bytes `B`, `E`, `L`, `W`, read as a little-endian `u32`.
  ///
  /// A magic number is not decoration here. The first thing a display does with
  /// a stream is decide where a frame starts, and everything downstream — the
  /// length it will allocate, the type it will dispatch on — is wrong in a
  /// quiet, plausible way if it got that wrong. Failing on byte zero is much
  /// better than drawing a shifted spectrum.
  static const int magic = 0x574C4542;

  static const int protocolVersion = 1;

  static const int headerBytes = 12;

  /// The largest payload a receiver will agree to buffer.
  ///
  /// A length field is an instruction to allocate, and one that has been
  /// corrupted in transit or written by something hostile must not be obeyed.
  /// The largest legitimate frame in version 1 is a snapshot at a little over
  /// 15 kB, so this is three orders of magnitude of headroom and still refuses
  /// to turn four bad bytes into a four-gigabyte allocation.
  static const int maxPayloadBytes = 1 << 20;

  static const int _offsetMagic = 0;
  static const int _offsetVersion = 4;
  static const int _offsetType = 6;
  static const int _offsetLength = 8;

  /// Writes a frame header into [into] at [offset]. Returns [headerBytes].
  static int writeHeader(
    ByteData into,
    int type,
    int payloadLength, {
    int offset = 0,
  }) {
    into.setUint32(offset + _offsetMagic, magic, Endian.little);
    into.setUint16(offset + _offsetVersion, protocolVersion, Endian.little);
    into.setUint16(offset + _offsetType, type, Endian.little);
    into.setUint32(offset + _offsetLength, payloadLength, Endian.little);
    return headerBytes;
  }

  /// A complete frame as one allocation, for the frames that are not on the
  /// publish path — hello, layout, skin.
  ///
  /// The snapshot deliberately does not go through here: it is sent tens of
  /// times a second and reuses a buffer instead. See [SnapshotFrame].
  static Uint8List encode(int type, Uint8List payload) {
    final bytes = Uint8List(headerBytes + payload.length);
    writeHeader(ByteData.view(bytes.buffer), type, payload.length);
    bytes.setRange(headerBytes, headerBytes + payload.length, payload);
    return bytes;
  }
}

/// Frame types. The full allocation table is in `docs/WIRE.md`; the ranges
/// belonging to other phases are listed here so that nobody allocates into them
/// by accident.
abstract final class WireFrameType {
  static const int hello = 0x0001;
  static const int layout = 0x0002;
  static const int snapshot = 0x0003;
  static const int skin = 0x0004;

  /// The active delivery target, resolved rather than named.
  ///
  /// It travels for the same reason the skin does: a reading is drawn green,
  /// amber or red by comparing it against a target, so two screens holding
  /// different targets show the same measurement in different colours. On a
  /// tool whose entire job is telling somebody whether a master passes, that is
  /// not a cosmetic difference.
  static const int calibration = 0x0005;

  /// `0x0010`–`0x001F` — DAW transport, sent by the plugin producer.
  static const int dawTransport = 0x0010;

  /// `0x0020`–`0x002F` — reserved for a client→host control channel that does
  /// not exist in version 1, and should not be added without an authentication
  /// story. See the note in `docs/WIRE.md`.
  static const int reservedControlLow = 0x0020;
  static const int reservedControlHigh = 0x002F;
}

/// The stream was not a Bel stream, or was not a Bel stream any more.
class WireFormatException implements Exception {
  WireFormatException(this.message);
  final String message;

  @override
  String toString() => 'WireFormatException: $message';
}

/// Turns a stream of arbitrary byte chunks into whole frames.
///
/// A socket hands over whatever arrived, which is never the frame boundaries: a
/// 15 kB snapshot crosses several TCP segments and two of them can land in one
/// chunk. This accumulates until a frame is complete and then exposes it in
/// place.
///
/// [payload] is a **view into this reader's buffer and is only valid until the
/// next [moveNext]**. That is deliberate: the alternative is copying 15 kB per
/// frame so a caller can hold on to bytes it will have decoded microseconds
/// later. Decode out of the view; do not store it.
class FrameReader {
  FrameReader({int initialCapacity = WireFrame.headerBytes + 16384})
    : _buffer = Uint8List(initialCapacity) {
    _view = ByteData.view(_buffer.buffer);
  }

  Uint8List _buffer;
  late ByteData _view;

  /// Bytes of [_buffer] that hold received data.
  int _filled = 0;

  int _type = 0;
  ByteData? _payload;

  /// The type of the frame [moveNext] last produced.
  int get type => _type;

  /// The payload of the frame [moveNext] last produced. Valid until the next
  /// call to [moveNext].
  ByteData get payload => _payload!;

  /// Appends received bytes.
  void add(List<int> chunk) {
    _reserve(_filled + chunk.length);
    _buffer.setRange(_filled, _filled + chunk.length, chunk);
    _filled += chunk.length;
  }

  /// Advances to the next complete frame, and reports whether there was one.
  ///
  /// Throws [WireFormatException] if the stream is not framed the way this
  /// protocol says it is. That is not recoverable by reading more bytes — a
  /// stream that has lost sync stays lost — so the caller's only correct
  /// response is to drop the connection.
  bool moveNext() {
    _payload = null;

    // Drop the frame the previous call handed out. Doing it here rather than
    // when that call returned is what makes the "valid until the next
    // moveNext" contract true.
    _compact();

    if (_filled < WireFrame.headerBytes) return false;

    final magic = _view.getUint32(0, Endian.little);
    if (magic != WireFrame.magic) {
      throw WireFormatException(
        'not a Bel frame: magic 0x${magic.toRadixString(16)}',
      );
    }

    final version = _view.getUint16(4, Endian.little);
    if (version != WireFrame.protocolVersion) {
      throw WireFormatException(
        'wire protocol version $version, this build speaks '
        '${WireFrame.protocolVersion}',
      );
    }

    final length = _view.getUint32(8, Endian.little);
    if (length > WireFrame.maxPayloadBytes) {
      throw WireFormatException(
        'payload of $length bytes exceeds the ${WireFrame.maxPayloadBytes} '
        'byte limit',
      );
    }

    final total = WireFrame.headerBytes + length;
    if (_filled < total) {
      // Grow now rather than on the next add, so a large frame is one
      // reallocation instead of a series of doublings.
      _reserve(total);
      return false;
    }

    _type = _view.getUint16(6, Endian.little);
    _payload = ByteData.view(_buffer.buffer, WireFrame.headerBytes, length);

    // Consume by shifting the remainder down. The common case is that nothing
    // remains and this is a no-op; the worst case moves the tail of one frame,
    // which is cheaper than the ring-buffer bookkeeping that would avoid it.
    _consumed = total;
    return true;
  }

  int _consumed = 0;

  /// Drops the bytes of the frame most recently returned. Called by [moveNext]
  /// on its next invocation, so a payload view stays valid in between.
  void _compact() {
    if (_consumed == 0) return;
    final remaining = _filled - _consumed;
    // Written as a forward loop rather than setRange because source and
    // destination are the same list. The direction is safe — the destination
    // starts before the source — and being explicit about that beats relying
    // on an overlap guarantee the library does not make.
    for (var i = 0; i < remaining; i++) {
      _buffer[i] = _buffer[_consumed + i];
    }
    _filled = remaining;
    _consumed = 0;
  }

  void _reserve(int needed) {
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _filled, _buffer);
    _buffer = grown;
    _view = ByteData.view(_buffer.buffer);
  }
}
