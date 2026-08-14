// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/rendering.dart';

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
abstract class MeterPainter extends CustomPainter {
  const MeterPainter({super.repaint});

  @override
  bool? hitTest(Offset position) => false;
}
