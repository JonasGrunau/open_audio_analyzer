// SPDX-License-Identifier: GPL-3.0-or-later
//
// The USB relay, both halves, with the cable played by a loopback socket.
//
// What a cable adds is one byte stream; everything either side does with it is
// here — the tablet's relay ports, the carriage, the desktop handing each
// channel to a real `DisplayHost`, and a real `DisplayClient` attached through
// it. What is not here is the USB itself: `usbmuxd` and the Android accessory
// each deliver the stream this test opens with `Socket.connect`.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/remote/display_client.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa/src/remote/usb_link.dart';
import 'package:oaa/src/remote/usb_relay.dart';
import 'package:oaa_wire/oaa_wire.dart';

import 'support/fake_source.dart';

Future<void> _settle([int milliseconds = 120]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await _settle(20);
  }
}

void main() {
  late FakeSource source;
  late DisplayHost host;
  late TabletRelay relay;
  UsbRelayHost? cable;

  setUp(() async {
    source = FakeSource();
    host = DisplayHost(source: source, hostName: 'Studio Mac', abiVersion: 4);
    await host.start(port: 0);
    relay = TabletRelay(name: 'Studio iPad', pipePort: 0, relayPort: 0);
    await relay.start();
  });

  tearDown(() async {
    cable?.close();
    cable = null;
    relay.dispose();
    await host.stop();
    host.dispose();
  });

  Future<void> plugIn() async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      relay.boundPipePort!,
    );
    cable = UsbRelayHost(SocketPipe(socket), host);
    await _until(() => relay.attached.value && cable!.name.value != null);
  }

  test('the relay port is closed until a cable arrives', () async {
    expect(relay.attached.value, isFalse);
    expect(relay.boundRelayPort, isNull);
  });

  test('a knock through the cable finds the desktop by its HELLO', () async {
    await plugIn();
    expect(cable!.name.value, 'Studio iPad');

    final found = await UsbHostProbe.knock(
      InternetAddress.loopbackIPv4,
      relay.boundRelayPort!,
    );
    expect(found?.name, 'Studio Mac');
    // The knock hung up, and its channel went with it.
    await _until(() => cable!.channelCount == 0);
    expect(cable!.channelCount, 0);
  });

  test('a display attached through the cable draws the desktop live', () async {
    await plugIn();
    final client = DisplayClient(staleAfter: const Duration(seconds: 2));
    addTearDown(() async {
      await client.disconnect();
      client.dispose();
    });
    await client.connect('127.0.0.1', relay.boundRelayPort!);
    await _until(() => client.hostName.value == 'Studio Mac');
    expect(host.clientCount.value, 1);

    // Well past the unacknowledged window, so a relay that lost the display's
    // acknowledgements would stall here rather than keep up.
    for (var i = 0; i < 60; i++) {
      source.generation++;
      host.publishNow();
      await _settle(15);
    }
    await _until(() => client.snapshot.generation >= 55);
    expect(client.snapshot.generation, greaterThanOrEqualTo(55));
  });

  test(
    'pulling the cable drops the display and closes the relay port',
    () async {
      await plugIn();
      final client = DisplayClient(staleAfter: const Duration(seconds: 2));
      addTearDown(() async {
        await client.disconnect();
        client.dispose();
      });
      await client.connect('127.0.0.1', relay.boundRelayPort!);
      await _until(() => host.clientCount.value == 1);
      final port = relay.boundRelayPort!;

      cable!.close();
      await _until(() => !relay.attached.value && host.clientCount.value == 0);
      expect(relay.attached.value, isFalse);
      expect(host.clientCount.value, 0);
      expect(
        await UsbHostProbe.knock(InternetAddress.loopbackIPv4, port),
        isNull,
      );
    },
  );

  test(
    'a host that is not publishing refuses what the cable carries',
    () async {
      await plugIn();
      await host.stop();
      expect(
        await UsbHostProbe.knock(
          InternetAddress.loopbackIPv4,
          relay.boundRelayPort!,
        ),
        isNull,
      );
    },
  );

  test(
    'something on the cable port that is not a desktop is hung up on',
    () async {
      final stray = await Socket.connect(
        InternetAddress.loopbackIPv4,
        relay.boundPipePort!,
      );
      addTearDown(stray.destroy);
      final closed = Completer<void>();
      stray.listen((_) {}, onDone: closed.complete, onError: (_) {});
      stray.add('GET / HTTP/1.1\r\n\r\n'.codeUnits);
      await closed.future.timeout(const Duration(seconds: 2));
      expect(relay.attached.value, isFalse);
    },
  );

  test('a tablet that starts over on a cable that stayed up is answered '
      'again', () async {
    // An Android application restarted with the accessory still attached: the
    // desktop's end of the cable never closed, and the new relay greets it.
    final desktop = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(desktop.close);
    final accepted = desktop.first;
    final tablet = await Socket.connect(
      InternetAddress.loopbackIPv4,
      desktop.port,
    );
    addTearDown(tablet.destroy);
    cable = UsbRelayHost(SocketPipe(await accepted), host);

    final fromDesktop = <int>[];
    tablet.listen(fromDesktop.addAll);
    tablet
      ..add(UsbCarriage.preamble)
      ..add(UsbCarriage.encodeName('First'))
      ..add(UsbCarriage.encode(CarriageKind.open, 1));
    await _until(() => host.clientCount.value == 1);
    expect(fromDesktop.take(8), UsbCarriage.preamble);

    // The restart: the old channel is gone, and the desktop says hello again.
    fromDesktop.clear();
    tablet
      ..add(UsbCarriage.preamble)
      ..add(UsbCarriage.encodeName('Second'));
    await _until(() => cable!.name.value == 'Second');
    await _until(() => host.clientCount.value == 0);
    expect(host.clientCount.value, 0);
    expect(fromDesktop.take(8), UsbCarriage.preamble);
  });
}
