// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// How display connections ride one USB pipe. See `docs/WIRE.md` § USB
/// carriage.
///
/// **A cable is one byte stream; a display port is many connections.** An
/// Android accessory is a pair of bulk endpoints and an iPad's `usbmuxd`
/// tunnel is one socket, while a tablet opens a connection to look for a host,
/// hangs it up, and opens another to attach. So the tablet carries each
/// connection made to its loopback relay port as a numbered *channel* inside
/// the pipe, and the desktop hands each channel to its display host as if it
/// were a socket that had just been accepted. Inside a channel the bytes are
/// exactly the display port's — frames, `HELLO` first — and nothing in this
/// file reads them.
///
/// Each side starts with [UsbCarriage.preamble], then messages of
/// [UsbCarriage.headerBytes]: `u8` kind, `u32` channel, `u32` length, all
/// little-endian like every other field in `WIRE.md`, then the payload.
abstract final class UsbCarriage {
  /// `OAAUSB` and a `u16` version, 1. Sent once by each side before anything
  /// else, so a pipe that is not carrying this — a stray accessory, a
  /// scanner on the loopback port — fails on its first byte.
  static const List<int> preamble = [0x4F, 0x41, 0x41, 0x55, 0x53, 0x42, 1, 0];

  static const int version = 1;

  static const int headerBytes = 9;

  /// The same ceiling the display port's frames have, for the same reason.
  static const int maxPayloadBytes = 1 << 20;

  /// One message.
  static Uint8List encode(
    CarriageKind kind,
    int channel, [
    List<int> payload = const [],
  ]) {
    final out = Uint8List(headerBytes + payload.length);
    final view = ByteData.sublistView(out);
    view.setUint8(0, kind.code);
    view.setUint32(1, channel, Endian.little);
    view.setUint32(5, payload.length, Endian.little);
    out.setRange(headerBytes, out.length, payload);
    return out;
  }

  /// The tablet's name for itself, sent on channel 0 right after the
  /// preamble: what the desktop lists under Settings › Publish.
  static Uint8List encodeName(String name) =>
      encode(CarriageKind.name, 0, utf8.encode(name));
}

enum CarriageKind {
  /// Tablet → desktop: a display connected to the relay port. No payload.
  open(1),

  /// Either way: bytes for one channel.
  data(2),

  /// Either way: the channel is finished. No payload. Never answered.
  close(3),

  /// Tablet → desktop, channel 0: the tablet's name, UTF-8.
  name(4),

  /// Never encoded: what [CarriageReader] reports when the other side's
  /// preamble arrives *again*, in place of a message. Its code is the
  /// preamble's first byte, `O`, which no message kind uses — so a side that
  /// started over is told apart from a corrupt pipe by reading eight bytes.
  restart(0x4F);

  const CarriageKind(this.code);
  final int code;

  static CarriageKind? byCode(int code) =>
      values.where((kind) => kind.code == code).firstOrNull;
}

/// Reassembles messages from whatever chunks the pipe delivers.
///
/// Throws [FormatException] on a preamble that is not ours, a kind it does
/// not know, or a length over the ceiling — after any of which the pipe is
/// not worth reading further.
///
/// With [resync], bytes before the first preamble are skipped rather than
/// refused. That is the desktop's reader, and an Android accessory is why: the
/// cable outlives the application at the far end of it, so what arrives first
/// on a cable the desktop has just opened can be the tail of a session nobody
/// is reading any more.
class CarriageReader {
  CarriageReader({this.resync = false});

  final bool resync;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _preambleSeen = false;

  /// Whether the other side has said it speaks this, which is the moment a
  /// pipe becomes worth anything.
  bool get preambleSeen => _preambleSeen;

  late CarriageKind kind;
  late int channel;
  late Uint8List payload;

  void add(List<int> chunk) => _pending.add(chunk);

  bool moveNext() {
    if (_pending.length > 0) {
      // A fresh buffer, never one written into: the payload handed out by the
      // previous message is a view of the old one and must stay what it was.
      final incoming = _pending.takeBytes();
      final rest = _buffer.length - _offset;
      final joined = Uint8List(rest + incoming.length)
        ..setRange(0, rest, _buffer, _offset)
        ..setRange(rest, rest + incoming.length, incoming);
      _buffer = joined;
      _offset = 0;
    }
    final available = _buffer.length - _offset;

    final want = UsbCarriage.preamble.length;
    if (!_preambleSeen) {
      if (resync) {
        // Drop everything before the first byte that could start a preamble,
        // and anything that starts one and does not finish it.
        while (_offset < _buffer.length && !_preambleAt(_offset)) {
          _offset++;
        }
        if (_buffer.length - _offset < want) return false;
      } else {
        final seen = available < want ? available : want;
        for (var i = 0; i < seen; i++) {
          if (_buffer[_offset + i] != UsbCarriage.preamble[i]) {
            throw const FormatException('Not a USB carriage pipe.');
          }
        }
        if (available < want) return false;
      }
      _offset += want;
      _preambleSeen = true;
      return moveNext();
    }

    if (available == 0) return false;
    if (_buffer[_offset] == CarriageKind.restart.code) {
      if (available < want) return false;
      if (!_preambleAt(_offset)) {
        throw const FormatException('Not a USB carriage pipe.');
      }
      _offset += want;
      kind = CarriageKind.restart;
      channel = 0;
      payload = Uint8List(0);
      return true;
    }

    if (available < UsbCarriage.headerBytes) return false;
    final view = ByteData.sublistView(_buffer, _offset);
    final code = view.getUint8(0);
    final length = view.getUint32(5, Endian.little);
    final known = CarriageKind.byCode(code);
    if (known == null || known == CarriageKind.restart) {
      throw FormatException('Unknown carriage message $code.');
    }
    if (length > UsbCarriage.maxPayloadBytes) {
      throw FormatException('Carriage message of $length bytes.');
    }
    if (available < UsbCarriage.headerBytes + length) return false;

    kind = known;
    channel = view.getUint32(1, Endian.little);
    final start = _offset + UsbCarriage.headerBytes;
    payload = Uint8List.sublistView(_buffer, start, start + length);
    _offset = start + length;
    return true;
  }

  /// Whether the preamble starts at [at], as far as the buffer goes: a prefix
  /// of it at the very end counts, because the rest may be in the next chunk.
  bool _preambleAt(int at) {
    for (var i = 0; i < UsbCarriage.preamble.length; i++) {
      if (at + i >= _buffer.length) return true;
      if (_buffer[at + i] != UsbCarriage.preamble[i]) return false;
    }
    return true;
  }
}
