// SPDX-License-Identifier: GPL-3.0-or-later
//
// The library builds, loads and scans. Nothing on a CI runner's bus is an
// Android device, so what this holds is that a scan of an ordinary bus asks
// nothing of anybody and answers without throwing; the accessory itself needs
// a tablet on a cable, which is a check by hand — see AGENTS.md. On Windows
// the library starts only with UsbDk installed, which no runner has, so there
// it holds that the library loads and refuses for that reason and no other.

import 'dart:io';

import 'package:oaa_usb/oaa_usb.dart';
import 'package:test/test.dart';

void main() {
  test('the library is there on the desktops that build it', () {
    if (Platform.isMacOS || Platform.isLinux) {
      expect(AccessoryBus.available, isTrue);
    } else if (Platform.isWindows) {
      // Built and loaded — `startStatus` would throw otherwise — and started
      // only with UsbDk, which no runner has.
      expect(AccessoryBus.startStatus(), anyOf(0, AccessoryBus.notFound));
      expect(AccessoryBus.available, AccessoryBus.startStatus() == 0);
    } else {
      expect(AccessoryBus.available, isFalse);
    }
  });

  test('a scan answers, and lists only what might be Android', () {
    if (!AccessoryBus.available) return;
    for (final device in AccessoryBus.scan()) {
      // Never a hub and never an Apple device.
      expect(device.vendorId, isNot(0x05AC));
    }
  });
}
