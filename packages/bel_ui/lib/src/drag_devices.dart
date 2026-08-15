// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/gestures.dart';

/// The pointer kinds a drag may begin from: every kind except the one that is
/// not a pointer at all.
///
/// **Pass this to `supportedDevices` on every `GestureDetector` with an
/// `onPan*` callback.** Without it, any two-finger trackpad gesture that begins
/// over the detector starts a drag.
///
/// A `PanGestureRecognizer` filters buttons — `allowedButtonsFilter` defaults
/// to the primary one — and that filter is never consulted for a trackpad,
/// because a trackpad gesture is not a button press. It arrives as a
/// `PointerPanZoomStartEvent`, and `GestureRecognizer.isPointerPanZoomAllowed`
/// looks at `supportedDevices` and nothing else. The recogniser then accepts on
/// the *start* event, with no slop to cross, so the drag is live before a
/// finger has moved.
///
/// That is not a theoretical hazard on macOS, where a two-finger tap is how a
/// trackpad sends a right click: right-clicking a module's title bar flashed
/// the placement grid on screen, and a two-finger scroll over one dragged the
/// module. The window drag area had the same hole, where the consequence is the
/// whole window moving.
///
/// Excluding [PointerDeviceKind.trackpad] costs nothing: a click and drag on a
/// trackpad is reported as a mouse. That kind is used for pan and zoom alone.
///
/// Not a `const` set of the kinds that are allowed, because the list of kinds
/// is Flutter's and a new one added there would be pointer-like far more often
/// than not. Stated as the exclusion it is.
final Set<PointerDeviceKind> kDragDevices = PointerDeviceKind.values.toSet()
  ..remove(PointerDeviceKind.trackpad);
