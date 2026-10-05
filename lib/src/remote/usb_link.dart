// SPDX-License-Identifier: GPL-3.0-or-later

/// A display on a USB cable: both ends of it.
///
/// **The protocol does not change, and neither does the direction of the
/// connection.** A display still dials a host and the host still listens on
/// 47821. What a cable adds is a route: `adb reverse tcp:47821 tcp:<port>`
/// makes the desktop's display port answer at `127.0.0.1:47821` *on the
/// tablet*, over the USB link, with nothing on either network in the way. So
/// the desktop half is one command run for every Android device it can see
/// while it is publishing, and the tablet half is a knock on its own loopback
/// port to see whether anybody answers there.
///
/// Why it is worth a file: the lag somebody reported was a tablet on Wi-Fi, and
/// the question that came with it was whether the cable could be used instead.
/// It can, and the one thing that stood in the way was the host picker, which
/// refused `127.0.0.1` outright as "this machine" — true on a desktop, and on a
/// tablet the address of somebody else's desktop at the end of a cable. The
/// refusal is now of this *instance*, which is the thing that was always meant;
/// see `ThisMachine.isThisInstance`.
///
/// **Android only, at both ends.** `adb` speaks to Android devices, and an iPad
/// has no equivalent a desktop can drive without Xcode: `usbmuxd` forwards the
/// other way round, desktop to device, which would need the tablet to be the
/// one listening. USB tethering is the other cable an Android tablet offers,
/// and it needs nothing here at all — it is a network, discovery finds the host
/// on it, and the picker marks a host found on a USB interface with the USB
/// mark as well; see `ThisMachine.isOverUsb`.
///
/// It needs `adb` on the desktop and USB debugging on the tablet. That is a
/// developer's setup rather than everybody's, which is why the README names
/// tethering beside it. It is not behind a setting: with no `adb` on the
/// machine nothing runs, and with one, forwarding a port that is already open
/// on the network to a device already trusted for debugging exposes nothing
/// that was not exposed before — and it happens only while PUBLISH is on.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:oaa_wire/oaa_wire.dart';

import 'display_host.dart';

// ---------------------------------------------------------------------------
// The tablet's half

/// Somebody answering on this device's own display port — a desktop at the far
/// end of an `adb reverse` forward.
@immutable
class UsbHost {
  const UsbHost({required this.name, this.port = DisplayHost.defaultPort});

  /// What the host called itself in its `HELLO`.
  final String name;

  /// The port on *this* device the forward answers at, which is the default
  /// whatever the desktop itself listens on: the forward maps one to the
  /// other.
  final int port;

  /// Always loopback. The forward is a listening socket on this device.
  String get address => InternetAddress.loopbackIPv4.address;

  @override
  bool operator ==(Object other) =>
      other is UsbHost && other.name == name && other.port == port;

  @override
  int get hashCode => Object.hash(name, port);
}

/// Knocks on loopback every couple of seconds, and says who answered.
///
/// **A knock is a whole handshake, not a connect.** `adbd` accepts on the
/// forwarded port whether or not anything is listening at the desktop end, and
/// closes the connection a moment later if nothing is — so a socket that opens
/// is not a host. One that sends a valid `HELLO` is, and its name is what the
/// row prints.
///
/// **It never knocks on this instance.** A tablet that is itself publishing
/// holds the port, and its own `HELLO` would come back as a row offering to
/// attach it to itself. The listening ports are the process's own
/// [DisplayHost.listeningPorts], which is an exact answer.
///
/// Each knock is seen by the desktop as a display that attaches and leaves,
/// which costs it a `HELLO`, a layout and a skin — a few kilobytes every two
/// seconds, while a picker is open and not otherwise.
class UsbHostProbe {
  UsbHostProbe({
    this.port = DisplayHost.defaultPort,
    this.interval = const Duration(seconds: 2),
  });

  final int port;
  final Duration interval;

