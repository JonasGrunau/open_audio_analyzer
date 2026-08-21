// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dns_message.dart';
import 'host_discovery.dart';
import 'multicast_lock.dart';

/// The service Open Audio Analyzer advertises. `_oaa._tcp` under the local
/// domain, as DNS-SD spells it.
const String oaaServiceType = '_oaa._tcp.local';

/// The same type without the domain, which is how Apple's DNS-SD API spells it
/// and therefore what `Info.plist` and `OaaBonjour.swift` say.
const String oaaServiceName = '_oaa._tcp';

const String _multicastAddress = '224.0.0.251';
const int _multicastPort = 5353;

/// Time to live on the records advertised, seconds. RFC 6763's recommendation
/// for a service that will send a goodbye when it stops.
const int _recordTtl = 120;

/// Binds the multicast socket both roles need, and says why when it cannot.
///
/// `reusePort` is asked for and then not insisted on. macOS already runs a
/// system responder on 5353 and will not share the port without it; Windows has
/// no equivalent option and refuses the request outright. Trying and falling
/// back is two lines and covers both, where picking either one alone silently
/// loses discovery on a whole platform.
///
/// The error is returned rather than thrown — nothing about discovery may throw
/// — but it is *returned*, which the first eight phases did not do. A caller
/// that is handed null and no reason can only show an empty list.
Future<(RawDatagramSocket?, Object?)> _bindMulticast() async {
  RawDatagramSocket socket;
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
    } on Object catch (error) {
      return (null, error);
    }
  }

  try {
    socket.joinMulticast(InternetAddress(_multicastAddress));
    // 255 is what mDNS specifies; the default of 1 is a link-local hop count
    // that some switches treat differently.
    socket.multicastHops = 255;
  } on Object catch (error) {
    // A machine with no multicast-capable interface — a VM with host-only
    // networking, a locked-down corporate laptop. Discovery will not work here
    // and the UI's typed-address path is why that is survivable.
    socket.close();
    return (null, error);
  }

  return (socket, null);
}

