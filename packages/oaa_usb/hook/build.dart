// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compiles libusb and the accessory layer over it, for the two desktops that
// can use it without installing a driver: macOS and Linux.
//
// **Nothing at all for the others.** iOS and Android are the *other* end of
// the cable. Windows binds an Android device in accessory mode to no driver —
// it sends no Microsoft OS descriptors — so libusb can open it only after a
// WinUSB driver has been installed for 18D1:2D00, which is an installer's job
// that has not been done; until it is, building libusb there would ship code
// that can never open anything. `AccessoryUsb.available` answers false on a
// platform with no asset, and the application offers the other cables.
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
  '$_libusb/os/events_posix.c',
  '$_libusb/os/threads_posix.c',
];

List<String> _backend(OS os) => switch (os) {
  OS.macOS => const ['$_libusb/os/darwin_usb.c'],
  OS.linux => const [
    '$_libusb/os/linux_usbfs.c',
    // Hot-plug through netlink rather than libudev, so the library links
    // nothing a distribution might not have.
    '$_libusb/os/linux_netlink.c',
  ],
  _ => const [],
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The empty pass `flutter run` makes; see oaa_engine's hook.
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.linux) return;

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
      libraries: os == OS.linux ? const ['pthread'] : const [],
      std: 'c11',
      defines: const {'_GNU_SOURCE': null},
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
