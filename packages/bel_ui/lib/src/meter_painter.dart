// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// The base class every module painter extends.
///
/// It exists for one reason, and it is not shared behaviour — it is a default
/// in Flutter that is wrong for this application.
///
/// [CustomPainter.hitTest] returns `null` by default, and `RenderCustomPaint`
/// reads that as **true**: a `CustomPaint` with a background painter swallows
/// every pointer event that lands on it. That default is right for a painted
/// button and wrong for a meter. The canvas puts a module's drag, select and
/// context-menu affordances *behind* the module — so that the frame's own menu
/// button keeps priority without any gesture-arena arbitration — and a painter
/// that absorbs hits makes the whole body of the module dead to the mouse. You
/// can drag a meter by its title bar and not by its face, which reads as a bug
/// in the canvas rather than a default in the painter.
///
/// So meters are display surfaces and do not take input. A module that genuinely
/// needs it — scrubbing a histogram, dragging a spectrum cursor — overrides
/// [hitTest] again and opts back in deliberately.
/// A meter's body: one painter, filling whatever room the frame gives it.
///
/// The `SizedBox.expand` is not decoration. A [CustomPaint] with no child has
/// no intrinsic size and collapses to nothing, and the symptom is a module that
/// draws its frame and its title and then nothing at all — which reads as a
/// broken meter rather than as a layout mistake. Every module used to write
/// this line; now none of them can forget it.
class MeterBody extends StatelessWidget {
  const MeterBody({required this.painter, super.key});

  final MeterPainter painter;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: painter, child: const SizedBox.expand());
}

abstract class MeterPainter extends CustomPainter {
  const MeterPainter({super.repaint});

  @override
  bool? hitTest(Offset position) => false;
}
