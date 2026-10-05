// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:oaa_wire/oaa_wire.dart';
import 'package:test/test.dart';

void main() {
  Uint8List pipe(List<Uint8List> messages) => Uint8List.fromList([
    ...UsbCarriage.preamble,
    for (final message in messages) ...message,
  ]);

  test('messages survive being cut anywhere', () {
    final bytes = pipe([
      UsbCarriage.encodeName('Studio iPad'),
      UsbCarriage.encode(CarriageKind.open, 7),
      UsbCarriage.encode(CarriageKind.data, 7, List.generate(300, (i) => i)),
      UsbCarriage.encode(CarriageKind.close, 7),
    ]);
    for (var cut = 1; cut < bytes.length; cut += 7) {
      final reader = CarriageReader();
      final seen = <String>[];
      for (var at = 0; at < bytes.length; at += cut) {
        reader.add(bytes.sublist(at, (at + cut).clamp(0, bytes.length)));
        while (reader.moveNext()) {
          seen.add(
            '${reader.kind.name}:${reader.channel}:${reader.payload.length}',
          );
        }
      }
      expect(seen, ['name:0:11', 'open:7:0', 'data:7:300', 'close:7:0']);
    }
  });

  test('a payload handed out stays what it was', () {
    final reader = CarriageReader()
      ..add(
        pipe([
          UsbCarriage.encode(CarriageKind.data, 1, [1, 2, 3]),
        ]),
      );
    expect(reader.moveNext(), isTrue);
    final first = reader.payload;
    reader.add(UsbCarriage.encode(CarriageKind.data, 1, [9, 9, 9]));
    expect(reader.moveNext(), isTrue);
    expect(first, [1, 2, 3]);
  });

  test('anything that is not ours fails on its first bytes', () {
    final reader = CarriageReader()..add(WireFrame.encode(1, Uint8List(0)));
    expect(reader.moveNext, throwsFormatException);
  });

  test('an unknown kind and an oversized length are refused', () {
    final unknown = CarriageReader()
      ..add([...UsbCarriage.preamble, 99, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(unknown.moveNext, throwsFormatException);

    final huge = CarriageReader()
      ..add([...UsbCarriage.preamble, 2, 1, 0, 0, 0, 0, 0, 0, 0x40]);
    expect(huge.moveNext, throwsFormatException);
  });

  test('a desktop skips what came before the first preamble', () {
    // The tail of a session on an accessory nobody was reading any more.
    final reader = CarriageReader(resync: true)
      ..add([2, 9, 0, 0, 0, 1, 0, 0, 0, 7, 0x4F, 0x41])
      ..add(pipe([UsbCarriage.encodeName('Tab')]));
    expect(reader.moveNext(), isTrue);
    expect(reader.kind, CarriageKind.name);
    expect(String.fromCharCodes(reader.payload), 'Tab');
  });

  test('a preamble mid-stream is a restart, not a corrupt pipe', () {
    final reader = CarriageReader()
      ..add(pipe([UsbCarriage.encode(CarriageKind.open, 1)]))
      ..add(UsbCarriage.preamble)
      ..add(UsbCarriage.encodeName('Again'));
    final kinds = <CarriageKind>[];
    while (reader.moveNext()) {
      kinds.add(reader.kind);
    }
    expect(kinds, [CarriageKind.open, CarriageKind.restart, CarriageKind.name]);
  });

  test('restart is never a kind on the wire', () {
    final reader = CarriageReader()
      ..add([...UsbCarriage.preamble, 0x4F, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(reader.moveNext, throwsFormatException);
  });
}