/// Why discovery is not working, in a sentence for a person.
String describeDiscoveryFailure(Object? error) {
  if (error is SocketException) {
    final osError = error.osError;
    // **`EHOSTUNREACH` on a multicast send is what a refused local-network
    // permission looks like from inside the process.** The socket binds, the
    // group joins, `NetworkInterface.list` reports the Wi-Fi address, the
    // routing table has a route for 224.0.0/4, `ping 224.0.0.251` is answered
    // by half the building — and every packet the process sends is refused
    // with "no route to host". Nothing else about the machine looks wrong,
    // which is why this needs saying in words rather than reporting an errno.
    if (Platform.isMacOS && osError != null && osError.errorCode == 65) {
      return 'macOS is not letting Open Audio Analyzer search the local network. Allow it '
          'under System Settings › Privacy & Security › Local Network, or '
          'enter an address below.';
    }
    return osError == null
        ? error.message
        : '${error.message} (${osError.message})';
  }
  if (error == null) {
    return 'This device cannot search the network for hosts. Enter an address '
        'below.';
  }
  return error.toString();
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

  /// Unique on the network. Open Audio Analyzer uses the host name the user
  /// chose.
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

  /// Whether this responder is one of the holders of the multicast lock.
  ///
  /// Advertising is mostly sending, which needs no lock — but a browser that
  /// asks a direct question gets an answer only if the question arrives, and on
  /// Android nothing multicast arrives without one. See `multicast_lock.dart`.
  bool _locked = false;

  /// The instance as **one label**, which is what DNS-SD says it is.
  ///
  /// **A dot in here does not name an instance with a dot in it; it invents
  /// labels.** Names are written by splitting on `.`, so a machine called
  /// `studio-mac.fritz.box` — which is what `Platform.localHostname` returns on
  /// any network whose DHCP server hands out a domain — was advertised as
  /// `studio-mac` `fritz` `box` `_oaa` `_tcp` `local`, six labels where DNS-SD
  /// expects four. Open Audio Analyzer's own reader takes everything before
  /// `_oaa._tcp.local` as the instance and is perfectly happy, so
  /// desktop-to-desktop discovery worked and hid this completely; Apple's
  /// responder is not, and drops the record. The symptom is a host that answers
  /// every query on the wire and is invisible to `dns-sd -B` and to every iPad
  /// in the building.
  ///
  /// The friendly name is not lost: it rides in the TXT record's `name`, which
  /// is free-form and is what a picker shows.
  @visibleForTesting
  String get instanceLabel => instanceName.replaceAll('.', '-');

  /// The `<instance>._oaa._tcp.local` name the records hang off.
  @visibleForTesting
  String get serviceInstance => '$instanceLabel.$oaaServiceType';

  /// A host name for the SRV target and the A records. `.local` because that is
  /// the only domain multicast DNS claims.
  ///
  /// **Deliberately not the machine's own `.local` name**, which is what
  /// sanitising the instance alone would produce. That name belongs to the
  /// system responder, which defends it: an A record it did not announce, for a
  /// name it owns, is a conflict, and RFC 6762 says the loser renames itself.
  /// Open Audio Analyzer advertises every interface's address on every
  /// interface, so its set differs from the system's per-interface set as soon
  /// as a machine has two — and the machine that renames itself is the user's,
  /// in System Settings, because a meter announced itself carelessly.
  @visibleForTesting
  String get hostName => '${_sanitise(instanceLabel)}-oaa.local';

  bool get isAdvertising => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;

    // Taken before the bind and given back with the socket. The failure is not
    // read here: a responder that cannot hear a query still announces itself
    // three times and then on every change, which is what browsers work from.
    // The browser is the half that has a panel to put a sentence in.
    _locked = true;
    await MulticastLock.acquire();

    final (socket, _) = await _bindMulticast();
    if (socket == null) {
      _unlock();
      return;
    }
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
    _unlock();

    final socket = _socket;
    if (socket == null) return;
    _socket = null;

    // A goodbye is the same records with a zero TTL. Without it every tablet on
    // the network keeps offering a host that has gone until the TTL runs out,
    // and somebody taps it and waits for a connection that cannot happen.
    _send(socket, await _records(ttl: 0));
    socket.close();
  }

  /// Gives back the multicast lock, once, however this responder ends.
  void _unlock() {
    if (!_locked) return;
    _locked = false;
    MulticastLock.release();
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
          (q.name == oaaServiceType ||
              q.name == serviceInstance ||
              q.name == hostName) &&
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
        name: oaaServiceType,
        type: DnsType.ptr,
        ttl: ttl,
        target: serviceInstance,
      ),
      DnsRecord(
        name: serviceInstance,
        type: DnsType.srv,
        ttl: ttl,
        cacheFlush: true,
        port: port,
        target: hostName,
      ),
      DnsRecord(
        name: serviceInstance,
        type: DnsType.txt,
        ttl: ttl,
        cacheFlush: true,
        txt: txt,
      ),
    ];

    for (final address in await _localAddresses()) {
      records.add(
        DnsRecord(
          name: hostName,
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

/// Watches the network for hosts advertising [oaaServiceType].
///
/// The implementation of [HostDiscovery] for every platform that lets an
/// application hold a multicast socket, which is all of them except iOS and
/// iPadOS — see `host_discovery.dart`. Android lets it hold one and then
/// delivers nothing into it unless a `WifiManager.MulticastLock` is held, which
/// is what [MulticastLock] is and why [start] takes it before the bind.
class MdnsBrowser implements HostDiscovery {
  @override
  final ValueNotifier<List<DiscoveredHost>> hosts = ValueNotifier(const []);

  @override
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  @override
  final ValueNotifier<String?> failure = ValueNotifier(null);

  RawDatagramSocket? _socket;
  Timer? _queryTimer;
  Timer? _pruneTimer;

  /// Whether anybody still wants this search.
  ///
  /// **Binding is real I/O and the browser can be torn down while it is in
  /// flight** — a panel closed on the frame it opened, a hot restart, the
  /// display screen replacing its own picker. The socket that arrives after
  /// that belongs to nobody: closing it is all there is left to do with it, and
  /// everything else [start] would go on to do writes to a `ValueNotifier` that
  /// [dispose] has already disposed. On macOS the window is wide enough to hit
  /// by hand, because the first bind of a session waits on the Local Network
  /// permission the system is asking about.
  bool _wanted = false;

  /// Whether this browser is one of the holders of the multicast lock.
  ///
  /// Set before the lock is asked for, not after: [MulticastLock.acquire]
  /// counts its caller synchronously, so a teardown that lands while the
  /// channel call is in flight has to give back the hold that already exists.
  bool _locked = false;

  final Map<String, DiscoveredHost> _found = {};

  /// Instance names seen in a PTR whose SRV has not arrived, and the addresses
  /// of host names an SRV pointed at before the A record turned up. Multicast
  /// packets arrive in whatever order the network feels like.
  ///
  /// A host name maps to *every* address announced for it, because a laptop on
  /// Wi-Fi in a Thunderbolt dock announces two and only one of them is the one
  /// this tablet can reach.
  final Map<String, List<String>> _hostAddresses = {};
  final Map<String, _PendingService> _pending = {};

  @override
  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;

    // **Before the socket, because on Android a socket without this receives
    // nothing and reports nothing.** The lock is what lifts the Wi-Fi driver's
    // multicast filter; everywhere else this is a no-op. A failure to take it
    // is carried rather than acted on — a device with no Wi-Fi has nothing
    // filtering multicast in the first place, so the browse is still worth
    // running and the sentence is what the panel shows next to it.
    _locked = true;
    final lockFailure = await MulticastLock.acquire();

    final (socket, error) = await _bindMulticast();
    // Checked before the failure below it, not after: a bind that failed while
    // the browser was going away must not report that to a disposed notifier
    // either. The lock is already given back by whatever set `_wanted` false.
    if (!_wanted) {
      socket?.close();
      return;
    }
    if (socket == null) {
      _wanted = false;
      _unlock();
      isBrowsing.value = false;
      failure.value = describeDiscoveryFailure(error);
      return;
    }
    _socket = socket;
    isBrowsing.value = true;
    // The search is running; whether anything can reach it is the other half of
    // what the panel needs, and null when nothing is in the way.
    failure.value = lockFailure;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null) _handle(datagram);
    }, onError: _fail);

    _query();
    // Re-asking costs one small packet and covers the host that was switched on
    // after the display was.
    _queryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _query());
    _pruneTimer = Timer.periodic(const Duration(seconds: 10), (_) => _prune());
  }

  @override
  Future<void> stop() async {
    _release();
    hosts.value = const [];
    isBrowsing.value = false;
    failure.value = null;
  }

  /// Everything [stop] gives back that is not a notifier.
  ///
  /// Apart from the publishing half because [dispose] must do this and *not*
  /// that: a write to a disposed `ValueNotifier` throws, and teardown is
  /// precisely when the two would meet.
  void _release() {
    _wanted = false;
    _unlock();
    _queryTimer?.cancel();
    _pruneTimer?.cancel();
    _queryTimer = null;
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _found.clear();
    _pending.clear();
    _hostAddresses.clear();
  }

  /// Gives back the multicast lock, once, however this browser ends.
  void _unlock() {
    if (!_locked) return;
    _locked = false;
    MulticastLock.release();
  }

  /// A send that failed is not a tick to try again on; it is the reason the
  /// list stays empty. Dart reports a datagram socket's send errors through the
  /// stream rather than from `send`, so both paths end here.
  void _fail(Object error) {
    isBrowsing.value = false;
    failure.value = describeDiscoveryFailure(error);
  }

  void _query() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(
        encodeQuery(oaaServiceType, DnsType.ptr),
        InternetAddress(_multicastAddress),
        _multicastPort,
      );
    } on Object catch (error) {
      _fail(error);
    }
  }

  /// Feeds a datagram to the browser as if the socket had delivered it.
  ///
  /// Everything between "a PTR arrived" and "there is a row somebody can tap"
  /// is otherwise reachable only through a multicast socket, and a test that
  /// opens one passes or fails on the machine's network. There is not even a
  /// loopback route in: on macOS a unicast datagram sent to 5353 is handed to
  /// the system responder rather than to whoever else holds the port. This
  /// state machine went eight phases with no test for exactly that reason,
  /// which is how it kept the last address a host announced rather than the
  /// one that could be reached.
  @visibleForTesting
  void handleDatagram(Uint8List data) => _handleMessage(data);

  void _handle(Datagram datagram) => _handleMessage(datagram.data);

  void _handleMessage(Uint8List data) {
    final message = decodeMessage(data);
    if (message == null || !message.isResponse) return;

    var changed = false;

    // **Addresses first, and all of them.** The SRV that needs one is usually
    // in the same packet and multicast promises nothing about the order; and
    // every A record Open Audio Analyzer sends carries the cache-flush bit,
    // which means "this is the whole truth about this name", so a packet
    // replaces what was known rather than adding to it. Keeping the last record
    // seen instead — which is what a plain assignment per record does — is how
    // a laptop that announces its Wi-Fi address and then the 169.254 address of
    // an empty dock ends up listed at the one nothing can reach.
    final announced = <String, List<String>>{};
    for (final record in message.answers) {
      if (record.type != DnsType.a || record.address.length != 4) continue;
      announced
          .putIfAbsent(record.name, () => <String>[])
          .add(record.address.join('.'));
    }
    _hostAddresses.addAll(announced);

    for (final record in message.answers) {
      switch (record.type) {
        case DnsType.ptr:
          if (record.name != oaaServiceType) break;
          if (record.ttl == 0) {
            // A goodbye.
            final instance = _instanceOf(record.target);
            if (_found.remove(instance) != null) changed = true;
            _pending.remove(instance);
            break;
          }
          _pending.putIfAbsent(_instanceOf(record.target), _PendingService.new);

        case DnsType.srv:
          if (!record.name.endsWith(oaaServiceType)) break;
          final instance = _instanceOf(record.name);
          final pending = _pending.putIfAbsent(instance, _PendingService.new)
            ..port = record.port
            ..hostName = record.target;
          if (_resolve(instance, pending)) changed = true;

        case DnsType.txt:
          if (!record.name.endsWith(oaaServiceType)) break;
          final instance = _instanceOf(record.name);
          final pending = _pending.putIfAbsent(instance, _PendingService.new)
            ..txt = record.txt;
          if (_resolve(instance, pending)) changed = true;
      }
    }

    // An A record can arrive after — or without — the SRV that needed it, so
    // anything waiting on a host name this packet carried may now be complete.
    for (final entry in _pending.entries) {
      if (announced.containsKey(entry.value.hostName) &&
          _resolve(entry.key, entry.value)) {
        changed = true;
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

    final address = _pickAddress(_hostAddresses[hostName]);
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
    if (!name.endsWith('.$oaaServiceType')) return name;
    return name.substring(0, name.length - oaaServiceType.length - 1);
  }

  /// Which of a host's addresses to offer.
  ///
  /// A 169.254 address is what an interface gives itself when nothing
  /// configured it — a dock with no cable in it, a second Ethernet port, a
  /// Thunderbolt bridge. It is a real address on a real interface and nothing
  /// on the network can reach it, so it is the last resort rather than
  /// whichever one happened to be announced last.
  static String? _pickAddress(List<String>? addresses) {
    if (addresses == null || addresses.isEmpty) return null;
    for (final address in addresses) {
      if (!address.startsWith('169.254.')) return address;
    }
    return addresses.first;
  }

  @override
  void dispose() {
    _release();
    hosts.dispose();
    isBrowsing.dispose();
    failure.dispose();
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
  return trimmed.isEmpty ? 'oaa' : trimmed;
}
