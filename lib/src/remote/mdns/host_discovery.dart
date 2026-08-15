// SPDX-License-Identifier: GPL-3.0-or-later

/// What "find the hosts on this network" means, and which of the two ways of
/// doing it this platform is allowed to use.
///
/// There are two implementations and the picker cannot tell them apart:
///
/// * [MdnsBrowser] speaks multicast DNS over a socket Bel owns. It is the one
///   that works on macOS, Windows and Linux, and it is the reason
///   `mdns/dns_message.dart` exists rather than a plugin — see its header.
/// * `BonjourDiscovery` asks the system responder, over a channel. It exists
///   because **iOS and iPadOS refuse the first one on real hardware.** A send to
///   224.0.0.251 fails with `EHOSTUNREACH` and nothing is delivered inbound
///   unless the app carries `com.apple.developer.networking.multicast`, which
///   Apple grants per team by request, and which a project people build for
///   themselves therefore cannot rely on. Bonjour through the system responder
///   needs no entitlement: `NSLocalNetworkUsageDescription` and
///   `NSBonjourServices` in `Info.plist` are the whole requirement, and both
///   were already there.
///
/// The trap is that the iOS **simulator** has no such restriction, so the raw
/// socket works there and fails on the iPad — which is how a tablet shipped
/// with a browser that had never once found anything, under a UI that said
/// "Looking for hosts on this network…" for as long as anybody cared to wait.
///
/// Only the browsing half is split this way. A tablet is a display: it never
/// advertises, so [MdnsResponder] stays the single implementation of the
/// sending end.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bonjour_discovery.dart';
import 'mdns_service.dart';

/// A host found on the network.
class DiscoveredHost {
  DiscoveredHost({
    required this.instanceName,
    required this.address,
    required this.port,
    required this.txt,
    required this.seenAt,
  });

  /// The DNS-SD instance name, which is unique on the network.
  final String instanceName;

  /// Where to connect. An address from the A record on the socket path, and the
  /// SRV target — `studio-mac.local` — on the Bonjour one, because the system
  /// resolver is better placed to choose between a laptop's Wi-Fi and its
  /// dock than a browser holding two A records is.
  final String address;

  final int port;
  final Map<String, String> txt;
  final DateTime seenAt;

  /// What to put in the list. The TXT name if the host gave one — it is
  /// free-form and may contain characters DNS-SD escapes — otherwise the
  /// instance name.
  String get displayName {
    final advertised = txt['name'];
    if (advertised != null && advertised.isNotEmpty) return advertised;
    return instanceName;
  }

  /// The signal the host says it is measuring, for the list. Absent while the
  /// host has not settled on a format.
  String? get format {
    final rate = txt['sr'];
    final channels = txt['ch'];
    if (rate == null || channels == null) return null;
    final khz = (int.tryParse(rate) ?? 0) / 1000;
    return '$channels ch · ${khz.toStringAsFixed(khz % 1 == 0 ? 0 : 1)} kHz';
  }

  DiscoveredHost copyWith({
    String? address,
    int? port,
    Map<String, String>? txt,
    DateTime? seenAt,
  }) => DiscoveredHost(
    instanceName: instanceName,
    address: address ?? this.address,
    port: port ?? this.port,
    txt: txt ?? this.txt,
    seenAt: seenAt ?? this.seenAt,
  );
}

/// Watching the network for Bel hosts.
abstract interface class HostDiscovery {
  /// Hosts seen recently, newest information winning. A [ValueNotifier] rather
  /// than a stream because the discovery list is a widget that rebuilds — this
  /// is configuration-shaped state, not measurement-shaped state, and it
  /// changes a few times a minute.
  ValueNotifier<List<DiscoveredHost>> get hosts;

  /// Whether a search is actually running.
  ValueNotifier<bool> get isBrowsing;

  /// Why it is not, in a sentence for a person, or null while nothing has gone
  /// wrong.
  ///
  /// **This is the whole difference between a feature that is off and a feature
  /// that is broken**, and for eight phases there was no way to tell: the
  /// socket bound, every send failed, each failure was swallowed by an empty
  /// `catch`, and the panel showed "Looking for hosts on this network…" for
  /// ever. Anything that stops discovery working says so here.
  ValueNotifier<String?> get failure;

  Future<void> start();
  Future<void> stop();
  void dispose();
}

/// The discovery this platform is allowed to do.
HostDiscovery createHostDiscovery() =>
    Platform.isIOS ? BonjourDiscovery() : MdnsBrowser();
