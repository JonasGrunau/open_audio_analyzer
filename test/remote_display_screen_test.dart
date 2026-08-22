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
    //
    // Pumped for rather than asserted outright: the readout appears with the
    // transport frame, and the hello that carries the name is a frame in front
    // of it. Whether the two land in one chunk is up to the kernel.
    await _pumpUntil(
      tester,
      () => find.byType(TransportReadout).evaluate().isNotEmpty,
    );
    expect(find.text('DISCONNECT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });

  testWidgets('a host with no playhead puts the tabs beside its name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The ordinary case, not an edge one: a desktop metering a sound card or a
    // file has no DAW behind it, so it never sends a transport frame at all.
    final host = DisplayHost(
      source: null,
      hostName: 'Studio Desktop',
      abiVersion: 0,
    );
    addTearDown(host.dispose);

    await tester.runAsync(() => host.start(port: 0));
    final port = host.port!;

    // Two tabs, because one draws no tab control — and the control is the thing
    // that was left stranded in the middle of the bar.
    host.publishLayout(
      const PresetSpec(
        name: 'Two',
        tabs: [
          TabSpec(name: 'Master', modules: []),
          TabSpec(name: 'Detail', modules: []),
        ],
      ),
    );

    await tester.pumpWidget(
      OaaTheme(
        colors: OaaColors.precisionInstrument,
        child: const MaterialApp(home: RemoteDisplayScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '127.0.0.1:$port');
    await tester.pump();
    await tester.tap(find.text('CONNECT'));

    await _pumpUntil(
      tester,
      () => find.byType(SegmentedControl<int>).evaluate().isNotEmpty,
    );

    // Nothing to draw, so nothing reserved. The readout is absent rather than
    // present and blank, which is the whole of the fix.
    expect(find.byType(TransportReadout), findsNothing);

    // And the consequence, measured: the tab control starts one gap after the
    // name ends. Asserted in pixels because it is a pixel problem — every
    // widget involved was present and correct while 248 px of nothing sat
    // between them, so nothing about it is visible in a finder.
    final name = tester.getRect(find.text('Studio Desktop'));
    final tabs = tester.getRect(find.byType(SegmentedControl<int>));
    expect(tabs.left - name.right, closeTo(Space.md, 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });
}
