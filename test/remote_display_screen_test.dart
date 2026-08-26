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
import 'package:oaa/src/remote/this_machine.dart';
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
        child: MaterialApp(
          // Nowhere, so that the address typed below — a host this test
          // started in its own process, on loopback — is not refused as this
          // machine, which is exactly what the picker does to anybody who is
          // not a test. See `ThisMachine`.
          home: RemoteDisplayScreen(thisMachine: ThisMachine.nowhere()),
        ),
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

    // Two tabs, so the bar holds both of the things whose order is the point of
    // the assertions at the bottom.
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
        child: MaterialApp(
          // Nowhere, so that the address typed below — a host this test
          // started in its own process, on loopback — is not refused as this
          // machine, which is exactly what the picker does to anybody who is
          // not a test. See `ThisMachine`.
          home: RemoteDisplayScreen(thisMachine: ThisMachine.nowhere()),
        ),
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

    // **The pages are at the trailing end of the bar, one gap in front of the
    // way out, and the readout leads them rather than following them.** The
    // page control is the one thing on this bar somebody touches repeatedly, so
    // what fixes its position is the edge it is packed against and nothing
    // else: a host that gains or loses a DAW, or reports two counters where
    // another reports three, must not move it. In front of the pages the
    // readout did exactly that — it is a 232 px reservation and this host's
    // counters come to 182 of them, so the control stood 66 px clear of the ink
    // with nothing between the two. A host counting bars leaves 88 px, and one
    // reporting a clock and no tempo 190. Every unspent pixel of it now falls
    // into the row's slack, which sits between the readout and the pages and is
    // the one place in the bar where a gap means nothing.
    //
    // Measured rather than read off the tree, because a finder cannot see this:
    // every widget in that bar was present and correct throughout, and the hole
    // was the width one of them had reserved and not used. See the tail of
    // `transport_readout_test.dart` for the same argument about the ink inside
    // the box.
    final name = tester.getRect(find.text('Studio Desktop'));
    final tabs = tester.getRect(find.byType(SegmentedControl<int>));
    final readout = tester.getRect(find.byType(TransportReadout));
    final out = tester.getRect(find.byType(OaaButton));

    expect(readout.left - name.right, closeTo(Space.md, 0.5));
    expect(out.left - tabs.right, closeTo(Space.md, 0.5));
    expect(tabs.left, greaterThan(readout.right));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });

  testWidgets('a host with no playhead leaves the pages where they are', (
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

    // Two tabs, because one draws no page control at all — and the control is
    // the thing that was left stranded in the middle of the bar.
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
        child: MaterialApp(
          // Nowhere, so that the address typed below — a host this test
          // started in its own process, on loopback — is not refused as this
          // machine, which is exactly what the picker does to anybody who is
          // not a test. See `ThisMachine`.
          home: RemoteDisplayScreen(thisMachine: ThisMachine.nowhere()),
        ),
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

    // And the consequence, measured: the page control ends one gap in front of
    // the way out, exactly where it ends on the host that does have a playhead.
    // That is the whole point of putting it here — the presence of a DAW at the
    // other end cannot move it, because everything that comes and goes with one
    // is upstream of the row's slack. Asserted in pixels because it is a pixel
    // problem: every widget involved was present and correct while 248 px of
    // nothing sat in the bar, so nothing about it is visible in a finder.
    final tabs = tester.getRect(find.byType(SegmentedControl<int>));
    final out = tester.getRect(find.byType(OaaButton));
    expect(out.left - tabs.right, closeTo(Space.md, 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });

  testWidgets('disconnecting lands back on the view that opened the display', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final host = DisplayHost(
      source: null,
      hostName: 'Studio Desktop',
      abiVersion: 0,
    );
    addTearDown(host.dispose);

    await tester.runAsync(() => host.start(port: 0));
    final port = host.port!;

    host.publishLayout(
      const PresetSpec(
        name: 'One',
        tabs: [TabSpec(name: 'Master', modules: [])],
      ),
    );

    // Pushed, which is the only shape the application ever has: both ways into
    // a display put it on the stack over the screen the person was looking at.
    await tester.pumpWidget(
      OaaTheme(
        colors: OaaColors.precisionInstrument,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RemoteDisplayScreen(host: '127.0.0.1', port: port),
                    ),
                  ),
                  child: const Text('THE VIEW BEHIND'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('THE VIEW BEHIND'));
    await _pumpUntil(
      tester,
      () => find.text('Studio Desktop').evaluate().isNotEmpty,
    );

    // The route is still sliding in when the first frame lands, and a control
    // half off the right edge cannot be tapped.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('DISCONNECT'));
    await tester.pumpAndSettle();

    // The way out goes back, and it does not hand over a question on the way.
    // Disconnect used to drop the screen to `idle`, whose build is the host
    // picker — so leaving a display put a panel asking which machine to attach
    // to next on top of the meters, with the display still behind it.
    expect(find.text('THE VIEW BEHIND'), findsOneWidget);
    expect(find.text('SHOW ANOTHER MACHINE'), findsNothing);
    expect(find.text('DISCONNECT'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.stop);
  });
}
