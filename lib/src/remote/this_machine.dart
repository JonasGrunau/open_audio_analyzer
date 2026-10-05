// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'display_host.dart';
import 'mdns/mdns_service.dart';
import 'remote_display_service.dart';

/// Whether the machine somebody is about to attach to is the one they are
/// sitting at.
///
/// **A machine cannot be its own display.** Attaching covers this window's
/// canvas with somebody else's meters; pointed here it covers the canvas with a
/// copy of itself — the same measurement, taken once, serialised onto a socket,
/// decoded a frame later and drawn a second time beside the first. Nothing
/// fails, which is what makes it worth refusing rather than leaving to the
/// user: the port is open, the handshake succeeds, the link says Connected, and
/// the screen is a display of a machine that is standing right there. The way
/// back is Disconnect, and the thing it goes back to is what was already on
/// screen.
///
/// **A desktop that is publishing finds itself.** The browser and the responder
/// are two objects in one process on one multicast group, so this machine's own
/// announcement comes back to it like anybody else's — which means the first
/// row in the list, on a machine that is alone on the network, is the machine
/// the list is being read on. That is the door this closes. The typed address
/// and the scanned code go through the same question, because the wrong answer
/// is the same wrong answer whichever way it was given.
///
/// **What is refused is this instance, not this machine** — [isThisInstance]
/// asks about an address *and* a port, and the port has to be one this process
/// is listening on. It used to ask about the address alone, on the argument
/// that nothing else on this machine could be attached to, and the argument
/// stopped being true the day a tablet could be plugged in: an Android tablet
/// on a USB cable reaches its desktop at `127.0.0.1`, through the reverse
/// forward `adb` sets up, and that address is this machine by every test in
/// this file. What is at the other end of it is a different instance on a
/// different computer. See `usb_link.dart`.
///
/// **What it cannot see is a renamed iPad.** iOS browses through the system
/// responder, which hands back the SRV target rather than an address, so a
/// self-match there is a name match: the name below covers the one this
/// application derives from the machine's own, and not one the user typed into
/// Settings → Publish. Every other platform resolves to an address and is
/// matched exactly.
class ThisMachine {
  ThisMachine() : _loopbackIsSelf = true, _listening = _hostPorts {
    _addresses.addAll(_loopbackNames.map(_key));
  }

  static Iterable<int> _hostPorts() => DisplayHost.listeningPorts;

  /// A machine that answers to exactly these, plus loopback.
  ///
  /// For a widget test, because the real answer is a `NetworkInterface.list`
  /// away: a `testWidgets` body runs in a fake-async zone that the real event
  /// loop never returns to, so a test that awaited [resolve] would hang until
  /// the runner killed it — and one that did not await it would assert against
  /// whatever the machine running the suite happens to be plugged into.
  ///
  /// [listening] is the ports this instance holds; null means every port,
  /// which is what a test of the address half wants. [overUsb] is this
  /// machine's own addresses on a USB link, as `resolve` would have found them
  /// on a tethered tablet.
  @visibleForTesting
  ThisMachine.at(
    Iterable<String> addresses, {
    Iterable<int>? listening,
    Iterable<String> overUsb = const [],
  }) : _resolved = true,
       _loopbackIsSelf = true,
       _listening = listening == null ? null : (() => listening) {
    _usbSubnets.addAll(overUsb.map(_subnet));
    _addresses
      ..addAll(_loopbackNames.map(_key))
      ..addAll(addresses.map(_key));
  }

  /// A machine that is nowhere, so that nothing is refused — loopback
  /// included.
  ///
  /// For the one kind of test that starts a display host in its own process
  /// and then types that host's address into the picker. `127.0.0.1` is this
  /// machine and the product is right to refuse it; a suite that cannot say
  /// otherwise can only cover the typed-address path by not using it.
  @visibleForTesting
  ThisMachine.nowhere()
    : _resolved = true,
      _loopbackIsSelf = false,
      _listening = null;

  /// True on every machine there is, so that `localhost` is refused before an
  /// interface has said anything.
  static const Set<String> _loopbackNames = {
    'localhost',
    '127.0.0.1',
    '::1',
    '0.0.0.0',
    '::',
  };

  final Set<String> _addresses = {};

  /// Whether 127/8 and the names above are this machine. They are, on every
  /// machine that is not [ThisMachine.nowhere].
  final bool _loopbackIsSelf;

  /// The ports this instance is listening on, or null for "all of them".
  final Iterable<int> Function()? _listening;

