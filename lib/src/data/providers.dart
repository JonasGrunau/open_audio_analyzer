// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Configuration state. **Not measurements.**
///
/// Everything in this file changes when a human does something — picks a
/// target, changes the frame rate, loads a preset. That is what makes it a
/// good fit for Riverpod: it is rare, it is user-driven, and rebuilding widgets
/// in response is exactly right.
///
/// Measurements are the opposite on every axis, which is why they are not here
/// and never will be. Routing a 47 Hz stream of readings through a provider
/// would rebuild the widget subtree under every meter forty-seven times a
/// second to change some numbers that a painter could have read directly from
/// native memory for free.

/// The active delivery target.
final calibrationProvider =
    NotifierProvider<CalibrationController, Calibration>(
      CalibrationController.new,
    );

class CalibrationController extends Notifier<Calibration> {
  @override
  Calibration build() => BuiltInCalibrations.fallback;

  void select(Calibration calibration) => state = calibration;

  void selectById(String id) {
    final found = BuiltInCalibrations.byId(id);
    if (found != null) state = found;
  }
}

/// How often the meters are allowed to repaint.
final targetFpsProvider = NotifierProvider<TargetFpsController, int>(
  TargetFpsController.new,
);

class TargetFpsController extends Notifier<int> {
  /// The rates offered. 30 halves GPU load for a session left open all day;
  /// 120 exists because the displays do.
  static const List<int> options = [30, 60, 120];

  @override
  int build() => 60;

  void select(int fps) {
    if (options.contains(fps)) state = fps;
  }
}
