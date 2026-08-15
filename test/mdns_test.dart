// SPDX-License-Identifier: GPL-3.0-or-later
//
// The DNS subset, held against packets built by hand.
//
// Hand-rolled protocol parsing is where bugs go to hide, and this one runs on
// port 5353 — where every device on the network is talking at once, most of it
// about services Bel has never heard of. The two things worth proving are that
// a well-formed packet round-trips exactly, and that a malformed or hostile one
// produces null rather than an exception or a loop.

import 'dart:typed_data';

import 'package:bel/src/remote/mdns/dns_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('queries', () {
    test('round-trip a service query', () {
      final message = decodeMessage(
        encodeQuery('_bel._tcp.local', DnsType.ptr),
      );

      expect(message, isNotNull);
      expect(message!.isResponse, isFalse);
      expect(message.questions.single.name, '_bel._tcp.local');
      expect(message.questions.single.type, DnsType.ptr);
    });
  });

  group('responses', () {
    test('a full announcement survives the round trip', () {
      final packet = encodeResponse(
        answers: [
          DnsRecord(
            name: '_bel._tcp.local',
            type: DnsType.ptr,
            ttl: 120,
            target: 'Studio Mac._bel._tcp.local',
          ),
        ],
        additionals: [
          DnsRecord(
            name: 'Studio Mac._bel._tcp.local',
            type: DnsType.srv,
            ttl: 120,
            cacheFlush: true,
            port: 47821,
            target: 'Studio-Mac.local',
          ),
          DnsRecord(
            name: 'Studio Mac._bel._tcp.local',
            type: DnsType.txt,
            ttl: 120,
            txt: const {'v': '1', 'name': 'Studio Mac', 'sr': '48000'},
          ),
          DnsRecord(
            name: 'Studio-Mac.local',
            type: DnsType.a,
            ttl: 120,
            address: const [192, 168, 1, 20],
          ),
        ],
      );

      final message = decodeMessage(packet);
      expect(message, isNotNull);
      expect(message!.isResponse, isTrue);
      expect(message.answers.length, 4);

      final ptr = message.answers.firstWhere((r) => r.type == DnsType.ptr);
      expect(ptr.name, '_bel._tcp.local');
      expect(ptr.target, 'Studio Mac._bel._tcp.local');

      final srv = message.answers.firstWhere((r) => r.type == DnsType.srv);
      expect(srv.port, 47821);
      expect(srv.target, 'Studio-Mac.local');

      final txt = message.answers.firstWhere((r) => r.type == DnsType.txt);
      expect(txt.txt['v'], '1');
      expect(txt.txt['name'], 'Studio Mac');
      expect(txt.txt['sr'], '48000');

      final a = message.answers.firstWhere((r) => r.type == DnsType.a);
      expect(a.address, [192, 168, 1, 20]);
    });

    test('a goodbye is a zero TTL, not a missing record', () {
      // How a host says it has gone. Without it every tablet keeps offering a
      // machine that is switched off until the TTL expires, and somebody taps
      // it and waits.
      final message = decodeMessage(
        encodeResponse(
          answers: [
            DnsRecord(
              name: '_bel._tcp.local',
              type: DnsType.ptr,
              ttl: 0,
              target: 'Gone._bel._tcp.local',
            ),
          ],
        ),
      );

      expect(message!.answers.single.ttl, 0);
      expect(message.answers.single.target, 'Gone._bel._tcp.local');
    });

    test('a non-ASCII instance name survives', () {
      final message = decodeMessage(
        encodeResponse(
          answers: [
            DnsRecord(
              name: '_bel._tcp.local',
              type: DnsType.ptr,
              ttl: 120,
              target: 'Björns Regieraum._bel._tcp.local',
            ),
          ],
        ),
      );

      expect(
        message!.answers.single.target,
        'Björns Regieraum._bel._tcp.local',
      );
    });

    test('an empty TXT is one zero-length string, not zero strings', () {
      // RFC 6763 is specific about this, and a responder that emits an empty
      // rdata is one some resolvers drop the whole record for.
      final packet = encodeResponse(
        answers: [
          DnsRecord(name: 'x._bel._tcp.local', type: DnsType.txt, ttl: 120),
        ],
      );

      // The last three bytes are the rdlength (1) and the single zero-length
      // string that makes up the record.
      expect(packet.sublist(packet.length - 3), [0, 1, 0]);
      expect(decodeMessage(packet)!.answers.single.txt, isEmpty);
    });
  });

  group('reading what other devices send', () {
    test('a compressed name is followed', () {
      // Every other responder on the network compresses names; this one does
      // not emit pointers but must read them, or Bel is the only service on
      // the LAN that cannot see its own kind announced by anyone else.
      final packet = _packetWithCompressedTarget();

      final message = decodeMessage(packet);
      expect(message, isNotNull);
      expect(message!.answers.single.target, 'Studio._bel._tcp.local');
    });

    test('a pointer loop is refused rather than followed', () {
      // A packet anyone on the network can send. A reader that followed this
      // never returns, and the app is gone with it.
      final packet = _packetWithSelfReferentialPointer();
      expect(decodeMessage(packet), isNull);
    });

    test('a truncated packet is not a crash', () {
      final full = encodeResponse(
        answers: [
          DnsRecord(
            name: '_bel._tcp.local',
            type: DnsType.ptr,
            ttl: 120,
            target: 'Studio._bel._tcp.local',
          ),
        ],
      );

      // Every prefix of a valid packet. Port 5353 will eventually deliver one.
      for (var length = 0; length < full.length; length++) {
        expect(
          () => decodeMessage(Uint8List.sublistView(full, 0, length)),
          returnsNormally,
        );
      }
    });

    test('random bytes are not a Bel announcement', () {
      final noise = Uint8List.fromList(
        List<int>.generate(64, (i) => (i * 37 + 11) & 0xFF),
      );
      // Either null or a message with nothing Bel cares about — never a throw.
      expect(() => decodeMessage(noise), returnsNormally);
    });

    test('an unknown record type does not desync the packet after it', () {
      // AAAA is the one that turns up in practice, from every other device on
      // the network. If reading it left the cursor in the wrong place, the
      // records after it would decode as garbage.
      final packet = encodeResponse(
        answers: [
          DnsRecord(
            name: 'host.local',
            type: DnsType.aaaa,
            ttl: 120,
            address: const [
              0xFE, 0x80, 0, 0, 0, 0, 0, 0, //
              0, 0, 0, 0, 0, 0, 0, 1,
            ],
          ),
          DnsRecord(
            name: '_bel._tcp.local',
            type: DnsType.ptr,
            ttl: 120,
            target: 'Studio._bel._tcp.local',
          ),
        ],
      );

      final message = decodeMessage(packet);
      expect(message!.answers.length, 2);
      expect(message.answers.last.type, DnsType.ptr);
      expect(message.answers.last.target, 'Studio._bel._tcp.local');
    });
  });
}

