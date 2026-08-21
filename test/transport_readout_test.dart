// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the transport readout says.
//
// The readout is painted, so nothing here can look for a `Text` — and pixels
// are not what goes wrong with a readout anyway. What goes wrong is the
// *claim*: a bar number under a host that never sent a time signature, `0.0
// BPM` under one that never sent a tempo, `00:00:00:00` under one parked at bar
// 57. Every one of those is a plausible-looking readout of a measurement nobody
// took, which is the thing this project forbids outright, and every one of them
// would pass a test that only asked whether something was drawn.
//
// So the two formatters are public and tested directly. The pixels are checked
// by looking at the application — see the note in `CLAUDE.md` about running it
// before calling a module finished.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/app/transport_readout.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

void main() {
  group('the position', () {
    test('is the timecode when the host counts frames', () {
      // The fixture's own transport: 29.97 drop-frame, a minute and a bit in,
      // on a timeline whose session starts at 01:00:00:00. Held against the
      // same string `packages/oaa_wire/test/plugin_golden_test.dart` asserts,
      // so the readout and the codec cannot drift apart about what the plugin
      // said.
      const transport = Transport(
        flags: Transport.flagHasTimecode | Transport.flagHasTimeSeconds,
        frameRate: TimecodeFrameRate.fps2997drop,
        timeSeconds: 61.5,
        editOriginSeconds: 3600,
      );

      expect(transportPosition(transport), '01:01:01;15');
    });

    test('falls back to bars and beats when it does not', () {
      // 7/8 at eight and a quarter quarter-notes, with the bar starting at
      // seven: bar 3, and a beat measured in eighths rather than quarters —
      // the distinction `Transport.barAndBeat` exists for.
      const transport = Transport(
        flags:
            Transport.flagHasPpq |
            Transport.flagHasBarStart |
            Transport.flagHasTimeSig,
        ppqPosition: 8.25,
        ppqBarStart: 7,
        timeSigNumerator: 7,
        timeSigDenominator: 8,
      );

      expect(transportPosition(transport), '3|3.5');
    });

    test('falls back to the clock when it counts neither', () {
      const transport = Transport(
        flags: Transport.flagHasTimeSeconds,
        timeSeconds: 3661.9,
      );

      // Truncated, like the timecode: a clock that rounded would name the next
      // second for the back half of every one of them.
      expect(transportPosition(transport), '01:01:01');
    });

    test('says nothing about a position it was not given', () {
      // A host that is rolling and will not say where. Every field but the
      // playing bit is absent, and the readout has to be dashes rather than
      // `00:00:00` — which is a real position, and one the transport never
      // claimed to be at.
      const transport = Transport(flags: Transport.flagPlaying);

      expect(transportPosition(transport), '--:--:--');
    });

    test('does not invent a bar from a partial answer', () {
      // PPQ and a bar start, and no time signature — so there is no bar length
      // to divide by. 4/4 is the most plausible-looking guess available and
      // therefore the most dangerous one.
      const transport = Transport(
        flags:
            Transport.flagHasPpq |
            Transport.flagHasBarStart |
            Transport.flagHasTimeSeconds,
        ppqPosition: 8.25,
        ppqBarStart: 7,
        timeSeconds: 4,
      );

      expect(transportPosition(transport), '00:00:04');
    });
  });

  group('the tempo', () {
    test('is a tempo and a meter when the host sent both', () {
      const transport = Transport(
        flags: Transport.flagHasBpm | Transport.flagHasTimeSig,
        bpm: 128,
        timeSigNumerator: 7,
        timeSigDenominator: 8,
      );

      expect(transportTempo(transport), '128.0 BPM · 7/8');
    });

    test('is half of it when the host sent half', () {
      const transport = Transport(flags: Transport.flagHasBpm, bpm: 93.5);
      expect(transportTempo(transport), '93.5 BPM');

      const meterOnly = Transport(
        flags: Transport.flagHasTimeSig,
        timeSigNumerator: 3,
        timeSigDenominator: 4,
      );
      expect(transportTempo(meterOnly), '3/4');
    });

    test('is nothing when the host sent neither', () {
      // Not `0.0 BPM · 0/0`. A tempo of zero is not a degraded reading, it is a
      // made-up one, and every DAW in existence would make it look right.
      const transport = Transport(
        flags: Transport.flagPlaying | Transport.flagHasTimeSeconds,
        timeSeconds: 12,
      );

      expect(transportTempo(transport), isNull);
      expect(transportTempo(Transport.none), isNull);
    });
  });

  testWidgets('the readout paints without a ticker of its own', (tester) async {
    // The widget takes any `Listenable` as its repaint, which is what lets the
    // desktop hand it the one `MeterClock` and a tablet hand it the same. Here
    // it is a notifier, so this stays a test of the readout rather than of the
    // clock — and it is pumped with a transport that changes, because a painter
    // that reads its value in `paint` is the whole design.
    final repaint = ValueNotifier<int>(0);
    addTearDown(repaint.dispose);

    var transport = const Transport(
      flags: Transport.flagPlaying | Transport.flagHasTimeSeconds,
      timeSeconds: 1,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OaaTheme(
          colors: OaaColors.precisionInstrument,
          child: TransportReadout(
            transportOf: () => transport,
            repaint: repaint,
            width: TransportReadout.fullWidth,
          ),
        ),
      ),
    );

    expect(find.byType(TransportReadout), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A position that moved, and then one that is not there at all — the state
    // the readout draws nothing in. Neither may throw: this paints on every
    // frame of a session for as long as one is open.
    transport = const Transport(
      flags: Transport.flagPlaying | Transport.flagHasTimeSeconds,
      timeSeconds: 2,
    );
    repaint.value = 1;
    await tester.pump();
    expect(tester.takeException(), isNull);

    transport = Transport.none;
    repaint.value = 2;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
