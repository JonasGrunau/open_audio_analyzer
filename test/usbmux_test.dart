// SPDX-License-Identifier: GPL-3.0-or-later
//
// The iPad's cable, desktop half, against a daemon that behaves like
// `usbmuxd`: a device list with one iPad on USB, and a `Connect` that becomes a
// tunnel to the tablet's relay — here a real `TabletRelay` on loopback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa/src/remote/usb_link.dart';
import 'package:oaa/src/remote/usb_relay.dart';
import 'package:oaa/src/remote/usbmux.dart';

import 'support/fake_source.dart';

/// Enough of `usbmuxd` to be lied to by.
class _FakeDaemon {
  _FakeDaemon(this._server, this.tabletPort) {
    _server.listen(_serve);
  }

  static Future<_FakeDaemon> start(int tabletPort) async => _FakeDaemon(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    tabletPort,
  );

  final ServerSocket _server;
  final int tabletPort;
  bool listening = true;
  final List<int> portsAsked = [];

  int get port => _server.port;

  void _serve(Socket client) {
    final buffer = BytesBuilder();
    late StreamSubscription<Uint8List> subscription;
    subscription = client.listen((chunk) async {
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      if (bytes.length < 16) return;
      final length = ByteData.sublistView(bytes).getUint32(0, Endian.little);
      if (bytes.length < length) return;
      final request =
          decodePlist(utf8.decode(bytes.sublist(16, length)))!
              as Map<String, Object?>;
      switch (request['MessageType']) {
        case 'ListDevices':
          _reply(
            client,
            '<plist><dict><key>DeviceList</key><array>'
            '<dict><key>DeviceID</key><integer>3</integer>'
            '<key>Properties</key><dict>'
            '<key>ConnectionType</key><string>USB</string>'
            '<key>SerialNumber</key><string>00008103-AAAA</string>'
            '</dict></dict>'
            '<dict><key>DeviceID</key><integer>4</integer>'
            '<key>Properties</key><dict>'
            '<key>ConnectionType</key><string>Network</string>'
            '<key>SerialNumber</key><string>WIFI-ONLY</string>'
            '</dict></dict>'
            '</array></dict></plist>',
          );
          await client.close();
        case 'Connect':
          final swapped = request['PortNumber']! as int;
          portsAsked.add(((swapped & 0xff) << 8) | (swapped >> 8));
          if (!listening) {
            _reply(client, _result(3));
            await client.close();
            return;
          }
          final tablet = await Socket.connect(
            InternetAddress.loopbackIPv4,
            tabletPort,
          );
          _reply(client, _result(0));
          // From here the daemon is a wire.
          subscription.onData(tablet.add);
          tablet.listen(client.add, onDone: client.destroy);
          subscription.onDone(tablet.destroy);
      }
    });
  }

  static String _result(int number) =>
      '<plist><dict><key>MessageType</key><string>Result</string>'
      '<key>Number</key><integer>$number</integer></dict></plist>';

  void _reply(Socket client, String plist) {
    final body = utf8.encode(plist);
    client
      ..add(
        (ByteData(16)
              ..setUint32(0, 16 + body.length, Endian.little)
              ..setUint32(4, 1, Endian.little)
              ..setUint32(8, 8, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(body);
  }

  Future<void> close() => _server.close();
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 150 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a property list round-trips what the daemon sends', () {
    final decoded =
        decodePlist(
              encodePlist({
                'MessageType': 'Connect',
                'DeviceID': 7,
                'Name': 'a & <b>',
                'Ok': true,
              }),
            )!
            as Map<String, Object?>;
    expect(decoded, {
      'MessageType': 'Connect',
      'DeviceID': 7,
      'Name': 'a & <b>',
      'Ok': true,
    });
  });

  group('an iPad on the cable', () {
    late DisplayHost host;
    late TabletRelay relay;
    late _FakeDaemon daemon;
    late IpadUsb ipad;

    setUp(() async {
      host = DisplayHost(
        source: FakeSource(),
        hostName: 'Studio Mac',
        abiVersion: 4,
      );
      await host.start(port: 0);
      relay = TabletRelay(name: 'Studio iPad', pipePort: 0, relayPort: 0);
      await relay.start();
      daemon = await _FakeDaemon.start(relay.boundPipePort!);
      ipad = IpadUsb(
        mux: UsbMux((address: InternetAddress.loopbackIPv4, port: daemon.port)),
        interval: const Duration(milliseconds: 100),
      );
    });

    tearDown(() async {
      ipad.dispose();
      relay.dispose();
      await daemon.close();
      await host.stop();
      host.dispose();
    });

    test('is dialled on the cable port, and only the cabled one', () async {
      ipad.start(host);
      await _until(() => ipad.devices.value.isNotEmpty);
      expect(ipad.devices.value, ['Studio iPad']);
      expect(daemon.portsAsked.toSet(), {kUsbPipePort});
      // One device on USB, one on Wi-Fi sync: one dial, ever.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(daemon.portsAsked, hasLength(1));

      final found = await UsbHostProbe.knock(
        InternetAddress.loopbackIPv4,
        relay.boundRelayPort!,
      );
      expect(found?.name, 'Studio Mac');
    });

    test('an iPad without the application open is asked again', () async {
      daemon.listening = false;
      ipad.start(host);
      await _until(() => daemon.portsAsked.length >= 2);
      expect(ipad.devices.value, isEmpty);

      daemon.listening = true;
      await _until(() => ipad.devices.value.isNotEmpty);
      expect(ipad.devices.value, ['Studio iPad']);
    });

    test('stopping publishing hangs the cable up', () async {
      ipad.start(host);
      await _until(() => relay.attached.value);
      ipad.stop();
      await _until(() => !relay.attached.value);
      expect(relay.attached.value, isFalse);
      expect(ipad.devices.value, isEmpty);
    });
  });
}
