// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dns_message.dart';

/// The service Bel advertises. `_bel._tcp` under the local domain, as DNS-SD
/// spells it.
const String belServiceType = '_bel._tcp.local';

const String _multicastAddress = '224.0.0.251';
const int _multicastPort = 5353;

/// Time to live on the records advertised, seconds. RFC 6763's recommendation
/// for a service that will send a goodbye when it stops.
const int _recordTtl = 120;

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

/// Binds the multicast socket both roles need.
///
/// `reusePort` is asked for and then not insisted on. macOS already runs a
/// system responder on 5353 and will not share the port without it; Windows has
/// no equivalent option and refuses the request outright. Trying and falling
/// back is two lines and covers both, where picking either one alone silently
/// loses discovery on a whole platform.
Future<RawDatagramSocket?> _bindMulticast() async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _multicastPort,
      reuseAddress: true,
      reusePort: true,
    );
  } on Object {
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _multicastPort,
        reuseAddress: true,
      );
    } on Object {
      return null;
    }
  }

  try {
    socket.joinMulticast(InternetAddress(_multicastAddress));
    // 255 is what mDNS specifies; the default of 1 is a link-local hop count
    // that some switches treat differently.
    socket.multicastHops = 255;
  } on Object {
    // A machine with no multicast-capable interface — a VM with host-only
    // networking, a locked-down corporate laptop. Discovery will not work here
    // and the UI's typed-address path is why that is survivable.
    socket.close();
    return null;
  }

  return socket;
}

/// Advertises this host's display service on the local network.
///
/// Best-effort by design. Every failure path here ends in "discovery does not
/// work on this machine", never in an exception reaching the app: multicast is
/// the first thing a guest network blocks and the first thing a corporate
/// image disables, and a metering tool that refused to publish because it could
/// not announce itself would be broken in exactly the rooms it is needed in.
/// The UI always offers a typed address as well.
class MdnsResponder {
  MdnsResponder({required this.instanceName, required this.port});

  /// Assigning before [start] simply records the value; the first announcement
  /// carries it.
  set txt(Map<String, String> value) {
    if (mapEquals(_txt, value)) return;
    _txt = value;
    _announce();
  }

  /// Unique on the network. Bel uses the host name the user chose.
  final String instanceName;
  final int port;

  /// The TXT record's contents.
  ///
  /// Mutable because one of the things it carries is the format being
  /// measured, and a host whose interface changes sample rate mid-session would
  /// otherwise keep advertising the old one — a browser list that describes a
  /// signal nobody is measuring any more. Assigning re-announces.
  Map<String, String> get txt => _txt;
  Map<String, String> _txt = const {};

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  int _announcements = 0;

  /// The `<instance>._bel._tcp.local` name the records hang off.
  String get _serviceInstance => '$instanceName.$belServiceType';

  /// A host name for the SRV target and the A records. `.local` because that is
  /// the only domain multicast DNS claims.
  String get _hostName => '${_sanitise(instanceName)}.local';

  bool get isAdvertising => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;

