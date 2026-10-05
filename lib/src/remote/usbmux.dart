// SPDX-License-Identifier: GPL-3.0-or-later

/// An iPad on a USB cable, through the daemon that already speaks to it.
///
/// Every desktop an iPad is ever plugged into runs `usbmuxd` — it is what
/// Finder, iTunes and the Apple Devices app sync through — and it will open a
/// TCP connection to a port *on the device*, carried over the cable, for any
/// local process that asks. No developer mode, no Xcode, nothing installed on
/// the iPad beyond the application, which listens on loopback the way any app
/// may. That is how Duet Display reaches an iPad, from the App Store, and it is
/// the only cable an iPad offers a desktop application at all.
///
/// **The direction is the other way round from every other route**: the
/// desktop dials and the tablet listens. That is why the tablet runs
/// `TabletRelay` — the cable arrives at [kUsbPipePort], and the display goes
/// on dialling a loopback port of its own as it always has.
///
/// The protocol is not documented by Apple; it is the one libimobiledevice,
/// Peertalk and every tool that talks to an iPhone from Linux speak. A 16-byte
/// little-endian header — length, version 1, message type 8 for a property
/// list, a tag — then an XML property list. Two messages are used: `ListDevices`,
/// and `Connect`, after whose `Result` of 0 the same socket *is* the tunnel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'display_host.dart';
import 'usb_link.dart';
import 'usb_relay.dart';

/// One device the daemon can see.
@immutable
class UsbMuxDevice {
  const UsbMuxDevice({
    required this.id,
    required this.serial,
    required this.overUsb,
  });

  /// The daemon's number for it, valid while it stays plugged in.
  final int id;
  final String serial;

  /// False for a device the daemon reaches over Wi-Fi sync. Only a cable is
  /// asked for: a network device is one the network route already reaches.
  final bool overUsb;
}

/// Where the daemon listens on this platform.
///
/// A Unix socket on macOS and Linux; on Windows, Apple Mobile Device Support —
/// installed with iTunes or the Apple Devices app — listens on TCP 27015.
typedef UsbMuxEndpoint = ({InternetAddress address, int port});

