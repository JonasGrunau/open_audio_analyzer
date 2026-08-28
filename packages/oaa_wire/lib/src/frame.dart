// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// Constants of the framing layer. See `docs/WIRE.md`.
abstract final class WireFrame {
  /// The ASCII bytes `O`, `A`, `A`, `W`, read as a little-endian `u32`.
  ///
  /// This is the one field that moved between protocol version 1 and 2: it
  /// spells the application's name, and the name changed. Every other table in
  /// `docs/WIRE.md` is the version-1 table unchanged.
  ///
  /// A magic number is not decoration here. The first thing a display does with
  /// a stream is decide where a frame starts, and everything downstream — the
  /// length it will allocate, the type it will dispatch on — is wrong in a
  /// quiet, plausible way if it got that wrong. Failing on byte zero is much
  /// better than drawing a shifted spectrum.
  static const int magic = 0x5741414F;

  /// The version this build speaks, and the one it stamps on what it sends.
  ///
  /// Version 3 adds `0x0020 SET_LUFS_MODE` and changes no existing table, which
  /// is what makes [isKnownVersion] able to accept a version-2 peer instead of
  /// refusing it. Version 4 moved the snapshot table and version 5 grew it;
  /// both older tables are still decoded, by the frame's version — see
  /// `WireSnapshot.decode`.
  static const int protocolVersion = 5;

  /// The oldest version whose tables this build can still decode.
  ///
  /// Version 1 is excluded on purpose rather than forgotten: its magic is a
  /// different four bytes, so a version-1 stream fails on byte zero and never
  /// reaches a version check.
  static const int minimumVersion = 2;

  /// Whether a frame stamped [version] can be decoded by this build.
  ///
  /// Greater than ours is refused — a later version may have moved a table we
  /// would then misread, and misreading a measurement table is how a meter
  /// shows a confident wrong number. Lower is accepted, because every table a
  /// lower version defines is one this version froze unchanged.
  static bool isKnownVersion(int version) =>
      version >= minimumVersion && version <= protocolVersion;

  static const int headerBytes = 12;

  /// The largest payload a receiver will agree to buffer.
  ///
  /// A length field is an instruction to allocate, and one that has been
  /// corrupted in transit or written by something hostile must not be obeyed.
  /// The largest legitimate frame is a snapshot at a little over 28 kB, so this
  /// is more than an order of magnitude of headroom and still refuses to turn
  /// four bad bytes into a four-gigabyte allocation.
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

  /// `0x0020` — what a LUFS integration counts from. Consumer → producer, and
  /// **on the ingest port only**: it is loopback, where the things that can
  /// connect are already running as this user. The display port is on the LAN
  /// and stays read-only until somebody designs authentication for it, so this
  /// frame must never be sent or accepted there. See `docs/WIRE.md`.
  static const int setLufsMode = 0x0020;

  /// `0x0021`–`0x002F` — the rest of the control range, still undefined and
  /// still bound by the same argument.
  static const int reservedControlLow = 0x0021;
  static const int reservedControlHigh = 0x002F;
}

/// The stream was not an Open Audio Analyzer stream, or was not an Open Audio
/// Analyzer stream any more.
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
  FrameReader({int initialCapacity = WireFrame.headerBytes + 20480})
    : _buffer = Uint8List(initialCapacity) {
    _view = ByteData.view(_buffer.buffer);
  }

  Uint8List _buffer;
  late ByteData _view;

  /// Bytes of [_buffer] that hold received data.
  int _filled = 0;

  int _type = 0;
  int _version = 0;
  ByteData? _payload;

  /// The type of the frame [moveNext] last produced.
  int get type => _type;

  /// The protocol version stamped on the frame [moveNext] last produced.
  ///
  /// Worth exposing rather than checking and discarding, because it is what
  /// decides whether a control frame may be sent *back*: a version-2 producer
  /// does not read its socket at all, so `0x0020` sent to one is not refused —
  /// it is ignored, and the consumer would go on believing a mode was in force
  /// that the producer had never heard of. Zero before the first frame.
  int get version => _version;

  /// The payload of the frame [moveNext] last produced. Valid until the next
  /// call to [moveNext].
  ByteData get payload => _payload!;

  /// Appends received bytes.
  void add(List<int> chunk) {
    _reserve(_filled + chunk.length);
    _buffer.setRange(_filled, _filled + chunk.length, chunk);
    _filled += chunk.length;
  }

  /// Forgets everything received so far, so this reader can be pointed at a
  /// different stream.
  ///
  /// **A reader outlives the connection it was reading, and the bytes must
  /// not.** A socket that dies mid-frame leaves the head of that frame here,
  /// and those bytes are not a prefix of anything the next connection will
  /// send. Reading on without dropping them reassembles the dead stream's head
  /// spliced onto the live stream's — which has the right *length*, so it
  /// decodes rather than failing, and is entirely wrong, so the meters draw a
  /// detailed picture of a signal nobody measured. The magic check then fails
  /// on whatever follows and the link drops; the leftovers survive that too, so
  /// every retry repeats it. A display that lost one frame to a Wi-Fi hiccup
  /// flashed one frame of nonsense every few seconds and never came back.
  ///
  /// The capacity is kept. It is bounded by [WireFrame.maxPayloadBytes], and
  /// re-growing it is the only thing releasing it would buy.
  void reset() {
    _filled = 0;
    _consumed = 0;
    _payload = null;
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
        'not an Open Audio Analyzer frame: magic 0x${magic.toRadixString(16)}',
      );
    }

    final version = _view.getUint16(4, Endian.little);
    if (!WireFrame.isKnownVersion(version)) {
      throw WireFormatException(
        'wire protocol version $version, this build speaks '
        '${WireFrame.minimumVersion}-${WireFrame.protocolVersion}',
      );
    }
    _version = version;

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