    final socket = await _bindMulticast();
    if (socket == null) return;
    _socket = socket;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null) _handle(datagram);
    }, onError: (Object _) {});

    // RFC 6762 §8.3: announce more than once, a second apart, because the first
    // one is the one that gets lost.
    _announcements = 0;
    _announce();
    _announceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_announcements >= 3) {
        timer.cancel();
        _announceTimer = null;
        return;
      }
      _announce();
    });
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;

    final socket = _socket;
    if (socket == null) return;
    _socket = null;

    // A goodbye is the same records with a zero TTL. Without it every tablet on
    // the network keeps offering a host that has gone until the TTL runs out,
    // and somebody taps it and waits for a connection that cannot happen.
    _send(socket, await _records(ttl: 0));
    socket.close();
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;
    _announcements++;
    unawaited(_records().then((records) => _send(socket, records)));
  }

  void _handle(Datagram datagram) {
    final message = decodeMessage(datagram.data);
    if (message == null || message.isResponse) return;

    final asked = message.questions.any(
      (q) =>
          (q.name == belServiceType ||
              q.name == _serviceInstance ||
              q.name == _hostName) &&
          (q.type == DnsType.ptr ||
              q.type == DnsType.srv ||
              q.type == DnsType.txt ||
              q.type == DnsType.a ||
              q.type == DnsType.any),
    );
    if (!asked) return;

    final socket = _socket;
    if (socket == null) return;
    unawaited(_records().then((records) => _send(socket, records)));
  }

  Future<List<DnsRecord>> _records({int ttl = _recordTtl}) async {
    final records = <DnsRecord>[
      DnsRecord(
        name: belServiceType,
        type: DnsType.ptr,
        ttl: ttl,
        target: _serviceInstance,
      ),
      DnsRecord(
        name: _serviceInstance,
        type: DnsType.srv,
        ttl: ttl,
        cacheFlush: true,
        port: port,
        target: _hostName,
      ),
      DnsRecord(
        name: _serviceInstance,
        type: DnsType.txt,
        ttl: ttl,
        cacheFlush: true,
        txt: txt,
      ),
    ];

    for (final address in await _localAddresses()) {
      records.add(
        DnsRecord(
          name: _hostName,
          type: DnsType.a,
          ttl: ttl,
          cacheFlush: true,
          address: address.rawAddress,
        ),
      );
    }

    return records;
  }

  void _send(RawDatagramSocket socket, List<DnsRecord> records) {
    try {
      // The PTR is the answer; everything else is what makes it useful. A
      // browser that received only the PTR would have to ask three more
      // questions before it could show a row.
      final packet = encodeResponse(
        answers: records.take(1).toList(),
        additionals: records.skip(1).toList(),
      );
      socket.send(packet, InternetAddress(_multicastAddress), _multicastPort);
    } on Object {
      // Nothing to do about a send that failed; the next announcement or query
      // will try again.
    }
  }
}

/// Watches the network for hosts advertising [belServiceType].
class MdnsBrowser {
  /// Hosts seen recently, newest information winning. A [ValueNotifier] rather
  /// than a stream because the discovery list is a widget that rebuilds — this
  /// is configuration-shaped state, not measurement-shaped state, and it
  /// changes a few times a minute.
  final ValueNotifier<List<DiscoveredHost>> hosts = ValueNotifier(const []);

  /// Whether the socket could be opened at all. False means this machine cannot
  /// do multicast discovery and the UI should say so and offer an address
  /// field, rather than showing an empty list that looks like "nothing found".
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  RawDatagramSocket? _socket;
  Timer? _queryTimer;
  Timer? _pruneTimer;

  final Map<String, DiscoveredHost> _found = {};

  /// Instance names seen in a PTR whose SRV has not arrived, and the addresses
  /// of host names an SRV pointed at before the A record turned up. Multicast
  /// packets arrive in whatever order the network feels like.
  final Map<String, String> _hostAddresses = {};
  final Map<String, _PendingService> _pending = {};

