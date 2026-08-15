// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../modules/alert_meter.dart';
import '../modules/digital_meter.dart';
import '../modules/histogram.dart';
import '../modules/lufs_meter.dart';
import '../modules/number_box.dart';
import '../modules/phase_scope.dart';
import '../modules/spectrogram.dart';
import '../modules/spectrum_analyzer.dart';
import '../modules/stereo_cloud.dart';
import '../modules/super_meter.dart';
import '../modules/validator.dart';
import '../modules/vu_meter.dart';

/// Turns a [ModuleSpec] into a widget.
///
/// The single place that knows which module kinds exist as code. Everything
/// else in the canvas works in terms of rectangles and ids and does not care
/// what is inside them, which is what keeps the drag, resize and selection
/// logic from acquiring twelve special cases.
///
/// The frame is built here rather than by each module, so that the title, the
/// border, the menu affordance and the selection state are written once.
class ModuleHost extends StatelessWidget {
  const ModuleHost({
    required this.spec,
    required this.engine,
    required this.clock,
    required this.calibration,
    required this.selected,
    required this.onMenu,
    super.key,
  });

  final ModuleSpec spec;
  final BelEngine engine;
  final MeterClock clock;
  final Calibration calibration;
  final bool selected;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return ModuleFrame(
      title: spec.title,
      selected: selected,
      onMenu: onMenu,
      child: _body(),
    );
  }

  Widget _body() {
    // A preset can name a size this build considers unreadable — it may have
    // been written before a module's minimum was raised, or on a version that
    // had no such minimum. Saying "too small" is honest and costs nothing;
    // drawing a two-cell spectrum analyser costs a full FFT to produce a smear.
    if (spec.rect.columns < spec.kind.minColumns ||
        spec.rect.rows < spec.kind.minRows) {
      return const ModuleTooSmall();
    }

    // Exhaustive on purpose: no default arm. When the thirteenth module kind is
    // added the compiler names this switch, rather than the new module silently
    // rendering as "not built" for however long it takes somebody to notice.
    return switch (spec.kind) {
      ModuleKind.numberBox => NumberBoxModule(
        engine: engine,
        clock: clock,
        metric: spec.metric,
        calibration: calibration,
      ),
      ModuleKind.lufsMeter => LufsMeterModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.digitalMeter => DigitalMeterModule(
        engine: engine,
        clock: clock,
      ),
      ModuleKind.superMeter => SuperMeterModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.vuMeter => VuMeterModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.alertMeter => AlertMeterModule(
        engine: engine,
        clock: clock,
        metric: spec.metric,
        calibration: calibration,
      ),
      ModuleKind.validator => ValidatorModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.histogram => HistogramModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.spectrumAnalyzer => SpectrumAnalyzerModule(
        engine: engine,
        clock: clock,
      ),
      ModuleKind.spectrogram => SpectrogramModule(engine: engine, clock: clock),
      ModuleKind.phaseScope => PhaseScopeModule(engine: engine, clock: clock),
      ModuleKind.stereoCloud => StereoCloudModule(engine: engine, clock: clock),
    };
  }
}
