// SPDX-License-Identifier: GPL-3.0-or-later

/// A canvas of the application's real meter modules, running live in a browser.
///
/// What the website embeds behind "Open the live analyzer". Every module here is
/// the real one from `package:oaa` — the same `ModuleHost`, the same
/// `ModuleFrame`, the same painters, laid out on the same `GridGeometry` and
/// repainting from one `MeterClock`, exactly as the desktop canvas and the
/// tablet remote display do.
///
/// The only thing that is not real is where the numbers come from. There is no
/// engine: `dart:ffi` has no web implementation, and this build never reaches
/// `OaaEngine` — `MockSource` sits in its place, a third `MeterSource` beside
/// the native one and the socket-backed one the tablet reads. Nothing on this
/// canvas knows the difference, which is the point of that interface.
///
///     ?seconds=32      freeze after this much programme, for a screenshot
///
/// Without it the programme runs indefinitely.
library;

import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_mock/oaa_mock.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// Set once the programme has frozen and the final frame is painted. Only
/// meaningful when `?seconds=` was given — see `scripts/render-analyzer.mjs`.
@JS('oaaRenderReady')
external set _renderReady(bool value);

/// Set as soon as anything has actually been drawn.
///
/// The page that embeds this waits for it before fading the iframe in over the
/// still. `load` is too early: it fires when the document is parsed, several
/// seconds before CanvasKit has been fetched and the first frame painted, so
/// fading on it swapped a photograph of the meters for an empty panel.
@JS('oaaFirstFrame')
external set _firstFrame(bool value);

void main() => runApp(const AnalyzerDemo());

const _calibration = Calibration(
  id: 'streaming',
  name: 'Streaming',
  lufsTarget: -14.0,
  lufsTolerance: 0.5,
  truePeakMax: -1.0,
  loudnessRangeMax: 12.0,
);

/// The canvas, as one tab of eight modules on the 24x16 grid.
///
/// Authored here rather than read from a preset because it is a piece of the
/// website: it is chosen to show the range of what the application draws — bars,
/// arcs, a spectrum, a time axis, a verdict, a waveform — in one screen. Every
/// rect clears its module's stated minimum in [ModuleKind]; a rect that does not
/// draws `ModuleTooSmall`, which is honest and not what a demo is for.
final _tab = TabSpec(
  name: 'Mastering',
  modules: [
    // Loudness, across the top.
    const ModuleSpec(
      id: 'lufs',
      kind: ModuleKind.lufsMeter,
      rect: GridRect(column: 0, row: 0, columns: 5, rows: 8),
    ),
    const ModuleSpec(
      id: 'super',
      kind: ModuleKind.superMeter,
      rect: GridRect(column: 5, row: 0, columns: 8, rows: 8),
    ),
    const ModuleSpec(
      id: 'spectrum',
      kind: ModuleKind.spectrumAnalyzer,
      rect: GridRect(column: 13, row: 0, columns: 11, rows: 8),
    ),
    // How the programme moved, what it delivers against, and the channels.
    const ModuleSpec(
      id: 'histogram',
      kind: ModuleKind.histogram,
      rect: GridRect(column: 0, row: 8, columns: 13, rows: 5),
    ),
    const ModuleSpec(
      id: 'validator',
      kind: ModuleKind.validator,
      rect: GridRect(column: 13, row: 8, columns: 6, rows: 5),
    ),
    const ModuleSpec(
      id: 'digital',
      kind: ModuleKind.digitalMeter,
      rect: GridRect(column: 19, row: 8, columns: 5, rows: 8),
    ),
    // The signal itself, and the one thing that is failing.
    const ModuleSpec(
      id: 'scope',
      kind: ModuleKind.oscilloscope,
      rect: GridRect(column: 0, row: 13, columns: 13, rows: 3),
      options: {'timeBase': '20ms'},
    ),
    const ModuleSpec(
      id: 'alert',
      kind: ModuleKind.alertMeter,
      rect: GridRect(column: 13, row: 13, columns: 6, rows: 3),
    ),
  ],
);

class AnalyzerDemo extends StatefulWidget {
  const AnalyzerDemo({super.key});

  @override
  State<AnalyzerDemo> createState() => _AnalyzerDemoState();
}

class _AnalyzerDemoState extends State<AnalyzerDemo>
    with SingleTickerProviderStateMixin {
  late final MockSource _source = MockSource(
    // Runs indefinitely unless a screenshot asked for a stopping point.
    captureAt:
        double.tryParse(Uri.base.queryParameters['seconds'] ?? '') ??
        double.infinity,
    // A second of programme per second of watching, unless this is a
    // screenshot — a still has to come out the same every time, so it steps by
    // frame instead. See MockSource.realtime.
    realtime: !Uri.base.queryParameters.containsKey('seconds'),
    onFrozen: _announceReady,
  );
  late final MeterClock _clock = MeterClock(engine: _source, vsync: this);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstFrame = true);
  }

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

  @override
  Widget build(BuildContext context) {
    final colors = oaaColorsFromSkin(BuiltInSkins.precisionInstrument);

    return OaaTheme(
      colors: colors,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: colors.background,
          padding: const EdgeInsets.all(Space.sm),
          // The same composition the tablet's canvas uses: one GridGeometry
          // sized to whatever the window is, every module positioned by the
          // rect it declares, and each keyed by id so that resizing the window
          // preserves the State its painter has laid its paragraphs out in.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = GridGeometry(size: constraints.biggest);

              return Stack(
                children: [
                  for (final module in _tab.modules)
                    Positioned.fromRect(
                      rect: geometry.rectFor(module.rect),
                      key: ValueKey<String>(module.id),
                      child: ModuleHost(
                        spec: module,
                        engine: _source,
                        clock: _clock,
                        calibration: _calibration,
                        selected: false,
                        // Nothing on this canvas can be changed, so no module
                        // draws a menu button — a control that swallows the tap
                        // is worse than no control.
                        onMenu: null,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
