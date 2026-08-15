// SPDX-License-Identifier: GPL-3.0-or-later

/// The part of the window Flutter does not paint.
///
/// Bel's window has no title bar on macOS. The frame belongs to Flutter from
/// the top edge down and AppKit keeps drawing only the three window buttons,
/// which now sit inside the status bar on the same row as BEL and the source —
/// see `macos/Runner/MainFlutterWindow.swift` for the window side of it.
///
/// Three consequences land here:
///
///  * The status bar has to leave the buttons room at its leading edge.
///    [statusBarLeading] is that room.
///  * A window with no title bar cannot be moved by one, so the status bar asks
///    for the drag itself — [startDrag]. Without it the window could not be
///    moved at all, which is a regression and not a style. Zoom is *not* asked
///    for here: it costs a double-tap recogniser, and one of those over the
///    status bar delays every button in it — see [WindowDragArea]. The green
///    window button still zooms, because AppKit still draws it.
///  * The window's background, and the appearance its buttons are drawn in,
///    follow the skin — which only Dart knows. [applyPalette].
///
/// Everything here is a no-op off macOS. Windows and Linux keep their own
/// frames: each needs its own platform code, and doing one of them properly is
/// a change of its own rather than a third of this one.
library;

import 'dart:io' show Platform;

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract final class WindowChrome {
  /// The same name as the channel in `MainFlutterWindow.swift`. A typo here is
  /// silent: every call fails with `MissingPluginException` and is swallowed,
  /// and the window simply keeps the colour it launched with.
  static const MethodChannel _channel = MethodChannel('bel/window_chrome');

  /// The status bar's leading padding.
  ///
  /// **Not a `Space` value, and deliberately not expressed as one.** AppKit
  /// puts the close button 20 pt from the leading edge and the other two on
  /// 20 pt centres after it, 14 pt across, so nothing Flutter paints before
  /// 74 pt is visible — the buttons are drawn over the top of it. This is a
  /// measurement of somebody else's layout; a design token that moved would
  /// take the row off the buttons rather than with them.
  ///
  /// 80 leaves the same gap after the buttons that [Space.md] leaves before
  /// `BEL` on a platform that still has a title bar of its own.
  static double get statusBarLeading => Platform.isMacOS ? 80 : Space.md;

  static BelColors? _applied;

  /// Points the window's background and its buttons at [colors].
  ///
  /// Safe to call from `build`: a palette that is already in force does not
  /// cross the channel, and `paletteProvider` hands out one instance per skin,
  /// so the common case is an identity comparison.
  static void applyPalette(BelColors colors) {
    if (colors == _applied) return;
    _applied = colors;

    // The channels go over as floats rather than as a packed integer because
    // that is what both sides already hold: `Color` stores them that way since
    // `Color.value` was deprecated, and `NSColor` takes them that way. Packing
    // to 8 bits in the middle would be a quantisation nobody asked for.
    _invoke('setPalette', <String, Object?>{
      'r': colors.panel.r,
      'g': colors.panel.g,
      'b': colors.panel.b,
      'a': colors.panel.a,
      'light': colors.isLight,
    });
  }

  /// Moves the window with the pointer until it is released.
  ///
  /// Call from a pan, not from a tap: the window side continues the mouse event
  /// that is still in flight, and there is nothing to continue once the button
  /// is up.
  static void startDrag() => _invoke('startDrag');

  /// Fire and forget, and deliberately silent.
  ///
  /// Nothing here is load-bearing — a call that fails leaves a window that
  /// looks like a stock one — and the case that actually happens is a widget
  /// test, which runs on a macOS host with no window and no handler registered
  /// and would otherwise fail on an unhandled `MissingPluginException`.
  static void _invoke(String method, [Object? arguments]) {
    if (!Platform.isMacOS) return;
    _channel.invokeMethod<void>(method, arguments).catchError((Object _) {});
  }
}

/// The strip of the window that behaves like a title bar.
///
/// Wraps the status bar, which is the only thing at the top edge and therefore
/// the only place the gestures a title bar used to answer can go. Off macOS it
/// is its child and nothing else.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return child;

    // `deferToChild` is what keeps the row's controls working. The pan
    // recogniser here and a button's tap recogniser below both enter the
    // arena, and a tap that never moved wins it — so a click still presses the
    // button and a drag that starts on the same button still moves the window,
    // which is exactly what dragging a title bar's controls does.
    //
    // **A pan may share the arena with the buttons underneath; a double tap may
    // not.** This detector also answered a double click with a zoom, which put
    // a `DoubleTapGestureRecognizer` over the whole status bar — and that
    // recogniser *holds* the arena from the first tap until `kDoubleTapTimeout`
    // expires, 300 ms later. A held arena is never swept, so the button's own
    // tap could not win it, and every control in this row fired a third of a
    // second after the click that pressed it. It read as an application that
    // was busy rather than as a gesture that was waiting. A pan recogniser does
    // not hold, which is why the drag can stay.
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      // **And a two-finger gesture may not either.** A trackpad pan is not a
      // button press, so the recogniser's button filter never sees it and it
      // wins the arena on the start event — a two-finger scroll anywhere over
      // the status bar handed the window to the compositor to drag. See
      // [kDragDevices].
      supportedDevices: kDragDevices,
      onPanStart: (_) => WindowChrome.startDrag(),
      child: child,
    );
  }
}
