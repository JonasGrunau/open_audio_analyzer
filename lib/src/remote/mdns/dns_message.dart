// SPDX-License-Identifier: GPL-3.0-or-later

/// Just enough DNS to advertise and find one service.
///
/// This is a deliberate subset of RFC 1035 and RFC 6762 — PTR, SRV, TXT and A,
/// on one service type, over multicast. It is not a resolver and it should
/// never grow into one.
///
/// Written by hand rather than taken from a package, and that is not
/// not-invented-here. The service has to be **advertised** as well as browsed,
/// and the pure-Dart package that everyone reaches for only browses; the
/// packages that do both wrap each platform's native responder through plugin
/// channels, which on Linux desktop is the platform Open Audio Analyzer would
/// then quietly stop supporting. One implementation that behaves identically on
/// macOS, Windows and Linux is worth a few hundred lines, especially when the
/// alternative is discovering the gap on the one machine in the studio that
/// runs Linux.
///
/// **iPadOS is the exception, and it is not one Open Audio Analyzer chose.** Apple will not let
/// an app hold a multicast socket on real hardware without a restricted
/// entitlement granted per team on request, so the tablet browses through the
/// system responder instead — `mdns/bonjour_discovery.dart`, and the reasoning
/// in `mdns/host_discovery.dart`. Nothing else moved: a tablet is a display and
/// never advertises, so this file is still the only thing that writes a record.
///
/// Names are written uncompressed. Compression is optional for a writer and
/// mandatory for a reader, so this reads pointers and never emits them; the
/// packets are a few hundred bytes either way.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Record types, only the ones this speaks.
abstract final class DnsType {
  static const int a = 1;
  static const int ptr = 12;
  static const int txt = 16;
  static const int aaaa = 28;
  static const int srv = 33;
  static const int any = 255;
}

/// Class IN, plus the two bits mDNS overloads the class field with.
abstract final class DnsClass {
  static const int internet = 1;

  /// In a question: "answer me directly, not to the multicast group."
  static const int unicastResponseBit = 0x8000;

  /// In a record: "this is the whole truth about this name, drop what you had."
  static const int cacheFlushBit = 0x8000;

  static const int mask = 0x7FFF;
}

/// One resource record, as read off the wire or as about to be written to it.
class DnsRecord {
  DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    this.cacheFlush = false,
    this.target = '',
    this.port = 0,
    this.priority = 0,
    this.weight = 0,
    this.address = const [],
    this.txt = const {},
  });

  final String name;
  final int type;
  final int ttl;
  final bool cacheFlush;

  /// PTR and SRV: the name pointed at.
  final String target;

  /// SRV.
  final int port;
  final int priority;
  final int weight;

  /// A / AAAA, in wire order.
  final List<int> address;

  /// TXT, as the key=value pairs it almost always is. A bare entry with no `=`
  /// arrives with an empty value.
  final Map<String, String> txt;
}

/// One question.
class DnsQuestion {
  DnsQuestion(this.name, this.type, {this.unicastResponse = false});
  final String name;
  final int type;
  final bool unicastResponse;
}

/// A parsed message. mDNS ignores most of the header, so this keeps only what
/// is acted on.
class DnsMessage {
  DnsMessage({
    required this.isResponse,
    required this.questions,
    required this.answers,
  });

  final bool isResponse;
  final List<DnsQuestion> questions;

  /// Answers, authorities and additionals together.
  ///
  /// mDNS puts the SRV, TXT and A records that make a PTR useful in the
  /// additional section, and a browser that only read the answer section would
  /// find a service it could not connect to. Nothing here needs to tell the
  /// sections apart, so nothing here does.
  final List<DnsRecord> answers;
}

/// Encodes a query for [name].
Uint8List encodeQuery(String name, int type) {
  final out = _Writer();
  out
    ..uint16(0) // id — mDNS ignores it
    ..uint16(0) // flags: standard query
    ..uint16(1) // one question
    ..uint16(0)
    ..uint16(0)
    ..uint16(0)
    ..name(name)
    ..uint16(type)
    ..uint16(DnsClass.internet);
  return out.take();
}

