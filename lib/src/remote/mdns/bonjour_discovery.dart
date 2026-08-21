// SPDX-License-Identifier: GPL-3.0-or-later

/// Discovery on iOS and iPadOS, through the system responder.
///
/// Why this exists rather than the socket every other platform uses is in
/// `host_discovery.dart`. What matters here is that it carries no measurement,
/// and that it is a browser and nothing else — the tablet is a display and
/// never advertises. It is one of four platform channels in the application,
/// and the only one that replaces a whole implementation rather than
/// unblocking one: Android's `multicast_lock.dart` lets the ordinary socket
/// work, where iOS refuses that socket outright.
///
/// The native half is `ios/Runner/OaaBonjour.swift`. It emits the whole list on
/// every change rather than add and remove events, because the list is what the
/// panel draws and a channel that could drop one event of a pair is a list that
/// slowly stops matching the network.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'host_discovery.dart';

/// The channel `OaaBonjour` publishes on. Listening starts the browse;
/// cancelling stops it, so the native side owns no state the Dart side has to
/// remember to tear down.
const EventChannel bonjourChannel = EventChannel(
  'dev.openaudioanalyzer.oaa/bonjour',
);

/// The one subscription this channel is allowed to have, shared by everything
/// that reads it.
///
/// **A `FlutterEventChannel` holds a single sink per channel name**, and both
/// ways of getting that wrong are silent. A second `listen` while a sink is
/// set calls the native handler's `onCancel` before installing the new one —
/// tearing down the browse the first reader is still waiting on — and a
/// `cancel` that arrives when no sink is set is answered with
/// `PlatformException(error, No active stream to cancel)`. That one is raised
/// inside the framework's own `onCancel` closure, where no `catch` in Open
/// Audio Analyzer can reach it: it is reported to the console and the search is
/// dead. See `SetStreamHandlerMessageHandlerOnChannel` in the engine's
/// `FlutterChannels.mm`.
///
/// Two pickers overlap every time one replaces another, because a route's
/// `initState` runs before the outgoing route's `dispose`. With one
/// subscription each that window was enough: the arriving panel's `listen`
/// killed the leaving panel's browse, the leaving panel's `cancel` then killed
/// the arriving panel's, and the arriving panel's own `cancel` — with no sink
/// left to cancel — was the exception in the log. In between it showed
/// "Looking for hosts on this network…" over a browse that had already been
/// torn down.
///
/// So the channel is subscribed once for the application, and the browse ends
/// when the last reader lets go and not before.
class _SharedBrowse {
  static final Set<BonjourDiscovery> _readers = <BonjourDiscovery>{};
  static StreamSubscription<dynamic>? _subscription;

  /// The last thing the responder said. A reader that attaches to a browse
  /// already in flight has missed the list it opened with, and the responder
  /// only speaks again when the network changes — so on a static network it
  /// would wait for ever with an empty panel.
  static dynamic _latest;

  static void attach(BonjourDiscovery reader) {
    if (!_readers.add(reader)) return;
    if (_subscription == null) {
      _latest = null;
      _subscription = bonjourChannel.receiveBroadcastStream().listen(
        _deliver,
        onError: _fail,
      );
    } else if (_latest != null) {
      reader._onHosts(_latest);
    }
  }

  static Future<void> detach(BonjourDiscovery reader) async {
    // Removed before anything is awaited, so a reader that is about to dispose
    // its notifiers cannot be handed one more event on the way out.
    if (!_readers.remove(reader)) return;
    if (_readers.isNotEmpty) return;

    final subscription = _subscription;
    _subscription = null;
    _latest = null;
    await subscription?.cancel();
  }

  static void _deliver(dynamic event) {
    _latest = event;
    for (final reader in _readers.toList()) {
      reader._onHosts(event);
    }
  }

  static void _fail(Object error) {
    for (final reader in _readers.toList()) {
      reader._onError(error);
    }
  }
}

class BonjourDiscovery implements HostDiscovery {
  @override
  final ValueNotifier<List<DiscoveredHost>> hosts = ValueNotifier(const []);

  @override
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  @override
  final ValueNotifier<String?> failure = ValueNotifier(null);

  /// Whether this reader is one of the ones holding the shared browse open.
  bool _reading = false;

  @override
  Future<void> start() async {
    if (_reading) return;
    _reading = true;
    failure.value = null;
    _SharedBrowse.attach(this);
    isBrowsing.value = true;
  }

  @override
  Future<void> stop() async {
    if (!_reading) return;
    _reading = false;
    // Published before the await, never after it. Cancelling a channel
    // subscription suspends here, and a hot restart tears the browser down
    // while that cancel is in flight — so the continuation resumed after
    // `dispose` and wrote to a `ValueNotifier` that no longer existed.
    hosts.value = const [];
    isBrowsing.value = false;
    await _SharedBrowse.detach(this);
  }

  void _onHosts(dynamic event) {
    if (event is! List) return;

    final seenAt = DateTime.now();
    final found = <DiscoveredHost>[];
    for (final entry in event) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final host = entry['host'];
      final port = entry['port'];
      // A service the responder has browsed but not yet resolved has no host
      // and no port. Dropping it is the same rule the socket browser follows:
      // a row that cannot be tapped is worse than no row.
      if (name is! String || host is! String || port is! int) continue;

      final txt = <String, String>{};
      final advertised = entry['txt'];
      if (advertised is Map) {
        for (final pair in advertised.entries) {
          if (pair.key is String && pair.value is String) {
            txt[pair.key as String] = pair.value as String;
          }
        }
      }

      found.add(
        DiscoveredHost(
          instanceName: name,
          address: host,
          port: port,
          txt: txt,
          seenAt: seenAt,
        ),
      );
    }

    found.sort((a, b) => a.displayName.compareTo(b.displayName));
    hosts.value = found;
    failure.value = null;
  }

  void _onError(Object error) {
    // The one that happens in the field is a refused local-network permission:
    // the browse starts and then reports nothing for ever, which is why the
    // native side turns it into an error rather than an empty list.
    isBrowsing.value = false;
    failure.value = switch (error) {
      MissingPluginException() =>
        'This build cannot search the network for hosts. Enter an address '
            'below.',
      PlatformException(:final message?) => message,
      _ => error.toString(),
    };
  }

  @override
  void dispose() {
    // Not `stop()`: that publishes an empty list, and these notifiers are one
    // statement from being gone. Letting go of the shared browse is the whole
    // of what teardown owes the platform, and `detach` drops this reader
    // before it awaits anything, so nothing can be delivered here afterwards.
    _reading = false;
    unawaited(_SharedBrowse.detach(this));
    hosts.dispose();
    isBrowsing.dispose();
    failure.dispose();
  }
}