/// A response whose PTR target ends in a pointer back to the question name, the
/// way every real responder writes it.
Uint8List _packetWithCompressedTarget() {
  final out = BytesBuilder();

  void uint16(int value) => out
    ..addByte(value >> 8 & 0xFF)
    ..addByte(value & 0xFF);

  // Header: one answer, no questions.
  uint16(0);
  uint16(0x8400);
  uint16(0);
  uint16(1);
  uint16(0);
  uint16(0);

  // The name `_bel._tcp.local` begins at offset 12 and is what the target will
  // point at.
  for (final label in ['_bel', '_tcp', 'local']) {
    out.addByte(label.length);
    out.add(label.codeUnits);
  }
  out.addByte(0);

  uint16(DnsType.ptr);
  uint16(DnsClass.internet);
  out.add(const [0, 0, 0, 120]); // ttl

  // rdata: `Studio` then a pointer to offset 12.
  const instance = 'Studio';
  uint16(1 + instance.length + 2);
  out.addByte(instance.length);
  out.add(instance.codeUnits);
  out
    ..addByte(0xC0)
    ..addByte(12);

  return out.toBytes();
}

/// A name whose pointer points at itself.
Uint8List _packetWithSelfReferentialPointer() {
  final out = BytesBuilder();

  void uint16(int value) => out
    ..addByte(value >> 8 & 0xFF)
    ..addByte(value & 0xFF);

  uint16(0);
  uint16(0x8400);
  uint16(0);
  uint16(1);
  uint16(0);
  uint16(0);

  // At offset 12: a pointer to offset 12.
  out
    ..addByte(0xC0)
    ..addByte(12);

  uint16(DnsType.ptr);
  uint16(DnsClass.internet);
  out.add(const [0, 0, 0, 120]);
  uint16(0);

  return out.toBytes();
}
