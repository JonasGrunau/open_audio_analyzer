// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compiles libusb and the accessory layer over it, for the three desktops.
//
// **Windows opens devices only through UsbDk**, a filter driver the Windows
// installer puts down behind a checkbox — see `src/oaa_usb.c` for why the
// WinUSB backend can open an Android tablet at neither end of the switch. The
// library is built there regardless; without UsbDk its context refuses to
// start, `AccessoryBus.available` answers false, and the application offers
// the other cables.
//
// **Nothing at all for iOS and Android**, which are the other end of the
// cable.
//
// Sources are listed one by one, as `oaa_engine`'s are.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _libusb = 'third_party/libusb/libusb';

const _common = <String>[
  'src/oaa_usb.c',
  '$_libusb/core.c',
  '$_libusb/descriptor.c',
  '$_libusb/hotplug.c',
  '$_libusb/io.c',
  '$_libusb/strerror.c',
  '$_libusb/sync.c',
];

const _posix = <String>[
  '$_libusb/os/events_posix.c',
  '$_libusb/os/threads_posix.c',
];

List<String> _backend(OS os) => switch (os) {
  OS.macOS => const [..._posix, '$_libusb/os/darwin_usb.c'],
  OS.linux => const [
    ..._posix,
    '$_libusb/os/linux_usbfs.c',
    // Hot-plug through netlink rather than libudev, so the library links
    // nothing a distribution might not have.
    '$_libusb/os/linux_netlink.c',
  ],
  // UsbDk and WinUSB both: libusb chooses per context, and the context asks
  // for UsbDk. No `windows_hotplug.c` — the application polls, as it does
  // everywhere, and libusb builds it only when asked to.
  OS.windows => const [
    '$_libusb/os/events_windows.c',
    '$_libusb/os/threads_windows.c',
    '$_libusb/os/windows_common.c',
    '$_libusb/os/windows_usbdk.c',
    '$_libusb/os/windows_winusb.c',
  ],
  _ => const [],
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The empty pass `flutter run` makes; see oaa_engine's hook.
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.linux && os != OS.windows) return;

    final builder = CBuilder.library(
      name: input.packageName,
      assetName: 'src/bindings.dart',
      sources: [..._common, ..._backend(os)],
      includes: const ['src', _libusb],
      // Objective-C on macOS for one reason: `CBuilder` passes `frameworks`
      // to the linker only for that language, and the Darwin backend needs
      // IOKit. libusb is C and compiles as Objective-C unchanged.
      language: os == OS.macOS ? Language.objectiveC : Language.c,
      frameworks: os == OS.macOS
          ? const ['IOKit', 'CoreFoundation', 'Security']
          : const [],
      // libusb loads SetupAPI, WinUSB and UsbDkHelper itself, at run time,
      // so Windows links kernel32 alone and nothing has to be present to load
      // this library — only to open a device with it.
      libraries: switch (os) {
        OS.linux => const ['pthread'],
        OS.windows => const ['kernel32'],
        _ => const [],
      },
      std: 'c11',
      defines: os == OS.windows ? const {} : const {'_GNU_SOURCE': null},
      flags: os == OS.macOS
          ? const ['-x', 'objective-c', '-mmacos-version-min=14.2']
          : const [],
    );
    await builder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        // The build hook's log goes to the build output, as oaa_engine's does.
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
