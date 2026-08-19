// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../modules/alert_meter.dart';
import '../modules/digital_meter.dart';
import '../modules/histogram.dart';
import '../modules/loudness_distribution.dart';
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
/// logic from acquiring thirteen special cases.
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
  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;
  final bool selected;

  /// Null on a surface where a module has nothing to open — the remote display.
  /// `ModuleFrame` then draws no button at all, which is the honest picture: a
  /// viewer cannot change anything about what is on that screen, and a control
  /// that is drawn and does nothing is worse than one that is not there.
  final VoidCallback? onMenu;

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

    // **And again in pixels, because a cell is not a size.** The canvas is
    // 24x16 cells at every window size, so the same legal two-row module is
    // 160 px tall on a 27" display and 40 px on a small window. Every painter
    // already refused to draw below its own threshold, and a painter that
    // refuses draws nothing at all: on a 1024x640 window the six Number Boxes
    // across the top of the default preset were six empty panels, which reads
    // as a meter that has failed rather than as a window that is too small.
    //
    // The thresholds live on `ModuleKind` now. This measures the body — what
    // is left after the title bar and `ModuleFrame`'s inset — because that is
    // what the painter is handed.
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth < spec.kind.minBodyWidth ||
              constraints.maxHeight < spec.kind.minBodyHeight
          ? const ModuleTooSmall()
          : _meter(),
    );
  }

  Widget _meter() {
    // Exhaustive on purpose: no default arm. When the fourteenth module kind is
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
      ModuleKind.loudnessDistribution => LoudnessDistributionModule(
        engine: engine,
        clock: clock,
        calibration: calibration,
      ),
      ModuleKind.spectrumAnalyzer => SpectrumAnalyzerModule(
        engine: engine,
        clock: clock,
        response: spec.spectrumResponse,
      ),
      ModuleKind.spectrogram => SpectrogramModule(engine: engine, clock: clock),
      ModuleKind.phaseScope => PhaseScopeModule(engine: engine, clock: clock),
      ModuleKind.stereoCloud => StereoCloudModule(engine: engine, clock: clock),
    };
  }
}