UsbMuxEndpoint? defaultUsbMuxEndpoint() {
  if (Platform.isWindows) {
    return (address: InternetAddress.loopbackIPv4, port: 27015);
  }
  if (Platform.isMacOS || Platform.isLinux) {
    return (
      address: InternetAddress(
        '/var/run/usbmuxd',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
  }
  return null;
}

/// A conversation with `usbmuxd`. Every call opens its own connection, as the
/// daemon expects: a socket that has been turned into a tunnel is spent.
class UsbMux {
  UsbMux(this.endpoint);

  final UsbMuxEndpoint endpoint;

  int _tag = 0;

  /// The devices the daemon can see, or null if there is no daemon.
  Future<List<UsbMuxDevice>?> listDevices() async {
    final Socket socket;
    try {
      socket = await _open();
    } on Object {
      return null;
    }
    try {
      final reply = await _exchange(socket, {
        'MessageType': 'ListDevices',
        ..._client,
      });
      final list = reply?.$1['DeviceList'];
      if (list is! List) return null;
      return [
        for (final entry in list)
          if (entry is Map && entry['Properties'] is Map)
            UsbMuxDevice(
              id: (entry['DeviceID'] as int?) ?? -1,
              serial: '${(entry['Properties'] as Map)['SerialNumber'] ?? ''}',
              overUsb: (entry['Properties'] as Map)['ConnectionType'] == 'USB',
            ),
      ];
    } finally {
      socket.destroy();
    }
  }

  /// A tunnel to [port] on [device], or null if nothing on the device is
  /// listening there — the application is not running, or not in front.
  Future<UsbPipe?> connect(UsbMuxDevice device, int port) async {
    final Socket socket;
    try {
      socket = await _open();
    } on Object {
      return null;
    }
    final reply = await _exchange(socket, {
      'MessageType': 'Connect',
      'DeviceID': device.id,
      // In network byte order, read by the daemon as a host-order integer.
      'PortNumber': ((port & 0xff) << 8) | ((port >> 8) & 0xff),
      ..._client,
    }, keepOpen: true);
    if (reply == null || reply.$1['Number'] != 0) {
      socket.destroy();
      return null;
    }
    return SocketPipe(socket, input: reply.$2);
  }

  static const Map<String, Object> _client = {
    'ClientVersionString': 'open-audio-analyzer',
    'ProgName': 'Open Audio Analyzer',
    'kLibUSBMuxVersion': 3,
  };

  Future<Socket> _open() => Socket.connect(
    endpoint.address,
    endpoint.port,
    timeout: const Duration(seconds: 1),
  );

  /// Sends one message and reads one reply. With [keepOpen], what follows the
  /// reply is handed back as the tunnel's input.
  Future<(Map<String, Object?>, Stream<Uint8List>)?> _exchange(
    Socket socket,
    Map<String, Object> message, {
    bool keepOpen = false,
  }) async {
    final body = utf8.encode(encodePlist(message));
    final header = ByteData(16)
      ..setUint32(0, 16 + body.length, Endian.little)
      ..setUint32(4, 1, Endian.little)
      ..setUint32(8, 8, Endian.little)
      ..setUint32(12, ++_tag, Endian.little);
    socket
      ..add(header.buffer.asUint8List())
      ..add(body);

    final rest = StreamController<Uint8List>();
    final reply = Completer<Map<String, Object?>?>();
    final buffer = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (chunk) {
        if (reply.isCompleted) {
          rest.add(chunk);
          return;
        }
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        if (bytes.length < 16) return;
        final length = ByteData.sublistView(bytes).getUint32(0, Endian.little);
        if (length < 16 || length > 1 << 20) {
          reply.complete(null);
          return;
        }
        if (bytes.length < length) return;
        final parsed = decodePlist(
          utf8.decode(bytes.sublist(16, length), allowMalformed: true),
        );
        reply.complete(parsed is Map<String, Object?> ? parsed : null);
        if (bytes.length > length) rest.add(bytes.sublist(length));
        if (!keepOpen) unawaited(subscription.cancel());
      },
      onError: (Object error) {
        if (!reply.isCompleted) reply.complete(null);
        rest.addError(error);
      },
      onDone: () {
        if (!reply.isCompleted) reply.complete(null);
        unawaited(rest.close());
      },
      cancelOnError: true,
    );

    final answer = await reply.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
    if (answer == null) {
      await subscription.cancel();
      return null;
    }
    return (answer, rest.stream);
  }
}

/// While publishing, attaches every iPad on a cable that has the application
/// open.
///
/// **Polled**, every two seconds: `Listen` would report a plug-in at once, but
/// a plug-in is not the moment that matters — the application coming to the
/// front on the iPad is, and the daemon cannot see that. So each look asks for
/// the device list and dials [kUsbPipePort] on every cabled device without a
/// relay; a refusal is the ordinary answer and costs a round trip to the
/// daemon.
class IpadUsb implements UsbRoute {
  IpadUsb({UsbMux? mux, this.interval = const Duration(seconds: 2)})
    : _mux = mux ?? _defaultMux();

  static UsbMux? _defaultMux() {
    final endpoint = defaultUsbMuxEndpoint();
    return endpoint == null ? null : UsbMux(endpoint);
  }

  final UsbMux? _mux;
  final Duration interval;

  /// The iPads attached, by the name each gave — for Settings › Publish.
  @override
  final ValueNotifier<List<String>> devices = ValueNotifier(const []);

  final Map<String, UsbRelayHost> _cables = {};
  DisplayHost? _host;
  Timer? _timer;
  bool _polling = false;

  @override
  void start(DisplayHost host) {
    if (_mux == null) return;
    if (identical(host, _host) && _timer != null) return;
    stop();
    _host = host;
    unawaited(poll());
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  @visibleForTesting
  Future<void> poll() async {
    final mux = _mux;
    final host = _host;
    if (mux == null || host == null || _polling) return;
    _polling = true;
    try {
      final listed = await mux.listDevices();
      if (listed == null || !identical(host, _host)) return;
      for (final device in listed) {
        if (!device.overUsb || _cables.containsKey(device.serial)) continue;
        final pipe = await mux.connect(device, kUsbPipePort);
        if (pipe == null) continue;
        if (!identical(host, _host)) {
          pipe.destroy();
          return;
        }
        final cable = UsbRelayHost(
          pipe,
          host,
          onClosed: (closed) {
            if (identical(_cables[device.serial], closed)) {
              _cables.remove(device.serial);
              _publish();
            }
          },
        );
        _cables[device.serial] = cable;
        cable.name.addListener(_publish);
      }
    } finally {
      _polling = false;
    }
  }

  void _publish() {
    final names = List<String>.unmodifiable([
      for (final cable in _cables.values)
        if (!cable.isClosed) cable.name.value ?? 'iPad',
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

// ---------------------------------------------------------------------------
// Property lists, as much of them as the daemon uses

/// A dictionary of strings, integers and booleans as an XML property list.
@visibleForTesting
String encodePlist(Map<String, Object> dictionary) {
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final out = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0"><dict>',
  );
  for (final MapEntry(:key, :value) in dictionary.entries) {
    out.write('<key>${escape(key)}</key>');
    out.write(switch (value) {
      final int number => '<integer>$number</integer>',
      true => '<true/>',
      false => '<false/>',
      _ => '<string>${escape('$value')}</string>',
    });
  }
  out.write('</dict></plist>');
  return out.toString();
}

/// The value inside an XML property list: dictionaries, arrays, strings,
/// integers, reals and booleans. Data and dates come back as their text. Null
/// for anything that is not a property list.
@visibleForTesting
Object? decodePlist(String xml) {
  final tokens = RegExp(
    r'<(/?)([A-Za-z]+)[^>]*?(/?)>|([^<]+)',
  ).allMatches(xml).toList();
  var at = 0;

  String unescape(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  String textUntil(String tag) {
    final text = StringBuffer();
    while (at < tokens.length) {
      final token = tokens[at++];
      if (token.group(4) != null) {
        text.write(token.group(4));
      } else if (token.group(1) == '/' && token.group(2) == tag) {
        break;
      }
    }
    return unescape(text.toString());
  }

  Object? value() {
    while (at < tokens.length) {
      final token = tokens[at++];
      final name = token.group(2);
      if (name == null || token.group(1) == '/') continue;
      final empty = token.group(3) == '/';
      switch (name) {
        case 'plist':
          continue;
        case 'true':
          return true;
        case 'false':
          return false;
        case 'string' || 'data' || 'date':
          return empty ? '' : textUntil(name);
        case 'integer':
          return int.tryParse(textUntil(name).trim());
        case 'real':
          return double.tryParse(textUntil(name).trim());
        case 'array':
          final list = <Object?>[];
          if (empty) return list;
          while (at < tokens.length) {
            final next = tokens[at];
            if (next.group(1) == '/' && next.group(2) == 'array') {
              at++;
              break;
            }
            if (next.group(4) != null) {
              at++;
              continue;
            }
            list.add(value());
          }
          return list;
        case 'dict':
          final map = <String, Object?>{};
          if (empty) return map;
          while (at < tokens.length) {
            final next = tokens[at++];
            if (next.group(1) == '/' && next.group(2) == 'dict') break;
            if (next.group(2) == 'key' && next.group(1) != '/') {
              map[textUntil('key')] = value();
            }
          }
          return map;
        default:
          continue;
      }
    }
    return null;
  }

  return value();
}
