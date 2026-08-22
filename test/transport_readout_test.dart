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
//
// **With one exception, at the bottom: where in its box the readout puts the
// ink.** The box is a reservation the width of a timecode, and a host that
// counts bars instead spends 36 px of it. Drawn from the left, that left the
// desktop's `1|1.0` marooned in the middle of the title bar with 56 px of
// nothing to its right — a placement defect, invisible to every assertion
// above, and one no formatter test can reach because the string was correct
// throughout. It is checked by rendering and reading the pixels back, which is
// the route `CLAUDE.md` names for exactly this: a layout that is merely wrong
// to look at.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

  group('the ink is packed against one edge of the box', () {
    // The real fonts, because "how much of the box is unspent" is a question
    // about Google Sans Code and not about the test binding's placeholder,
    // whose square em box is wide enough to fill the reserve on its own and
    // would make every case below pass. Read with `readAsBytesSync`: an awaited
    // real read inside a `testWidgets` body never completes.
    setUpAll(() async {
      final loader = FontLoader('Google Sans Code');
      for (final path in const [
        'assets/fonts/GoogleSansCode-Regular.ttf',
        'assets/fonts/GoogleSansCode-Medium.ttf',
      ]) {
        loader.addFont(
          Future<ByteData>.value(
            ByteData.sublistView(File(path).readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    });

    // A host that counts bars and reports a tempo, parked at the top of the
    // session: `1|1.0`, and a tempo too wide for the desktop's box to hold. The
    // shortest position this readout can print, and the case that showed the
    // hole.
    const barBeat = Transport(
      flags:
          Transport.flagHasPpq |
          Transport.flagHasBarStart |
          Transport.flagHasTimeSig |
          Transport.flagHasBpm,
      timeSigNumerator: 4,
      timeSigDenominator: 4,
      bpm: 120,
    );

    testWidgets('trailing, in the desktop bar', (tester) async {
      final ink = await _inkBounds(
        tester,
        transport: barBeat,
        width: TransportReadout.defaultWidth,
        align: TransportAlign.trailing,
      );

      // Flush against the trailing edge, so the reserve it did not spend lands
      // on the far side and joins the row's own slack. Anything else puts a
      // gap between the playhead and the elapsed clock it is read beside.
      expect(TransportReadout.defaultWidth - ink.right, lessThan(2));
      expect(
        ink.left,
        greaterThan(2),
        reason:
            'The position filled the whole box, so this proves nothing about '
            'which edge it was drawn against.',
      );
    });

    testWidgets('leading, in the tablet link bar', (tester) async {
      final ink = await _inkBounds(
        tester,
        transport: barBeat,
        width: TransportReadout.fullWidth,
        align: TransportAlign.leading,
      );

      // The other way on the tablet, where the readout follows the host name
      // rather than leading a group packed right.
      expect(ink.left, lessThan(2));
      expect(TransportReadout.fullWidth - ink.right, greaterThan(2));
    });
  });
}

/// The leftmost and rightmost lit pixel of a rendered readout.
///
/// `toImage` inside `runAsync`, off a boundary above the widget: there is no
/// other way to ask where a `CustomPainter` put something, and a screenshot of
/// the running application needs a screen-recording permission an agent does
/// not have. See `CLAUDE.md`.
Future<({double left, double right})> _inkBounds(
  WidgetTester tester, {
  required Transport transport,
  required double width,
  required TransportAlign align,
}) async {
  final repaint = ValueNotifier<int>(0);
  addTearDown(repaint.dispose);
  final key = GlobalKey();

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            // Black rather than the skin's panel, so "lit" below is a threshold
            // on the glyph and not on the background it is drawn over.
            color: const Color(0xFF000000),
            child: OaaTheme(
              colors: OaaColors.precisionInstrument,
              child: TransportReadout(
                transportOf: () => transport,
                repaint: repaint,
                width: width,
                align: align,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final pixels = bytes.buffer.asUint8List();

  var left = double.infinity;
  var right = double.negativeInfinity;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final i = (y * image.width + x) * 4;
      // Any channel clear of the black ground. The muted text colour a parked
      // playhead is drawn in is well above this, and antialiasing at the edge
      // of a glyph is not.
      if (pixels[i] > 24 || pixels[i + 1] > 24 || pixels[i + 2] > 24) {
        if (x < left) left = x.toDouble();
        if (x + 1 > right) right = x + 1.0;
      }
    }
  }
  image.dispose();

  expect(
    right.isFinite,
    isTrue,
    reason: 'Nothing was drawn, so there is no placement to check.',
  );
  return (left: left, right: right);
}
