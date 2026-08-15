// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finding a host, on both of the two paths there are.
//
// `mdns_test.dart` covers the DNS codec — that a packet Bel writes is a packet
// Bel reads. This covers what happens after that: the browser's state machine,
// the channel iOS has to use instead of it, and the sentence the panel shows
// when neither of them can work. All three were untested, and the third did not
// exist: a search that could not run showed "Looking for hosts on this
// network…" for as long as anybody was willing to wait.

import 'package:bel/src/remote/host_picker.dart';
import 'package:bel/src/remote/mdns/bonjour_discovery.dart';
import 'package:bel/src/remote/mdns/dns_message.dart';
import 'package:bel/src/remote/mdns/host_discovery.dart';
import 'package:bel/src/remote/mdns/mdns_service.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The packet `MdnsResponder` puts on the wire: the PTR as the answer, and the
/// SRV, TXT and A records that make it useful as additionals.
Uint8List announcement({
  String instance = 'studio-mac',
  String hostName = 'studio-mac.local',
  int port = 45678,
  List<List<int>> addresses = const [
    [192, 168, 1, 20],
  ],
  Map<String, String> txt = const {
    'v': '1',
    'name': 'Studio Mac',
    'sr': '48000',
    'ch': '2',
  },
  int ttl = 120,
}) {
  final serviceInstance = '$instance.$belServiceType';
  return encodeResponse(
    answers: [
      DnsRecord(
        name: belServiceType,
        type: DnsType.ptr,
        ttl: ttl,
        target: serviceInstance,
      ),
    ],
    additionals: [
      if (ttl != 0) ...[
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
        for (final address in addresses)
          DnsRecord(
            name: hostName,
            type: DnsType.a,
            ttl: ttl,
            cacheFlush: true,
            address: address,
          ),
      ],
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the browser every platform but iOS uses', () {
    test('an announcement becomes a host somebody can tap', () {
      final browser = MdnsBrowser()..handleDatagram(announcement());

      expect(browser.hosts.value, hasLength(1));
      final host = browser.hosts.value.single;
      expect(host.instanceName, 'studio-mac');
      expect(host.address, '192.168.1.20');
      expect(host.port, 45678);
      expect(host.displayName, 'Studio Mac');
      expect(host.format, '2 ch · 48 kHz');
    });

    test('a service with no address yet is not a row', () {
      final browser = MdnsBrowser()
        ..handleDatagram(announcement(addresses: const []));

      // A row that cannot be tapped is worse than no row: it sends somebody to
      // check the machine that is working.
      expect(browser.hosts.value, isEmpty);
    });

    test('a laptop in an empty dock is offered at the address that works', () {
      // 169.254 is what an interface gives itself when nothing configured it.
      // It is a real address on a real interface and nothing can reach it, so
      // it loses however the two arrive — which is the bug: keeping whichever
      // came last put half the docked laptops in the building on the wrong one.
      for (final addresses in [
        [
          [192, 168, 1, 20],
          [169, 254, 154, 238],
        ],
        [
          [169, 254, 154, 238],
          [192, 168, 1, 20],
        ],
      ]) {
        final browser = MdnsBrowser()
          ..handleDatagram(announcement(addresses: addresses));
        expect(browser.hosts.value.single.address, '192.168.1.20');
      }
    });

    test('a host that moves is followed, not accumulated', () {
      final browser = MdnsBrowser()
        ..handleDatagram(
          announcement(
            addresses: const [
              [192, 168, 1, 20],
            ],
          ),
        )
        ..handleDatagram(
          announcement(
            addresses: const [
              [192, 168, 1, 44],
            ],
          ),
        );

      // Every A record carries the cache-flush bit, which says "this is the
      // whole truth about this name".
      expect(browser.hosts.value.single.address, '192.168.1.44');
    });

    test('a goodbye takes the row with it', () {
      final browser = MdnsBrowser()..handleDatagram(announcement());
      expect(browser.hosts.value, hasLength(1));

      browser.handleDatagram(announcement(ttl: 0));
      expect(browser.hosts.value, isEmpty);
    });

    test('nothing about another device on port 5353 is a Bel host', () {
      final browser = MdnsBrowser()
        ..handleDatagram(
          encodeResponse(
            answers: [
              DnsRecord(
                name: '_airplay._tcp.local',
                type: DnsType.ptr,
                ttl: 120,
                target: 'Living Room._airplay._tcp.local',
              ),
            ],
          ),
        )
        ..handleDatagram(Uint8List.fromList(const [1, 2, 3]));

      expect(browser.hosts.value, isEmpty);
    });

    test('tearing the browser down is not a publish', () {
      final browser = MdnsBrowser()..handleDatagram(announcement());

      // `dispose` gives back the socket and the timers without going through
      // the publishing half of `stop`. A write to a disposed `ValueNotifier`
      // throws, and these are one statement from being disposed.
      expect(browser.dispose, returnsNormally);
    });
  });

  group('the browser iOS makes Bel use', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(bonjourChannel, null);
    });

    void answerWith(MockStreamHandler handler) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(bonjourChannel, handler);

    test('what the system responder found becomes the same rows', () async {
      answerWith(
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            sink.success(<dynamic>[
              <dynamic, dynamic>{
                'name': 'studio-mac',
                // The SRV target rather than an address: on this path the
                // system resolver picks the interface.
                'host': 'studio-mac.local',
                'port': 45678,
                'txt': <dynamic, dynamic>{
                  'v': '1',
                  'name': 'Studio Mac',
                  'sr': '96000',
                  'ch': '2',
                },
              },
              // Browsed but not resolved yet: no host and no port, so no row.
              <dynamic, dynamic>{'name': 'live-rig'},
            ]);
          },
        ),
      );

      final discovery = BonjourDiscovery();
      await discovery.start();
      await pumpEventQueue();

      expect(discovery.isBrowsing.value, isTrue);
      expect(discovery.failure.value, isNull);
      expect(discovery.hosts.value, hasLength(1));
      expect(discovery.hosts.value.single.displayName, 'Studio Mac');
      expect(discovery.hosts.value.single.address, 'studio-mac.local');
      expect(discovery.hosts.value.single.format, '2 ch · 96 kHz');

      await discovery.stop();
    });

    test('a refused permission is a sentence, not an empty list', () async {
      answerWith(
        MockStreamHandler.inline(
          onListen: (arguments, sink) => sink.error(
            code: 'browse-failed',
            message: 'iPadOS is not letting Bel search the local network.',
          ),
        ),
      );

      final discovery = BonjourDiscovery();
      await discovery.start();
      await pumpEventQueue();

      expect(discovery.isBrowsing.value, isFalse);
      expect(discovery.failure.value, contains('iPadOS'));

      await discovery.stop();
    });

    test('a search torn down mid-browse ends quietly', () async {
      answerWith(MockStreamHandler.inline(onListen: (arguments, sink) {}));

      final discovery = BonjourDiscovery();
      await discovery.start();

      // What a hot restart does. Cancelling a channel subscription suspends,
      // so `stop` used to resume after `dispose` had already disposed the
      // notifiers and then write to one — an uncaught asynchronous error the
      // test zone reports, and a red exception in the running application.
      discovery.dispose();
      await pumpEventQueue();
    });
  });

  group('what the panel says when it cannot search', () {
    testWidgets('the reason, when there is one', (tester) async {
      final discovery = _StaticDiscovery()
        ..failure.value =
            'macOS is not letting Bel search the local network. Allow it '
            'under System Settings › Privacy & Security › Local Network, '
            'or enter an address below.';

      await tester.pumpWidget(_panel(discovery));

      expect(find.textContaining('System Settings'), findsOneWidget);
      expect(find.textContaining('Looking for hosts'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('and the general version when there is not', (tester) async {
      // Android: the socket opens, the join succeeds, and nothing is ever
      // delivered because Dart cannot take a `WifiManager.MulticastLock`.
      // There is no error to report — only the fact.
      await tester.pumpWidget(_panel(_StaticDiscovery()));

      expect(find.textContaining('cannot search the network'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a search that is running says so instead', (tester) async {
      await tester.pumpWidget(
        _panel(_StaticDiscovery()..isBrowsing.value = true),
      );

      expect(find.textContaining('Looking for hosts'), findsOneWidget);
      expect(find.textContaining('cannot search the network'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

Widget _panel(HostDiscovery discovery) => BelTheme(
  colors: BelColors.precisionInstrument,
  child: MaterialApp(
    home: HostPickerPanel(onConnect: (_, _) {}, discovery: discovery),
  ),
);

/// A search whose state the test sets, so that the panel can be looked at in
/// each of the three things it has to say without a socket in sight.
class _StaticDiscovery implements HostDiscovery {
  @override
  final ValueNotifier<List<DiscoveredHost>> hosts = ValueNotifier(const []);

  @override
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  @override
  final ValueNotifier<String?> failure = ValueNotifier(null);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}
