// SPDX-License-Identifier: GPL-3.0-or-later

/// Renders one of the application's modules, filling the window, so that a
/// headless browser can photograph it.
///
/// This exists because the website used to draw its own approximations of the
/// fourteen meters in JavaScript, and an approximation of a measurement display
/// is the one thing this project should not ship: the modules would drift apart
/// silently, and a picture of a meter that disagrees with the meter is worse
/// than no picture. So the website's thumbnails are photographs of the real
/// widgets instead, taken from `package:oaa` itself — there is nothing here to
/// keep in sync, because there is no second copy.
///
/// Driven entirely by the query string, one module per page load:
///
///     ?module=spectrum_analyzer&columns=8&rows=6
///
/// See `website/scripts/render-modules.mjs`, which builds this, serves it and
/// walks the list.
library;

import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_mock/oaa_mock.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// Set on `globalThis` once the programme has frozen and a frame has been
/// painted holding its final reading.
///
/// The renderer polls for it and photographs the page when it appears. Waiting
/// on the picture rather than on a stopwatch is what makes the images
/// reproducible: a slow machine takes longer to get here and produces the same
/// bytes, where a fixed delay would produce a half-finished spectrogram.
@JS('oaaRenderReady')
external set _renderReady(bool value);

void main() => runApp(const RendererApp());

/// The delivery target the stills are shot against.
///
/// Streaming rather than broadcast because the numbers the mock reports are a
/// little hot for it, which is the point: a validator that always passes and an
/// alert meter that is never red teach a reader nothing about what these
/// modules are for.
const _calibration = Calibration(
  id: 'streaming',
  name: 'Streaming',
  lufsTarget: -14.0,
  lufsTolerance: 0.5,
  truePeakMax: -1.0,
  loudnessRangeMax: 12.0,
);

class RendererApp extends StatefulWidget {
  const RendererApp({super.key});

  @override
  State<RendererApp> createState() => _RendererAppState();
}

class _RendererAppState extends State<RendererApp>
    with SingleTickerProviderStateMixin {
  late final MockSource _source = MockSource(
    // Long enough that the integrated reading has settled and there are enough
    // short-term blocks for a range; the modules with a time axis ask for more.
    captureAt:
        double.tryParse(Uri.base.queryParameters['seconds'] ?? '') ?? 14.0,
    // The spectrogram scrolls by one *device* pixel per published measurement,
    // so filling it is a matter of frames rather than of seconds — it asks for
    // a shorter step and gets many more of them for the same programme.
    dt: double.tryParse(Uri.base.queryParameters['dt'] ?? '') ?? 0.094,
    onFrozen: _announceReady,
  );
  late final MeterClock _clock = MeterClock(engine: _source, vsync: this);

  /// The frozen reading is set during the tick, *before* the frame that shows
  /// it has been painted. Two frames' grace, then the shutter may open.
  void _announceReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _renderReady = true);
    });
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  ModuleSpec _spec() {
    final q = Uri.base.queryParameters;
    final kind = ModuleKind.fromId(q['module'] ?? '') ?? ModuleKind.lufsMeter;

    // A module's appearance depends on how many cells it was given, not only on
    // how many pixels: several of them decide what to label and whether to draw
    // a scale from the cell count. So the renderer passes both, and the caller
    // keeps them in proportion.
    final columns = int.tryParse(q['columns'] ?? '') ?? kind.defaultColumns;
    final rows = int.tryParse(q['rows'] ?? '') ?? kind.defaultRows;

    return ModuleSpec(
      id: kind.id,
      kind: kind,
      rect: GridRect(column: 0, row: 0, columns: columns, rows: rows),
      // Anything else in the query string is passed through as a module option,
      // so a thumbnail can ask for a particular metric or channel mode without
      // this file growing a case for each one.
      options: {
        for (final entry in q.entries)
          if (!const {
            'module',
            'columns',
            'rows',
            'w',
            'h',
            'fw',
            'fh',
            'seconds',
            'dt',
          }.contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = oaaColorsFromSkin(BuiltInSkins.precisionInstrument);
    final q = Uri.base.queryParameters;

    // The frame every photograph comes out as, so the catalogue is a grid of
    // identically sized pictures.
    final frameW = double.tryParse(q['fw'] ?? '') ?? 360;
    final frameH = double.tryParse(q['fh'] ?? '') ?? 236;

    // The module inside it. Most fill the frame — a module is resizable on the
    // real canvas and these are the proportions most of them are happiest at.
    // The two bar meters are not: stretched this wide, a pair of vertical bars
    // becomes a pair of squat slabs. They keep their own width and sit centred
    // in the frame instead, which is why the frame exists.
    final width = double.tryParse(q['w'] ?? '') ?? frameW;
    final height = double.tryParse(q['h'] ?? '') ?? frameH;

    return OaaTheme(
      colors: colors,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: colors.background,
          // Pinned to the top-left rather than filling the window, because
          // headless Chrome refuses to open a window narrower than 500 px:
          // asking for a 360 px one silently lays the page out at 500 and hands
          // back a picture of the wrong layout. Anchoring here means the frame
          // is the same size whatever window the renderer got, and the caller
          // clips a known rectangle out of the corner.
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: frameW,
            height: frameH,
            child: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: ModuleHost(
                  spec: _spec(),
                  engine: _source,
                  clock: _clock,
                  calibration: _calibration,
                  selected: false,
                  // Null, as on the remote display: a menu button that cannot
                  // be pressed in a photograph should not be drawn in one.
                  onMenu: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