  /// Whether this platform has a USB link to probe. Android only — see the
  /// library comment. Overridden by the suite, which runs on a desktop.
  @visibleForTesting
  static bool? platformSupported;

  static bool get supported => platformSupported ?? Platform.isAndroid;

  /// Who answered the last knock, or null.
  final ValueNotifier<UsbHost?> host = ValueNotifier(null);

  Timer? _timer;
  bool _knocking = false;
  bool _disposed = false;

  void start() {
    if (!supported || _timer != null) return;
    unawaited(_knock());
    _timer = Timer.periodic(interval, (_) => unawaited(_knock()));
  }

  Future<void> _knock() async {
    if (_knocking || _disposed) return;
    _knocking = true;
    try {
      final found = DisplayHost.listeningPorts.contains(port)
          ? null
          : await knock(InternetAddress.loopbackIPv4, port);
      if (!_disposed) host.value = found;
    } finally {
      _knocking = false;
    }
  }

  /// One knock: connect, wait for a `HELLO`, hang up. Null for anything else.
  @visibleForTesting
  static Future<UsbHost?> knock(
    InternetAddress address,
    int port, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      final reader = FrameReader(initialCapacity: WireFrame.headerBytes + 256);
      final hello = Completer<UsbHost?>();
      final subscription = socket.listen(
        (chunk) {
          if (hello.isCompleted) return;
          reader.add(chunk);
          try {
            while (reader.moveNext()) {
              if (reader.type != WireFrameType.hello) continue;
              final decoded = WireHello.decode(reader.payload);
              hello.complete(UsbHost(name: decoded.producerName, port: port));
              return;
            }
          } on Object {
            hello.complete(null);
          }
        },
        onError: (Object _) {
          if (!hello.isCompleted) hello.complete(null);
        },
        onDone: () {
          if (!hello.isCompleted) hello.complete(null);
        },
        cancelOnError: true,
      );
      final found = await hello.future.timeout(timeout, onTimeout: () => null);
      await subscription.cancel();
      return found;
    } on Object {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    host.dispose();
  }
}

// ---------------------------------------------------------------------------
// The desktop's half

/// Runs one command and hands back what it said. The seam a test replaces.
typedef AdbRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// While publishing, forwards the display port to every Android device `adb`
/// can see.
///
/// **Polled rather than watched**, every few seconds: `adb track-devices`
/// exists but is a long-lived socket protocol of its own, and a cable plugged
/// in at the desk is a thing a person waits two seconds for without noticing.
///
/// **Removed on the way out.** A forward outlives the process that made it —
/// it belongs to `adbd` on the device — and one left behind would answer the
/// next knock with a connection that goes nowhere. It would not show as a host
/// (a knock wants a `HELLO`), but it is ours to clean up.
///
/// Nothing here is reported as a failure. A desktop with no `adb` is the
/// ordinary case, and a device that refuses the forward is one that has not
/// been authorised for debugging, which `adb` itself prompts about on the
/// tablet.
class AdbReverse {
  AdbReverse({AdbRunner? run, this.interval = const Duration(seconds: 3)})
    : _run = run ?? Process.run;

  final AdbRunner _run;
  final Duration interval;

  /// The Android devices the display port is forwarded to, by the name `adb`
  /// gives them — for Settings → Publish to say so.
  final ValueNotifier<List<String>> devices = ValueNotifier(const []);

  /// Serial → the name shown in [devices], for every device forwarded to.
  final Map<String, String> _forwarded = {};

  String? _adb;
  bool _located = false;
  int? _hostPort;
  Timer? _timer;
  bool _polling = false;

