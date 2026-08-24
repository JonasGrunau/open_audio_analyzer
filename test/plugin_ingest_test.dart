// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app accepts a plugin, and draws it.
//
// `test/plugin_link_test.dart` covers the link itself — binding, framing,
// decoding, staleness — and passed for a whole phase while the feature did not
// exist, because **nothing in the application ever constructed a
// `PluginLink`**. The port was never bound, no session was ever created, and a
// plugin inserted in a DAW retried against nothing forever while the README
// said the desktop app meters what the DAW is playing.
//
// That is the class of defect a unit test cannot see: every part worked and
// none of them was wired to another. So this test starts at the top — the real
// `OaaApp`, the real engine, a real socket — and asserts the two things a user
// would notice: the port is open, and connecting to it puts the plugin on
// screen in place of the local source.

import 'dart:io';
import 'dart:typed_data';

import 'package:oaa/src/app/oaa_app.dart';
import 'package:oaa/src/app/transport_readout.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bytes the plugin itself produced, written by `plugin/test/wire_fixture.cpp`.
/// A HELLO, a transport frame and a snapshot, in the order the plugin sends
/// them.
///
/// Read **synchronously**. A `testWidgets` body runs in a fake-async zone, and a
/// future completed by the disk is delivered by the real event loop that zone
/// never returns to — so an awaited read never completes and the test hangs
/// until the runner kills it ten minutes later, with no error and no stack.
Uint8List _goldenFrames() =>
    File('plugin/test/golden/wire_v2.bin').readAsBytesSync();

/// A port nothing is using, chosen by the operating system.
///
/// The app binds `kPluginLinkPort` in production and the test needs to know
/// which port to connect to, so it picks one first and hands it over. Asking for
/// a free port and releasing it leaves a window in which something else could
/// take it; on a test runner that window is theoretical, and the alternative —
/// binding the real 47822 — fails whenever the developer has the app open,
/// which is exactly when they are most likely to be running the suite.
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// Pumps until [condition] holds. Widget tests have their own clock, so a
/// socket's arrival needs pumping rather than only waiting.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was still false after $timeout.');
    }
    await tester.pump(const Duration(milliseconds: 20));
    // The socket is real, so its bytes are delivered by the real event loop
    // that a widget test's fake-async zone never returns to on its own.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  testWidgets('a connected plugin takes the canvas', (tester) async {
    // Wide enough that the status bar keeps every item: it drops whole entries
    // rather than squeezing them, and the source label is what is asserted on.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final frames = _goldenFrames();

    // Real socket work, so it has to happen where the real event loop can
    // deliver it. Same reason as the synchronous read above.
    final port = (await tester.runAsync(_freePort))!;

    final store = ConfigStore.disabled();
    addTearDown(store.dispose);

    final container = ProviderContainer(
      overrides: [
        configStoreProvider.overrideWithValue(store),
        startupConfigProvider.overrideWithValue(
          StartupConfig(notice: store.lastError),
        ),
        pluginLinkPortProvider.overrideWithValue(port),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const OaaApp()),
    );
    await tester.pump();

    // The local engine, before anything connects.
    expect(find.text('TEST TONE'), findsOneWidget);

    // And no playhead, because a sound card does not have one. The readout is
    // absent rather than blank: it is 132 px of a bar that drops whole items
    // rather than squeezing them.
    expect(find.byType(TransportReadout), findsNothing);

    // The app is listening. This is the assertion the feature never passed:
    // before the link was wired, nothing was bound here and `connect` threw.
    final socket = (await tester.runAsync(
      () => Socket.connect(InternetAddress.loopbackIPv4, port),
    ))!;
    addTearDown(socket.destroy);

    await tester.runAsync(() async {
      socket.add(frames);
      await socket.flush();
    });

    // Inserting a plugin is the act of choosing it, so the canvas follows
    // without anybody opening a menu.
    await _pumpUntil(
      tester,
      () => find
          .text('OPEN AUDIO ANALYZER PLUGIN — FIXTURE')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.text('TEST TONE'), findsNothing);

    // And it is the plugin's measurements on screen, not the engine's: the
    // fixture says 48 kHz stereo, and the status bar reads its format from
    // whatever is being metered.
    expect(find.text('48.0 kHz · 2 ch'), findsOneWidget);

    // The DAW's playhead arrives in its own frame, ahead of the snapshot, and
    // the bar gains a readout for it. The fixture is rolling at 120 bpm in 7/8
    // with drop-frame timecode; what the readout makes of those is held in
    // `test/transport_readout_test.dart` against the same values, and what is
    // asserted here is the wiring — that a connected plugin puts a position in
    // the bar at all, which is the half of this that no unit test can see.
    expect(find.byType(TransportReadout), findsOneWidget);

    // And the overrun notice counts the *plugin's* lost frames. The fixture
    // reports seven and raises the flag; the sentence used to read the
    // desktop's own engine, which is idle while a plugin is on the canvas — so
    // a real loss of audio was reported as zero frames, which is a warning
    // that contradicts itself and a number somebody would quote.
    //
    // The wording changed when a source that stopped became a second way to
    // lose audio — the frames are no longer "discarded because analysis could
    // not keep up", because half of them were never produced at all — and what
    // is pinned here is the count, not the prose around it.
    expect(
      find.textContaining('7 frames never reached the measurement'),
      findsOneWidget,
      reason: 'the notice is counting something other than what is metered',
    );
  });
}
