// SPDX-License-Identifier: GPL-3.0-or-later
//
// `src/oaa_usb.h`, by hand: seven functions and one struct are fewer lines than
// an ffigen configuration. The asset id is this library's URI, which is what
// `hook/build.dart` names the library it builds.

import 'dart:ffi';

final class OaaUsbDevice extends Struct {
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
  @Uint8()
  external int bus;
  @Uint8()
  external int address;
  @Uint8()
  external int kind;
  @Uint8()
  external int reserved;
}

const int kindCandidate = 1;
const int kindAccessory = 2;

final class OaaUsbLink extends Opaque {}

@Native<Int32 Function()>(symbol: 'oaa_usb_init')
external int oaaUsbInit();

@Native<Int32 Function(Pointer<OaaUsbDevice>, Int32)>(symbol: 'oaa_usb_scan')
external int oaaUsbScan(Pointer<OaaUsbDevice> out, int capacity);

@Native<
  Int32 Function(
    Uint8,
    Uint8,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
  )
>(symbol: 'oaa_usb_switch')
external int oaaUsbSwitch(
  int bus,
  int address,
  Pointer<Char> manufacturer,
  Pointer<Char> model,
  Pointer<Char> description,
  Pointer<Char> version,
  Pointer<Char> uri,
  Pointer<Char> serial,
);

@Native<Pointer<OaaUsbLink> Function(Uint8, Uint8)>(symbol: 'oaa_usb_open')
external Pointer<OaaUsbLink> oaaUsbOpen(int bus, int address);

@Native<Int32 Function(Pointer<OaaUsbLink>, Pointer<Uint8>, Int32, Uint32)>(
  symbol: 'oaa_usb_read',
)
external int oaaUsbRead(
  Pointer<OaaUsbLink> link,
  Pointer<Uint8> buffer,
  int capacity,
  int timeoutMs,
);

@Native<Int32 Function(Pointer<OaaUsbLink>, Pointer<Uint8>, Int32, Uint32)>(
  symbol: 'oaa_usb_write',
)
external int oaaUsbWrite(
  Pointer<OaaUsbLink> link,
  Pointer<Uint8> bytes,
  int length,
  int timeoutMs,
);

@Native<Void Function(Pointer<OaaUsbLink>)>(symbol: 'oaa_usb_close')
external void oaaUsbClose(Pointer<OaaUsbLink> link);
