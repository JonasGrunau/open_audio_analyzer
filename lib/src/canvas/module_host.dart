// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../modules/number_box.dart';

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
      ModuleKind.lufsMeter ||
      ModuleKind.digitalMeter ||
      ModuleKind.superMeter ||
      ModuleKind.vuMeter ||
      ModuleKind.alertMeter ||
      ModuleKind.validator ||
      ModuleKind.histogram ||
      ModuleKind.spectrumAnalyzer ||
      ModuleKind.spectrogram ||
      ModuleKind.phaseScope ||
      ModuleKind.stereoCloud => const _NotBuiltYet(),
    };
  }
}

/// Stands in for a module kind the canvas can place but this build cannot draw.
///
/// Placing one is allowed deliberately: laying out a tab is useful before every
/// meter exists, and a canvas that refuses eleven of twelve kinds hides the
/// shape of the finished product. What it must never do is look like a meter —
/// an empty panel with a title bar reads as a meter showing nothing, which is
/// indistinguishable from a meter that is broken. So it says what it is.
class _NotBuiltYet extends StatelessWidget {
  const _NotBuiltYet();

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    // Inert, like every meter body. Text absorbs pointer events, and a module
    // you cannot drag by its own middle is a module that looks broken.
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'NOT BUILT YET',
              style: BelType.label.copyWith(color: colors.textFaint),
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Phase 3',
              style: BelType.caption.copyWith(color: colors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}
