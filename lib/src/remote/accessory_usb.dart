// SPDX-License-Identifier: GPL-3.0-or-later

/// An Android tablet on a cable with no USB debugging: the accessory route.
///
/// While publishing, the desktop looks at the bus every two seconds. A device
/// that might be Android is asked — once — to become an *accessory*, which is
/// AOSP's protocol for a USB host that wants to talk to an app: the device
/// leaves the bus and comes back as Google's 18D1:2D00, and Android offers to
/// open Open Audio Analyzer for it. A device already in accessory mode is
/// opened, and its two bulk endpoints become a [UsbRelayHost] — after which the
/// tablet's display finds this desktop on its relay port exactly as it would at
/// the end of any other cable. See `usb_relay.dart` for the relay and
/// `packages/oaa_usb` for the protocol.
///
/// **Asked once per plug-in, and only while publishing.** A phone charging on
/// the desk is a device that might be Android too, and being switched into
/// accessory mode costs it file transfer until it is unplugged and a prompt
/// about an app it may not have. So a device is asked once for each time it
/// appears on the bus, and never while PUBLISH is off — the same rule every
/// other route here follows.
///
/// macOS and Linux always; Windows only with UsbDk installed, which the
/// Windows installer offers — see `packages/oaa_usb/src/oaa_usb.c` for why.
/// [create] answers null wherever accessories cannot be opened.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:oaa_usb/oaa_usb.dart';

import 'display_host.dart';
import 'usb_link.dart';
import 'usb_relay.dart';

class AccessoryUsb implements UsbRoute {
  AccessoryUsb({this.interval = const Duration(seconds: 2)});

  /// The route, or null on a platform without the library.
  static AccessoryUsb? create() =>
      AccessoryBus.available ? AccessoryUsb() : null;

  final Duration interval;

  @override
  final ValueNotifier<List<String>> devices = ValueNotifier(const []);

  /// Open accessories, by bus location.
  final Map<String, UsbRelayHost> _cables = {};

  /// Devices already asked to switch, by id and location — a replug is a new
  /// location and is asked again, which is what plugging a tablet in means.
  final Set<String> _asked = {};

  /// Accessories that were opened and never said who they are — the tablet
  /// has not opened the app — and when to try them again. Not every two
  /// seconds: each try is a write that waits out its timeout.
  final Map<String, DateTime> _quietUntil = {};

  DisplayHost? _host;
  Timer? _timer;
  bool _polling = false;

  @override
  void start(DisplayHost host) {
    if (identical(host, _host) && _timer != null) return;
    stop();
    _host = host;
    unawaited(_poll());
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final host = _host;
    if (host == null || _polling) return;
    _polling = true;
    try {
      // Off the UI thread: enumeration and the switch's control requests are
      // synchronous, and a device slow to answer would hold a frame.
      final found = await Isolate.run(AccessoryBus.scan);
      if (!identical(host, _host)) return;
      final present = {for (final device in found) device.location};
      _asked.removeWhere((key) => !present.contains(key.split('@').last));
      _quietUntil.removeWhere((location, _) => !present.contains(location));

      for (final device in found) {
        if (device.isAccessory) {
          if (_cables.containsKey(device.location)) continue;
          final quiet = _quietUntil[device.location];
          if (quiet != null && DateTime.now().isBefore(quiet)) continue;
          final link = await AccessoryBus.open(device);
          if (link == null) continue;
          if (!identical(host, _host)) {
            await link.close();
            return;
          }
          _attach(device.location, link, host);
        } else {
          final key =
              '${device.vendorId}:${device.productId}@${device.location}';
          if (!_asked.add(key)) continue;
          await Isolate.run(() => AccessoryBus.switchToAccessory(device));
        }
      }
    } on Object {
      // A bus that will not enumerate is a desktop with no cable to offer.
    } finally {
      _polling = false;
    }
  }

  void _attach(String location, AccessoryLink link, DisplayHost host) {
    final cable = UsbRelayHost(
      _AccessoryPipe(link),
      host,
      onClosed: (closed) {
        if (identical(_cables[location], closed)) {
          _cables.remove(location);
          if (closed.name.value == null) {
            _quietUntil[location] = DateTime.now().add(
              const Duration(seconds: 10),
            );
          }
          _publish();
        }
      },
    );
    _cables[location] = cable;
    cable.name.addListener(_publish);
  }

  void _publish() {
    final names = List<String>.unmodifiable([
      for (final cable in _cables.values)
        // A cable is a tablet only once its relay has said who it is: an
        // accessory whose app is not open answers nothing at all.
        if (!cable.isClosed && cable.name.value != null) cable.name.value!,
    ]);
    if (!listEquals(names, devices.value)) devices.value = names;
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _host = null;
    final cables = List.of(_cables.values);
    _cables.clear();
    for (final cable in cables) {
      cable.close();
    }
    if (devices.value.isNotEmpty) devices.value = const [];
  }

  @override
  void dispose() {
    stop();
    devices.dispose();
  }
}

class _AccessoryPipe implements UsbPipe {
  _AccessoryPipe(this._link);
  final AccessoryLink _link;

  @override
  Stream<Uint8List> get input => _link.input;

  @override
  void add(List<int> bytes) => _link.add(bytes);

  @override
  Future<void> flush() => _link.flush();

  @override
  void destroy() => unawaited(_link.close());
}