/// Encodes a response carrying [answers] and [additionals].
Uint8List encodeResponse({
  required List<DnsRecord> answers,
  List<DnsRecord> additionals = const [],
}) {
  final out = _Writer();
  out
    ..uint16(0)
    ..uint16(0x8400) // response, authoritative
    ..uint16(0)
    ..uint16(answers.length)
    ..uint16(0)
    ..uint16(additionals.length);

  for (final record in answers) {
    out.record(record);
  }
  for (final record in additionals) {
    out.record(record);
  }
  return out.take();
}

/// Parses a datagram, or returns null if it is not a DNS message this
/// understands.
///
/// Returning null rather than throwing is the right shape here: port 5353 on a
/// busy network carries every kind of announcement from every kind of device,
/// most of it for services Open Audio Analyzer has never heard of, some of it
/// malformed. A parser that threw would make normal network traffic look like
/// an error.
DnsMessage? decodeMessage(Uint8List datagram) {
  try {
    final reader = _Reader(datagram);
    reader.skip(2);
    final flags = reader.uint16();
    final questionCount = reader.uint16();
    final answerCount = reader.uint16();
    final authorityCount = reader.uint16();
    final additionalCount = reader.uint16();

    final questions = <DnsQuestion>[];
    for (var i = 0; i < questionCount; i++) {
      final name = reader.name();
      final type = reader.uint16();
      final klass = reader.uint16();
      questions.add(
        DnsQuestion(
          name,
          type,
          unicastResponse: klass & DnsClass.unicastResponseBit != 0,
        ),
      );
    }

    final answers = <DnsRecord>[];
    final recordCount = answerCount + authorityCount + additionalCount;
    for (var i = 0; i < recordCount; i++) {
      final record = reader.record();
      if (record != null) answers.add(record);
    }

    return DnsMessage(
      isResponse: flags & 0x8000 != 0,
      questions: questions,
      answers: answers,
    );
  } on Object {
    return null;
  }
}

class _Writer {
  final BytesBuilder _bytes = BytesBuilder(copy: true);

  void uint8(int value) => _bytes.addByte(value & 0xFF);

  void uint16(int value) {
    _bytes
      ..addByte(value >> 8 & 0xFF)
      ..addByte(value & 0xFF);
  }

  void uint32(int value) {
    _bytes
      ..addByte(value >> 24 & 0xFF)
      ..addByte(value >> 16 & 0xFF)
      ..addByte(value >> 8 & 0xFF)
      ..addByte(value & 0xFF);
  }

  void name(String value) {
    for (final label in value.split('.')) {
      if (label.isEmpty) continue;
      final bytes = utf8.encode(label);
      // 63 is the label limit; a longer one would encode as a compression
      // pointer and corrupt every name after it.
      final clipped = bytes.length > 63 ? bytes.sublist(0, 63) : bytes;
      uint8(clipped.length);
      _bytes.add(clipped);
    }
    uint8(0);
  }

  void record(DnsRecord record) {
    name(record.name);
    uint16(record.type);
    uint16(
      DnsClass.internet | (record.cacheFlush ? DnsClass.cacheFlushBit : 0),
    );
    uint32(record.ttl);

    final data = _Writer();
    switch (record.type) {
      case DnsType.ptr:
        data.name(record.target);
      case DnsType.srv:
        data
          ..uint16(record.priority)
          ..uint16(record.weight)
          ..uint16(record.port)
          ..name(record.target);
      case DnsType.txt:
        if (record.txt.isEmpty) {
          // A TXT record must not be empty — RFC 6763 says a single zero-length
          // string, which is not the same as no strings at all.
          data.uint8(0);
        }
        for (final entry in record.txt.entries) {
          final bytes = utf8.encode('${entry.key}=${entry.value}');
          final clipped = bytes.length > 255 ? bytes.sublist(0, 255) : bytes;
          data
            ..uint8(clipped.length)
            .._bytes.add(clipped);
        }
      case DnsType.a:
      case DnsType.aaaa:
        for (final byte in record.address) {
          data.uint8(byte);
        }
    }

    final encoded = data.take();
    uint16(encoded.length);
    _bytes.add(encoded);
  }