  Future<void> start() async {
    if (_socket != null) return;

    final socket = await _bindMulticast();
    if (socket == null) {
      isBrowsing.value = false;
      return;
    }
    _socket = socket;
    isBrowsing.value = true;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null) _handle(datagram);
    }, onError: (Object _) {});

    _query();
    // Re-asking costs one small packet and covers the host that was switched on
    // after the display was.
    _queryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _query());
    _pruneTimer = Timer.periodic(const Duration(seconds: 10), (_) => _prune());
  }

  Future<void> stop() async {
    _queryTimer?.cancel();
    _pruneTimer?.cancel();
    _queryTimer = null;
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _found.clear();
    _pending.clear();
    _hostAddresses.clear();
    hosts.value = const [];
    isBrowsing.value = false;
  }

  void _query() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(
        encodeQuery(belServiceType, DnsType.ptr),
        InternetAddress(_multicastAddress),
        _multicastPort,
      );
    } on Object {
      // Same as the responder: the next tick tries again.
    }
  }

  void _handle(Datagram datagram) {
    final message = decodeMessage(datagram.data);
    if (message == null || !message.isResponse) return;

    var changed = false;

    for (final record in message.answers) {
      switch (record.type) {
        case DnsType.ptr:
          if (record.name != belServiceType) break;
          if (record.ttl == 0) {
            // A goodbye.
            final instance = _instanceOf(record.target);
            if (_found.remove(instance) != null) changed = true;
            _pending.remove(instance);
            break;
          }
          _pending.putIfAbsent(_instanceOf(record.target), _PendingService.new);

        case DnsType.srv:
          if (!record.name.endsWith(belServiceType)) break;
          final instance = _instanceOf(record.name);
          final pending = _pending.putIfAbsent(instance, _PendingService.new)
            ..port = record.port
            ..hostName = record.target;
          if (_resolve(instance, pending)) changed = true;

        case DnsType.txt:
          if (!record.name.endsWith(belServiceType)) break;
          final instance = _instanceOf(record.name);
          final pending = _pending.putIfAbsent(instance, _PendingService.new)
            ..txt = record.txt;
          if (_resolve(instance, pending)) changed = true;

        case DnsType.a:
          if (record.address.length != 4) break;
          _hostAddresses[record.name] = record.address.join('.');
          // An A record can arrive after the SRV that needed it, so anything
          // waiting on this host name may now be complete.
          for (final entry in _pending.entries) {
            if (entry.value.hostName == record.name &&
                _resolve(entry.key, entry.value)) {
              changed = true;
            }
          }
      }
    }

    if (changed) _publish();
  }

  /// Promotes a service to the visible list once it has both a port and an
  /// address. A row that cannot be tapped is worse than no row.
  bool _resolve(String instance, _PendingService pending) {
    final hostName = pending.hostName;
    final port = pending.port;
    if (hostName == null || port == null) return false;

    final address = _hostAddresses[hostName];
    if (address == null) {
      // Ask for it directly rather than waiting for the next announcement.
      final socket = _socket;
      if (socket != null) {
        try {
          socket.send(
            encodeQuery(hostName, DnsType.a),
            InternetAddress(_multicastAddress),
            _multicastPort,
          );
        } on Object {
          // Best effort.
        }
      }
      return false;
    }

    final existing = _found[instance];
    final host = DiscoveredHost(
      instanceName: instance,
      address: address,
      port: port,
      txt: pending.txt,
      seenAt: DateTime.now(),
    );
    _found[instance] = host;

    return existing == null ||
        existing.address != address ||
        existing.port != port ||
        !mapEquals(existing.txt, pending.txt);
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 90));
    final gone = _found.entries
        .where((entry) => entry.value.seenAt.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    if (gone.isEmpty) return;
    for (final instance in gone) {
      _found.remove(instance);
      _pending.remove(instance);
    }
    _publish();
  }

  void _publish() {
    final list = _found.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    hosts.value = list;
  }

  static String _instanceOf(String name) {
    if (!name.endsWith('.$belServiceType')) return name;
    return name.substring(0, name.length - belServiceType.length - 1);
  }

  void dispose() {
    unawaited(stop());
    hosts.dispose();
    isBrowsing.dispose();
  }
}

class _PendingService {
  int? port;
  String? hostName;
  Map<String, String> txt = const {};
}

/// This machine's non-loopback IPv4 addresses, as text.
///
/// Shown in the host's own UI so that somebody whose network blocks multicast
/// has something to type into the tablet. A discovery feature that cannot tell
/// you where to look when discovery fails is half a feature.
Future<List<String>> localIPv4Addresses() async => [
  for (final address in await _localAddresses()) address.address,
];

/// This machine's non-loopback IPv4 addresses, for the A records.
///
/// All of them, not the first: a laptop on Wi-Fi with a Thunderbolt dock has
/// two, and which one the tablet can reach is not knowable from here.
Future<List<InternetAddress>> _localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    return [for (final interface in interfaces) ...interface.addresses];
  } on Object {
    return const [];
  }
}

/// DNS-SD instance names are free-form, but a host name is not. Anything that
/// is not a letter, digit or hyphen becomes a hyphen.
String _sanitise(String name) {
  final cleaned = name
      .split('')
      .map((c) => RegExp(r'[A-Za-z0-9-]').hasMatch(c) ? c : '-')
      .join();
  final trimmed = cleaned.replaceAll(RegExp('-+'), '-');
  return trimmed.isEmpty ? 'bel' : trimmed;
}
