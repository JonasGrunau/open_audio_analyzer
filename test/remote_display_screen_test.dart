// SPDX-License-Identifier: GPL-3.0-or-later
//
// The display screen builds.
//
// Narrow on purpose: it proves the screen renders without a host, a socket or
// an engine — the state a tablet is in when somebody opens it — and that the
// typed-address route is present, which is the one that has to work when
// discovery does not.

import 'package:oaa/src/app/transport_readout.dart';
import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa/src/remote/display_screen.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps until [condition] holds, letting a real socket's bytes arrive.
///
/// A widget test has its own clock and a fake-async zone the real event loop
/// never returns to, so a socket needs both: a pump to advance the widget
/// tree's time and a `runAsync` for the delivery itself.
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  testWidgets('opens on the host picker with somewhere to type an address', (
    tester,
  ) async {
    await tester.pumpWidget(
      OaaTheme(
        colors: OaaColors.precisionInstrument,
        child: const MaterialApp(home: RemoteDisplayScreen()),
      ),
    );

    // The same panel the desktop opens to choose a host, on a screen with
    // nothing behind it — one implementation, so the two ways into a display
    // cannot drift apart.
    expect(find.text('SHOW ANOTHER MACHINE'), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // Unmount so the browser's socket and timers are torn down inside the test.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows the host it is attached to, and its playhead', (
    tester,
  ) async {
    // Wide enough for the link bar to keep everything: the name, the readout
    // and the way out.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A host with nothing to measure still handshakes and still has a playhead
    // to relay — which is the point: transport travels in its own frame and
    // does not wait for a measurement. Real sockets, so this is the tablet's
    // own code path rather than a stand-in for it.
    final host = DisplayHost(
      source: null,
      hostName: 'Studio Desktop',
      abiVersion: 0,
    );
    addTearDown(host.dispose);

    await tester.runAsync(() => host.start(port: 0));
    final port = host.port!;

    host.transport = const Transport(
      flags:
          Transport.flagPlaying |
          Transport.flagHasBpm |
          Transport.flagHasTimeSig |
          Transport.flagHasTimeSeconds,
      timeSeconds: 61.5,
      bpm: 128,
      timeSigNumerator: 7,
      timeSigDenominator: 8,
    );

    await tester.pumpWidget(
      OaaTheme(
        colors: OaaColors.precisionInstrument,
        child: const MaterialApp(home: RemoteDisplayScreen()),
      ),
    );

    await tester.pump();

    // The way in that has to work when discovery does not: type the address.
    await tester.enterText(find.byType(TextField), '127.0.0.1:$port');
    await tester.pump();
    await tester.tap(find.text('CONNECT'));

    await _pumpUntil(
      tester,
      () => find.text('Studio Desktop').evaluate().isNotEmpty,
    );

    // The link bar carries the desktop's playhead. Nothing here is the
    // desktop's own widget reused by accident — `TransportReadout` is the one
    // readout both screens build, so a tablet cannot end up with a second
    // opinion about what a missing tempo looks like.
    expect(find.byType(TransportReadout), findsOneWidget);
    expect(find.text('DISCONNECT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });
}