  /// The first three octets of every IPv4 address on an interface that is a
  /// USB link: Android's `rndis0`, `usb0` or `ncm0` while USB tethering is
  /// on. A host found on one of those subnets was found down the cable, and
  /// the picker says so. See [isOverUsb].
  final Set<String> _usbSubnets = {};

  static final RegExp _usbInterface = RegExp(r'^(rndis|usb|ncm)\d');

  bool _resolved = false;

  /// Reads the interfaces and the machine's own name, once.
  ///
  /// Best effort, like everything else on this path: a machine that refuses to
  /// enumerate its interfaces still refuses loopback, and a list that is one
  /// address short offers a row that should not have been there rather than
  /// failing. Awaiting it is not required — [contains] answers with whatever is
  /// known — but a caller that draws a list wants to rebuild when it completes.
  Future<void> resolve() async {
    if (_resolved) return;
    _resolved = true;

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.any,
      );
      for (final interface in interfaces) {
        final usb = _usbInterface.hasMatch(interface.name);
        for (final address in interface.addresses) {
          _addresses.add(_key(address.address));
          if (usb && address.type == InternetAddressType.IPv4) {
            _usbSubnets.add(_subnet(address.address));
          }
        }
      }
    } on Object {
      // A platform that will not enumerate is not a reason to let a self
      // attach through the loopback check.
    }

    // Three shapes of the same name, because three things produce one: what
    // the system calls this machine, what a person types at it, and what the
    // responder advertises it as. `studio-mac.fritz.box`, `studio-mac.local`
    // and `studio-mac-oaa.local` are one computer.
    try {
      final full = Platform.localHostname.trim();
      if (full.isNotEmpty) _addresses.add(_key(full));
    } on Object {
      // Nothing to add.
    }
    final name = RemoteDisplayService.defaultHostName();
    _addresses
      ..add(_key(name))
      ..add(_key('$name.local'))
      ..add(_key(oaaHostName(name)));
  }

  /// Whether attaching to [host] on [port] would attach this instance to
  /// itself — which is the only attach that is refused. See the class comment.
  bool isThisInstance(String host, int port) {
    if (!contains(host)) return false;
    final listening = _listening;
    return listening == null || listening().contains(port);
  }

  /// Whether [address] is on the far side of a USB link rather than the
  /// network: a host found over USB tethering. Loopback is not asked about
  /// here; a reverse forward is recognised by the probe that found it.
  bool isOverUsb(String address) {
    final parsed = InternetAddress.tryParse(_clean(address));
    if (parsed == null || parsed.type != InternetAddressType.IPv4) {
      return false;
    }
    return _usbSubnets.contains(_subnet(parsed.address));
  }

  /// A /24, which is what every Android tethering subnet is.
  static String _subnet(String ipv4) =>
      ipv4.substring(0, ipv4.lastIndexOf('.'));

  /// Whether [host] is this machine.
  bool contains(String host) {
    final text = _clean(host);
    if (text.isEmpty) return false;
    // The whole of 127/8, not the one address in it anybody types. Every
    // address in the block is this machine and a loopback interface reports
    // one of them.
    if (_loopbackIsSelf &&
        text.startsWith('127.') &&
        InternetAddress.tryParse(text)?.type == InternetAddressType.IPv4) {
      return true;
    }
    return _addresses.contains(_key(text));
  }

  /// One key per host, so that the set can be a set.
  ///
  /// An IP literal is keyed by its **bytes**, because the text is not unique:
  /// `fe80::1`, `[fe80::1]`, `fe80::1%en0` and `FE80:0:0:0:0:0:0:1` are one
  /// address written four ways, `InternetAddress` keeps whichever one it was
  /// handed, and the one an interface reports is not the one a person types.
  /// Anything that is not a literal is a name and is keyed by its text.
  static String _key(String host) {
    final text = _clean(host);
    final address = InternetAddress.tryParse(text);
    if (address == null) return text;
    return address.rawAddress
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// The spelling both of the above work from: lower case, no brackets, no
  /// zone — which names the interface a link-local address is local to and not
  /// the address — and no trailing dot, which is a fully qualified name's way
  /// of saying it is one.
  static String _clean(String host) {
    var text = host.trim().toLowerCase();
    if (text.startsWith('[') && text.endsWith(']')) {
      text = text.substring(1, text.length - 1);
    }
    final zone = text.indexOf('%');
    if (zone >= 0) text = text.substring(0, zone);
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return text;
  }
}
