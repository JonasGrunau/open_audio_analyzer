# packages/oaa_usb/

The Android Open Accessory protocol, desktop side: an Android tablet on a USB
cable becomes a byte stream, with no USB debugging and no `adb`.
GPL-3.0-or-later; `third_party/libusb/` is LGPL-2.1-or-later.

| Path | Purpose |
|------|---------|
| `src/oaa_usb.h` | The whole C surface: scan, switch to accessory, open, read, write, close. |
| `src/oaa_usb.c` | AOSP's three vendor requests and the two bulk endpoints, over libusb. Which devices are asked at all — Android vendors, or an MTP/PTP/adb interface — is `classify`. |
| `src/config.h` | libusb's `config.h`, by hand, for macOS and Linux. libusb's own build generates it with autoconf. |
| `hook/build.dart` | Compiles the above for macOS and Linux, and nothing anywhere else. |
| `lib/oaa_usb.dart` | The library: exports `src/accessory.dart`. |
| `lib/src/accessory.dart` | `AccessoryBus` (available, scan, switch, open) and `AccessoryLink`, an accessory as a stream in and a sink out, read and written on two isolates. |
| `lib/src/bindings.dart` | `oaa_usb.h` as `@Native` bindings, by hand. |
| `test/accessory_test.dart` | The library builds where it should, loads, and scans without throwing. |
| `third_party/libusb/` | libusb 1.0.30, the core and the Darwin, Linux, POSIX and Windows backends, with `COPYING` and `AUTHORS`. Unmodified. |

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

- **Windows is not built, on purpose.** An accessory-mode device sends no
  Microsoft OS descriptors, so Windows binds it to no driver and libusb cannot
  open it until a WinUSB driver has been installed for 18D1:2D00 and 2D01 —
  which is an installer's job (libwdi, or a signed INF) that has not been done.
  The switch would work and the open never would. `AccessoryBus.available` is
  false there and the application offers the other cables.

- **Nothing in CI can see an accessory.** No runner has an Android device on
  its bus. The check is by hand, with a tablet that has USB debugging *off*:
  publish on the desktop, plug the tablet in, say yes to "Open Audio Analyzer"
  on it, and its ATTACH panel lists the desktop under Over USB as "USB cable".
  `test/usb_relay_test.dart` in the application holds everything after the
  bulk endpoints.