  Uint8List take() => _bytes.toBytes();
}

class _Reader {
  _Reader(this._bytes)
    : _view = ByteData.view(_bytes.buffer, _bytes.offsetInBytes, _bytes.length);

  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  void skip(int count) => _offset += count;

  int uint8() => _view.getUint8(_offset++);

  int uint16() {
    final value = _view.getUint16(_offset);
    _offset += 2;
    return value;
  }

  int uint32() {
    final value = _view.getUint32(_offset);
    _offset += 4;
    return value;
  }

  /// Reads a name, following compression pointers.
  ///
  /// The jump budget is the point of interest: a packet can point a name at
  /// itself, and a reader that followed that loops forever on a datagram
  /// anybody on the network can send. Every pointer must also point *backwards*,
  /// which is what makes a budget sufficient rather than merely likely to work.
  String name() {
    final labels = <String>[];
    var offset = _offset;
    var jumps = 0;
    var following = false;

    while (true) {
      final length = _view.getUint8(offset);
      if (length == 0) {
        offset++;
        break;
      }

      if (length & 0xC0 == 0xC0) {
        final pointer = (length & 0x3F) << 8 | _view.getUint8(offset + 1);
        if (pointer >= offset || ++jumps > 16) {
          throw const FormatException('compression pointer loop');
        }
        if (!following) {
          _offset = offset + 2;
          following = true;
        }
        offset = pointer;
        continue;
      }

      offset++;
      labels.add(
        utf8.decode(
          _bytes.sublist(offset, offset + length),
          allowMalformed: true,
        ),
      );
      offset += length;
    }

    if (!following) _offset = offset;
    return labels.join('.');
  }

  DnsRecord? record() {
    final name = this.name();
    final type = uint16();
    final klass = uint16();
    final ttl = uint32();
    final length = uint16();
    final end = _offset + length;

    DnsRecord? result;
    switch (type) {
      case DnsType.ptr:
        result = DnsRecord(
          name: name,
          type: type,
          ttl: ttl,
          cacheFlush: klass & DnsClass.cacheFlushBit != 0,
          target: this.name(),
        );
      case DnsType.srv:
        final priority = uint16();
        final weight = uint16();
        final port = uint16();
        result = DnsRecord(
          name: name,
          type: type,
          ttl: ttl,
          cacheFlush: klass & DnsClass.cacheFlushBit != 0,
          priority: priority,
          weight: weight,
          port: port,
          target: this.name(),
        );
      case DnsType.txt:
        final entries = <String, String>{};
        while (_offset < end) {
          final size = uint8();
          if (size == 0 || _offset + size > end) break;
          final text = utf8.decode(
            _bytes.sublist(_offset, _offset + size),
            allowMalformed: true,
          );
          _offset += size;
          final split = text.indexOf('=');
          if (split < 0) {
            entries[text] = '';
          } else {
            entries[text.substring(0, split)] = text.substring(split + 1);
          }
        }
        result = DnsRecord(name: name, type: type, ttl: ttl, txt: entries);
      case DnsType.a:
      case DnsType.aaaa:
        result = DnsRecord(
          name: name,
          type: type,
          ttl: ttl,
          cacheFlush: klass & DnsClass.cacheFlushBit != 0,
          address: _bytes.sublist(_offset, end),
        );
    }

    // Always leave the cursor at the end of the record, whether or not this
    // build understood it. A type nobody here parses must still not desync the
    // rest of the packet.
    _offset = end;
    return result;
  }
}
