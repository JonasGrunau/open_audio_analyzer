// SPDX-License-Identifier: GPL-3.0-or-later
//
// A display on a USB cable, both halves: the knock a tablet makes on its own
// loopback port, and the `adb reverse` a desktop runs so that somebody answers
// it. Neither half needs a device — the knock is a real socket on this
// machine's loopback, which is exactly where a reverse forward puts the
// desktop, and `adb` is a runner the suite replaces.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa/src/remote/this_machine.dart';
import 'package:oaa/src/remote/usb_link.dart';
import 'package:oaa_core/oaa_core.dart';

void main() {
  group('the knock', () {
    test('finds a host by the name its HELLO gives', () async {
      final host = DisplayHost(
        source: null,
        hostName: 'Studio Mac',
        abiVersion: 4,
      );
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      await host.start(port: 0);

      final found = await UsbHostProbe.knock(
        InternetAddress.loopbackIPv4,
        host.port!,
      );
      expect(found?.name, 'Studio Mac');
      expect(found?.address, '127.0.0.1');
    });

    test('a socket that opens and says nothing is not a host', () async {
      // What `adbd` does on the tablet when a forward exists and nothing is
      // listening at the desktop end: accept, and hang up a moment later.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        Future<void>.delayed(const Duration(milliseconds: 50), socket.destroy);
      });

      expect(
        await UsbHostProbe.knock(InternetAddress.loopbackIPv4, server.port),
        isNull,
      );
    });

    test('and nobody listening is nobody', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(
        await UsbHostProbe.knock(InternetAddress.loopbackIPv4, port),
        isNull,
      );
    });

    test('never knocks on this instance', () async {
      // A tablet that is itself publishing holds the port, and its own HELLO
      // would come back as a host to attach it to itself.
      final host = DisplayHost(source: null, hostName: 'Me', abiVersion: 4);
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      await host.start(port: 0);

      UsbHostProbe.platformSupported = true;
      addTearDown(() => UsbHostProbe.platformSupported = null);
      final probe = UsbHostProbe(ports: [host.port!])..start();
      addTearDown(probe.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(probe.host.value, isNull);
    });
  });

  group('this instance, not this machine', () {
    test('loopback is refused only on a port this process holds', () {
      final machine = ThisMachine.at(const [], listening: const [50000]);

      // The USB case: the tablet's loopback, answered by a desktop down a
      // cable.
      expect(
        machine.isThisInstance('127.0.0.1', DisplayHost.defaultPort),
        isFalse,
      );
      // And the one that is still refused: this very host.
      expect(machine.isThisInstance('127.0.0.1', 50000), isTrue);
      expect(machine.isThisInstance('localhost', 50000), isTrue);
    });

    test('a host on a USB interface is marked as one', () {
      final machine = ThisMachine.at(
        const ['192.168.42.129'],
        overUsb: const ['192.168.42.129'],
      );
      expect(machine.isOverUsb('192.168.42.20'), isTrue);
      expect(machine.isOverUsb('192.168.1.20'), isFalse);
      expect(machine.isOverUsb('studio.local'), isFalse);
    });
  });

  group('adb reverse', () {
    test('reads the devices that are ready, by model', () {
      final devices = AdbReverse.parseDevices(
        'List of devices attached\n'
        'emulator-5560          device product:sdk_gphone64_arm64 '
        'model:Pixel_Tablet device:emu64a transport_id:3\n'
        'R58N123ABC             unauthorized usb:1-1 transport_id:4\n'
        'P11275000244           device usb:2-1 product:x model:A063 '
        'transport_id:5\n'
        '\n',
      );
      expect(devices, {
        'emulator-5560': 'Pixel Tablet',
        'P11275000244': 'A063',
      });
    });

    test('forwards every device once, and takes it back on stop', () async {
      final calls = <String>[];
      var listed =
          'List of devices attached\n'
          'tablet-1\tdevice model:Pixel_Tablet\n';
      final adb = AdbReverse(
        interval: const Duration(hours: 1),
        run: (executable, arguments) async {
          calls.add(arguments.join(' '));
          return ProcessResult(
            0,
            0,
            arguments.first == 'devices' ? listed : '',
            '',
          );
        },
      );
      addTearDown(adb.dispose);

      await adb.start(50123);
      expect(adb.devices.value, ['Pixel Tablet']);
      expect(
        calls,
        contains(
          '-s tablet-1 reverse tcp:${DisplayHost.defaultPort} tcp:50123',
        ),
      );

      // Polled again with the same device: no second forward.
      await adb.poll();
      expect(
        calls.where((call) => call.contains('reverse tcp:')),
        hasLength(1),
      );

      // A second tablet plugged in.
      listed =
          '$listed'
          'tablet-2\tdevice model:Galaxy_Tab\n';
      await adb.poll();
      expect(adb.devices.value, ['Pixel Tablet', 'Galaxy Tab']);

      await adb.stop();
      expect(adb.devices.value, isEmpty);
      expect(
        calls,
        containsAll([
          '-s tablet-1 reverse --remove tcp:${DisplayHost.defaultPort}',
          '-s tablet-2 reverse --remove tcp:${DisplayHost.defaultPort}',
        ]),
      );
    });

    test('a machine with no adb runs nothing more', () async {
      var runs = 0;
      final adb = AdbReverse(
        run: (executable, arguments) async {
          runs++;
          throw const ProcessException('adb', [], 'not found', 2);
        },
      );
      addTearDown(adb.dispose);

      await adb.start(47821);
      final looked = runs;
      await adb.poll();
      expect(runs, looked, reason: 'it went on running a missing binary');
      expect(adb.devices.value, isEmpty);
    });
  });

  test('a recent host is a place, not a name', () {
    const a = RecentHost(host: 'Studio.local', port: 47821, name: 'A');
    const b = RecentHost(host: 'studio.local', port: 47821, name: 'B');
    expect(a.sameAddress(b), isTrue);
    expect(
      a.sameAddress(const RecentHost(host: 'studio.local', port: 1)),
      isFalse,
    );
  });
}
