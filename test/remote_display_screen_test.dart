// SPDX-License-Identifier: GPL-3.0-or-later
//
// The display screen builds.
//
// Narrow on purpose: it proves the screen renders without a host, a socket or
// an engine — the state a tablet is in when somebody opens it — and that the
// typed-address route is present, which is the one that has to work when
// discovery does not.

import 'package:bel/src/remote/display_screen.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens on the connect panel with somewhere to type an address', (
    tester,
  ) async {
    await tester.pumpWidget(
      BelTheme(
        colors: BelColors.precisionInstrument,
        child: const MaterialApp(home: RemoteDisplayScreen()),
      ),
    );

    expect(find.text('Remote display'), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // Unmount so the browser's socket and timers are torn down inside the test.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
