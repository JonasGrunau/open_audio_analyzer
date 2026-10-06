# packages/oaa_usb/

The Android Open Accessory protocol, desktop side: an Android tablet on a USB
cable becomes a byte stream, with no USB debugging and no `adb`.
GPL-3.0-or-later; `third_party/libusb/` is LGPL-2.1-or-later.

| Path | Purpose |
|------|---------|
| `src/oaa_usb.h` | The whole C surface: scan, switch to accessory, open, read, write, close. |
| `src/oaa_usb.c` | AOSP's three vendor requests and the two bulk endpoints, over libusb. Which devices are asked at all — Android vendors, or an MTP/PTP/adb interface — is `classify`. |
| `src/config.h` | libusb's `config.h`, by hand, for macOS, Linux and Windows. libusb's own build generates it with autoconf. |
| `hook/build.dart` | Compiles the above for the three desktops, and nothing anywhere else. |
| `lib/oaa_usb.dart` | The library: exports `src/accessory.dart`. |
| `lib/src/accessory.dart` | `AccessoryBus` (available, scan, switch, open) and `AccessoryLink`, an accessory as a stream in and a sink out, read and written on two isolates. |
| `lib/src/bindings.dart` | `oaa_usb.h` as `@Native` bindings, by hand. |
| `test/accessory_test.dart` | The library builds where it should, loads, and scans without throwing. |
| `third_party/libusb/` | libusb 1.0.30, the core and the Darwin, Linux, POSIX and Windows backends, with `COPYING` and `AUTHORS`. Unmodified. `windows_hotplug.c` is vendored and not built: libusb compiles it only when asked to, and the application polls. |

**What it does not know** is anything carried. The stream is
`docs/WIRE.md` § USB carriage, and `lib/src/remote/usb_relay.dart` and
`accessory_usb.dart` in the application are the ones that read it. The tablet's
half is `android/.../OaaAccessory.kt` and the manifest's
`res/xml/accessory_filter.xml`.

## Rules

- **The accessory is named by two strings, and three files must agree on
  them.** `AccessoryIdentity`'s `Open Audio Analyzer` and `Display`,
  `accessory_filter.xml`, and the `MANUFACTURER`/`MODEL` constants in
  `OaaAccessory.kt`. A mismatch is silent: Android simply never offers the app.

- **Asking is not free, so it is narrowed twice.** `classify` asks only devices
  from an Android vendor or with an MTP, PTP or adb interface — a keyboard or an
  audio interface on the same bus is never sent a vendor request — and the
  application asks each of those once per plug-in and only while publishing,
  because a phone that is only charging loses file transfer until it is
  unplugged and is shown a prompt about an app it may not have.

- **Every transfer blocks, so none happens on the UI isolate.** The reader
  returns every 200 ms to look at its stop flag and the writer waits on its
  port; `AccessoryLink.close` waits for both isolates to exit before
  `oaa_usb_close` frees the handle. The application runs `scan` and the switch
  through `Isolate.run` for the same reason.

- **On Windows a device is opened through UsbDk or not at all.** An Android
  tablet that is not yet an accessory belongs to Windows' MTP driver, which
  forwards no vendor request, and one that is an accessory sends no Microsoft
  OS descriptors and belongs to no driver — so libusb's WinUSB backend can open
  it at neither end of the switch. UsbDk, a filter driver, lets libusb borrow a
  device from whatever owns it and give it back on close. `oaa_usb_init` asks
  for `LIBUSB_OPTION_USE_USBDK`; without UsbDk installed libusb refuses the
  option and the context with it, `AccessoryBus.startStatus` answers
  `notFound`, and `available` is false. The library is still built and
  shipped, and links `kernel32` alone: libusb loads SetupAPI, WinUSB and
  `UsbDkHelper.dll` itself when it needs them. The driver is the Windows
  installer's to put down — see `packaging/AGENTS.md`. **x64 and x86 only**:
  UsbDk ships no ARM64 build, and the installer is x64.

- **Nothing in CI can see an accessory.** No runner has an Android device on
  its bus. The check is by hand, with a tablet that has USB debugging *off*:
  publish on the desktop, plug the tablet in, say yes to "Open Audio Analyzer"
  on it, and its ATTACH panel lists the desktop under Over USB as "USB cable".
  `test/usb_relay_test.dart` in the application holds everything after the
  bulk endpoints. Last done 2026-10-05 on a Nothing Phone (2a) and a Mac, with
  debugging off (18D1:2D00) and on (2D01), and across a reinstall of the
  application with the cable in. On Windows the same check needs an x64 PC with
  the installer's USB driver row ticked; it has not been done yet.
