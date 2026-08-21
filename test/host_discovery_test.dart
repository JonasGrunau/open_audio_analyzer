// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finding a host, on both of the two paths there are.
//
// `mdns_test.dart` covers the DNS codec — that a packet Open Audio Analyzer
// writes is a packet Open Audio Analyzer reads. This covers what happens after
// that: the browser's state machine, the channel iOS has to use instead of it,
// and the sentence the panel shows when neither of them can work. All three
// were untested, and the third did not exist: a search that could not run
// showed "Looking for hosts on this network…" for as long as anybody was
// willing to wait.

import 'package:oaa/src/remote/host_picker.dart';
import 'package:oaa/src/remote/mdns/bonjour_discovery.dart';
import 'package:oaa/src/remote/mdns/dns_message.dart';
import 'package:oaa/src/remote/mdns/host_discovery.dart';
import 'package:oaa/src/remote/mdns/mdns_service.dart';
import 'package:oaa/src/remote/mdns/multicast_lock.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final serviceInstance = '$instance.$oaaServiceType';
  return encodeResponse(
    answers: [
      DnsRecord(
        name: oaaServiceType,
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

    test(
      'nothing about another device on port 5353 is an Open Audio Analyzer host',
      () {
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
      },
    );

    test('tearing the browser down is not a publish', () {
      final browser = MdnsBrowser()..handleDatagram(announcement());

      // `dispose` gives back the socket and the timers without going through
      // the publishing half of `stop`. A write to a disposed `ValueNotifier`
      // throws, and these are one statement from being disposed.
      expect(browser.dispose, returnsNormally);
    });

    test('a browser torn down while it is still binding ends quietly', () async {
      final browser = MdnsBrowser();

      // Binding is real I/O, so `start` is suspended for as long as the
      // machine takes — and on macOS the first bind of a session waits on the
      // Local Network permission the system is asking somebody about. A picker
      // closed inside that window disposes the notifiers the rest of `start`
      // was about to write to, and abandons a bound multicast socket that
      // nothing holds a reference to any more.
      final starting = browser.start();
      browser.dispose();

      await expectLater(starting, completes);
    });
  });

  group('what the responder puts on the wire', () {
    // Everything in this group is about one rule: **a DNS-SD instance name is
    // one label.** Open Audio Analyzer writes a name by splitting it on dots,
    // so a dot in the instance does not name an instance containing a dot — it
    // invents labels, and the record stops being `<instance>._oaa._tcp.local`
    // at all.
    //
    // Nothing caught it because Open Audio Analyzer's own reader takes
    // everything before `_oaa._tcp.local` as the instance, so an Open Audio
    // Analyzer desktop found an Open Audio Analyzer desktop perfectly. Apple's
    // responder drops the record, so `dns-sd -B` and every iPad saw nothing, on
    // any network whose DHCP hands out a domain — `Platform.localHostname` is
    // `studio-mac.fritz.box` on one of those.

    test('a machine name with a domain in it is still one label', () {
      final responder = MdnsResponder(
        instanceName: 'studio-mac.fritz.box',
        port: 47821,
      );

      expect(responder.instanceLabel, 'studio-mac-fritz-box');
      expect(responder.serviceInstance, 'studio-mac-fritz-box.$oaaServiceType');
      // `<instance>._oaa._tcp.local` is four labels. The bug made it six, and
      // six labels are not a service instance whatever they read as.
      expect(responder.serviceInstance.split('.'), hasLength(4));
    });

    test('a name somebody typed with a dot in it is too', () {
      // The friendly form is not lost; it rides in the TXT record, which is
      // free-form and is what the picker shows.
      final responder = MdnsResponder(instanceName: 'Mix Room 2.0', port: 1)
        ..txt = const {'name': 'Mix Room 2.0'};

      expect(responder.instanceLabel, 'Mix Room 2-0');
      expect(responder.txt['name'], 'Mix Room 2.0');
    });

    test('the advertised host name is never the machine own .local', () {
      // The system responder owns `studio-mac.local` and defends it: an A
      // record it did not announce, for a name it owns, is a conflict, and the
      // loser renames itself. The loser would be the user's Mac.
      final responder = MdnsResponder(instanceName: 'studio-mac', port: 1);

      expect(responder.hostName, isNot('studio-mac.local'));
      expect(responder.hostName, 'studio-mac-oaa.local');
    });

    test('a plain machine name is left alone', () {
      final responder = MdnsResponder(instanceName: 'studio-mac', port: 1);
      expect(responder.instanceLabel, 'studio-mac');
    });
  });

  group('the browser iOS makes Open Audio Analyzer use', () {
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
            message:
                'iPadOS is not letting Open Audio Analyzer search the local network.',
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

    test('two searches that overlap are one browse', () async {
      var listens = 0;
      var cancels = 0;
      answerWith(
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            listens++;
            sink.success(<dynamic>[
              <dynamic, dynamic>{
                'name': 'studio-mac',
                'host': 'studio-mac.local',
                'port': 45678,
                'txt': <dynamic, dynamic>{'name': 'Studio Mac'},
              },
            ]);
          },
          onCancel: (arguments) => cancels++,
        ),
      );

      // What replacing one host picker with another does: the arriving route's
      // `initState` runs before the leaving route's `dispose`, so for a frame
      // there are two of these.
      final leaving = BonjourDiscovery();
      await leaving.start();
      await pumpEventQueue();

      final arriving = BonjourDiscovery();
      await arriving.start();
      leaving.dispose();
      await pumpEventQueue();

      // A channel holds one sink. A second `listen` would have cancelled the
      // browse underneath the panel still on screen, and the `cancel` that
      // followed it would have been answered with "No active stream to cancel"
      // — reported from inside the framework, where Open Audio Analyzer cannot
      // catch it.
      expect(listens, 1);
      expect(cancels, isZero);

      // And the search that arrived mid-browse has the list rather than an
      // empty panel waiting for the network to change.
      expect(arriving.hosts.value.single.displayName, 'Studio Mac');

      await arriving.stop();
      expect(cancels, 1);
    });
  });

  // The socket above is only half of what Android needs. The other half is a
  // `WifiManager.MulticastLock`: without one the driver discards every answer
  // below the socket, so the browse binds, joins, queries and hears nothing,
  // with no error anywhere. These hold the two things that cannot be seen on a
  // device — that the lock is asked for at all, and that it is given back.
  group('the lock Android needs before any of that arrives', () {
    late bool wasNeeded;
    var acquires = 0;
    var releases = 0;
    String? refuseWith;

    setUp(() {
      wasNeeded = MulticastLock.platformNeedsLock;
      MulticastLock.platformNeedsLock = true;
      MulticastLock.reset();
      acquires = 0;
      releases = 0;
      refuseWith = null;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(multicastLockChannel, (call) async {
            switch (call.method) {
              case 'acquire':
                acquires++;
                final refusal = refuseWith;
                if (refusal != null) {
                  throw PlatformException(
                    code: 'multicast-lock-unavailable',
                    message: refusal,
                  );
                }
              case 'release':
                releases++;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(multicastLockChannel, null);
      MulticastLock.reset();
      MulticastLock.platformNeedsLock = wasNeeded;
    });

    test('a browse takes it, and stopping gives it back', () async {
      final browser = MdnsBrowser();
      await browser.start();

      // Before the socket, not after: the answers to the query the browse sends
      // on its way up are the ones a display is waiting for.
      expect(acquires, 1);
      expect(releases, isZero);

      await browser.stop();
      await pumpEventQueue();
      expect(releases, 1);
    });

    test('two searches that overlap hold one lock between them', () async {
      // What replacing one host picker with another does — the arriving route's
      // `initState` runs before the leaving route's `dispose` — and what a
      // desktop that is advertising while it browses does all the time. A
      // release counted per caller would take multicast away from whichever of
      // them is still looking.
      final leaving = MdnsBrowser();
      final arriving = MdnsBrowser();
      await leaving.start();
      await arriving.start();
      expect(acquires, 1);

      await leaving.stop();
      await pumpEventQueue();
      expect(releases, isZero, reason: 'somebody is still searching');

      await arriving.stop();
      await pumpEventQueue();
      expect(releases, 1);
    });

    test('a lock that cannot be taken is a sentence, not silence', () async {
      refuseWith =
          'Android is not letting Open Audio Analyzer receive '
          'multicast (SecurityException). Enter an address below.';

      // Reported rather than obeyed: a device with no Wi-Fi has nothing
      // filtering multicast, so the search is still worth running — and the
      // panel is where the reason belongs, next to the field for typing an
      // address.
      expect(await MulticastLock.acquire(), contains('SecurityException'));
      expect(MulticastLock.holders, 1);

      // A second searcher is told the same thing without a second trip.
      expect(await MulticastLock.acquire(), contains('SecurityException'));
      expect(acquires, 1);

      MulticastLock.release();
      MulticastLock.release();
      await pumpEventQueue();
      expect(releases, 1);
    });

    test('and nothing crosses the channel on a platform without one', () async {
      MulticastLock.platformNeedsLock = false;

      expect(await MulticastLock.acquire(), isNull);
      MulticastLock.release();
      await pumpEventQueue();

      expect(acquires, isZero);
      expect(releases, isZero);
    });
  });

  group('what the panel says when it cannot search', () {
    testWidgets('the reason, when there is one', (tester) async {
      final discovery = _StaticDiscovery()
        ..failure.value =
            'macOS is not letting Open Audio Analyzer search the local network. Allow it '
            'under System Settings › Privacy & Security › Local Network, '
            'or enter an address below.';

      await tester.pumpWidget(_panel(discovery));

      expect(find.textContaining('System Settings'), findsOneWidget);
      expect(find.textContaining('Looking for hosts'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('and the general version when there is not', (tester) async {
      // A machine with no multicast-capable interface: a VM on host-only
      // networking, a locked-down corporate image. Nothing named an errno, so
      // there is no better sentence than the fact.
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

    testWidgets('a search that is running and deaf does not', (tester) async {
      // Android with the multicast lock refused: the socket is bound, the query
      // is going out every five seconds, and not one answer will be delivered.
      // "Looking for hosts on this network…" is true and useless — it is the
      // face a search that is about to succeed wears.
      await tester.pumpWidget(
        _panel(
          _StaticDiscovery()
            ..isBrowsing.value = true
            ..failure.value =
                'Android is not delivering multicast to Open Audio Analyzer, '
                'so hosts cannot be found automatically. Enter an address '
                'below.',
        ),
      );

      expect(find.textContaining('not delivering multicast'), findsOneWidget);
      expect(find.textContaining('Looking for hosts'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

Widget _panel(HostDiscovery discovery) => OaaTheme(
  colors: OaaColors.precisionInstrument,
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