  /// Where `adb` usually is, in the order it is looked for.
  ///
  /// **Not only the `PATH`.** An application launched from the Dock or the
  /// Start menu does not get the shell's `PATH`, so an SDK somebody put on it
  /// in `.zshrc` is invisible from here; the SDK's own default locations are
  /// where it actually is on most machines that have one.
  @visibleForTesting
  static List<String> candidates(Map<String, String> environment) {
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
    final exe = Platform.isWindows ? 'adb.exe' : 'adb';
    final sep = Platform.pathSeparator;
    return [
      for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
        if ((environment[key] ?? '').isNotEmpty)
          '${environment[key]}${sep}platform-tools$sep$exe',
      if (Platform.isMacOS) '$home/Library/Android/sdk/platform-tools/adb',
      if (Platform.isLinux) '$home/Android/Sdk/platform-tools/adb',
      if (Platform.isWindows && (environment['LOCALAPPDATA'] ?? '').isNotEmpty)
        '${environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
      if (Platform.isMacOS) ...['/opt/homebrew/bin/adb', '/usr/local/bin/adb'],
      if (Platform.isLinux) '/usr/bin/adb',
      exe,
    ];
  }

  Future<String?> _locate() async {
    if (_located) return _adb;
    _located = true;
    for (final candidate in candidates(Platform.environment)) {
      try {
        final result = await _run(candidate, const ['version']);
        if (result.exitCode == 0) return _adb = candidate;
      } on Object {
        // Not there; the next one.
      }
    }
    return null;
  }

  /// Starts forwarding the display port, which this machine is listening on
  /// at [hostPort], to the default port on every device.
  Future<void> start(int hostPort) async {
    if (_hostPort == hostPort && _timer != null) return;
    await stop();
    _hostPort = hostPort;
    if (await _locate() == null || _hostPort != hostPort) return;
    await poll();
    _timer ??= Timer.periodic(interval, (_) => unawaited(poll()));
  }

  /// One look at the devices. Public so a test can take one without a timer.
  @visibleForTesting
  Future<void> poll() async {
    final adb = _adb;
    final hostPort = _hostPort;
    if (adb == null || hostPort == null || _polling) return;
    _polling = true;
    try {
      final ProcessResult listed;
      try {
        listed = await _run(adb, const ['devices', '-l']);
      } on Object {
        return;
      }
      if (listed.exitCode != 0) return;

      final present = parseDevices('${listed.stdout}');
      _forwarded.removeWhere((serial, _) => !present.containsKey(serial));

      for (final MapEntry(key: serial, value: name) in present.entries) {
        if (_forwarded.containsKey(serial)) continue;
        try {
          final result = await _run(adb, [
            '-s',
            serial,
            'reverse',
            'tcp:${DisplayHost.defaultPort}',
            'tcp:$hostPort',
          ]);
          if (result.exitCode == 0) _forwarded[serial] = name;
        } on Object {
          // Tried again on the next poll.
        }
      }
      // Only on a change: this runs every few seconds, and a notifier handed
      // an equal list in a new instance rebuilds whatever draws it each time.
      final names = List<String>.unmodifiable(_forwarded.values);
      if (_hostPort == hostPort && !listEquals(names, devices.value)) {
        devices.value = names;
      }
    } finally {
      _polling = false;
    }
  }

  /// `adb devices -l`, as serial → a name for a person. Only devices that are
  /// ready: `unauthorized` and `offline` cannot be forwarded to.
  @visibleForTesting
  static Map<String, String> parseDevices(String output) {
    final devices = <String, String>{};
    for (final line in output.split('\n').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 2 || fields[1] != 'device') continue;
      final model = fields
          .where((field) => field.startsWith('model:'))
          .map((field) => field.substring(6).replaceAll('_', ' '))
          .firstOrNull;
      devices[fields[0]] = model ?? fields[0];
    }
    return devices;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _hostPort = null;
    final adb = _adb;
    final serials = List.of(_forwarded.keys);
    _forwarded.clear();
    devices.value = const [];
    if (adb == null) return;
    for (final serial in serials) {
      try {
        await _run(adb, [
          '-s',
          serial,
          'reverse',
          '--remove',
          'tcp:${DisplayHost.defaultPort}',
        ]);
      } on Object {
        // The device went with the cable; so did the forward.
      }
    }
  }

  void dispose() {
    unawaited(stop());
    devices.dispose();
  }
}
