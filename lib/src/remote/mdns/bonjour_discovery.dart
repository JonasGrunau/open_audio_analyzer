// SPDX-License-Identifier: GPL-3.0-or-later

/// Discovery on iOS and iPadOS, through the system responder.
///
/// Why this exists rather than the socket every other platform uses is in
/// `host_discovery.dart`. What matters here is that it is the *only* platform
/// channel in the application, that it carries no measurement, and that it is
/// a browser and nothing else — the tablet is a display and never advertises.
///
/// The native half is `ios/Runner/BelBonjour.swift`. It emits the whole list on
/// every change rather than add and remove events, because the list is what the
/// panel draws and a channel that could drop one event of a pair is a list that
/// slowly stops matching the network.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'host_discovery.dart';

/// The channel `BelBonjour` publishes on. Listening starts the browse;
/// cancelling stops it, so the native side owns no state the Dart side has to
/// remember to tear down.
const EventChannel bonjourChannel = EventChannel('dev.belmeter.bel/bonjour');

class BonjourDiscovery implements HostDiscovery {
  @override
  final ValueNotifier<List<DiscoveredHost>> hosts = ValueNotifier(const []);

  @override
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  @override
  final ValueNotifier<String?> failure = ValueNotifier(null);

  StreamSubscription<dynamic>? _subscription;

  @override
  Future<void> start() async {
    if (_subscription != null) return;
    failure.value = null;
    _subscription = bonjourChannel.receiveBroadcastStream().listen(
      _onHosts,
      onError: _onError,
    );
    isBrowsing.value = true;
  }

  @override
  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    // Published before the await, never after it. Cancelling a channel
    // subscription suspends here, and a hot restart tears the browser down
    // while that cancel is in flight — so the continuation resumed after
    // `dispose` and wrote to a `ValueNotifier` that no longer existed.
    hosts.value = const [];
    isBrowsing.value = false;
    await subscription?.cancel();
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
    // statement from being gone. Cancelling ends the native browse, which is
    // the whole of what teardown owes the platform.
    unawaited(_subscription?.cancel());
    _subscription = null;
    hosts.dispose();
    isBrowsing.dispose();
    failure.dispose();
  }
}
