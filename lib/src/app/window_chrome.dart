// SPDX-License-Identifier: GPL-3.0-or-later

/// The part of the window Flutter does not paint.
///
/// Open Audio Analyzer's window has no title bar on macOS. The frame belongs to
/// Flutter from the top edge down and AppKit keeps drawing only the three
/// window buttons, which now sit inside the menu bar on the same row as the
/// File menu and the document's name — see `macos/Runner/MainFlutterWindow.swift`
/// for the window side of it.
///
/// Three consequences land here:
///
///  * The menu bar has to leave the buttons room at its leading edge.
///    [menuBarLeading] is that room.
///  * A window with no title bar cannot be moved or zoomed by one, so the
///    menu bar asks for both itself — [startDrag] and [titleBarClick].
///    Without them the window cannot be moved at all and a double click on its
///    top edge does nothing, and neither of those is a style choice.
///
///    **Only the single click crosses the channel; the pair is counted on the
///    window side.** A `DoubleTapGestureRecognizer` here would hold the
///    gesture arena over the whole menu bar for 300 ms and every button in
///    the row would answer that late — see [WindowDragArea]. AppKit is also
///    the only side that knows the double-click interval this user set and
///    what they asked a title bar's double click to do.
///  * The window's background, and the appearance its buttons are drawn in,
///    follow the skin — which only Dart knows. [applyPalette].
///
/// Everything here is a no-op off macOS. Windows and Linux keep their own
/// frames: each needs its own platform code, and doing one of them properly is
/// a change of its own rather than a third of this one.
library;

import 'dart:io' show Platform;

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract final class WindowChrome {
  /// The same name as the channel in `MainFlutterWindow.swift`. A typo here is
  /// silent: every call fails with `MissingPluginException` and is swallowed,
  /// and the window simply keeps the colour it launched with.
  static const MethodChannel _channel = MethodChannel('oaa/window_chrome');

  /// The menu bar's leading padding.
  ///
  /// **Not a `Space` value, and deliberately not expressed as one.** AppKit
  /// puts the close button 20 pt from the leading edge and the other two on
  /// 20 pt centres after it, 14 pt across, so nothing Flutter paints before
  /// 74 pt is visible — the buttons are drawn over the top of it. This is a
  /// measurement of somebody else's layout; a design token that moved would
  /// take the row off the buttons rather than with them.
  ///
  /// 80 leaves the same gap after the buttons that [Space.md] leaves before
  /// the FILE button on a platform that still has a title bar of its own — and
  /// that is also what the two numbers being close together buys the row: the
  /// leading group ends within 2 px of where it does off macOS, so the name
  /// centred in the window clears both arrangements from one measurement.
  static double get menuBarLeading => Platform.isMacOS ? 80 : Space.md;

  static OaaColors? _applied;

  /// Points the window's background and its buttons at [colors].
  ///
  /// Safe to call from `build`: a palette that is already in force does not
  /// cross the channel, and `paletteProvider` hands out one instance per skin,
  /// so the common case is an identity comparison.
  static void applyPalette(OaaColors colors) {
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

  /// Reports one click on the strip of window that behaves like a title bar.
  ///
  /// Sent for every click the bar wins outright and never for one a control in
  /// it took — see [WindowDragArea]. Which of them are pairs, how long a pair
  /// may take and what a pair does are all the window side's, because all
  /// three are the system's rather than this application's: see
  /// `titleBarClick` in `macos/Runner/MainFlutterWindow.swift`.
  static void titleBarClick() => _invoke('titleBarClick');

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
/// Wraps the menu bar, which is the only thing at the top edge and therefore
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
    // **A pan and a tap may share the arena with the buttons underneath; a
    // double tap may not.** This detector answered the double click with a
    // `DoubleTapGestureRecognizer` once, and that recogniser *holds* the arena
    // from the first tap until `kDoubleTapTimeout` expires 300 ms later. A held
    // arena is never swept, so a button's own tap could not win it and every
    // control in this row fired a third of a second after the click that
    // pressed it — an application that reads as busy rather than as a gesture
    // that is waiting.
    //
    // A `TapGestureRecognizer` holds nothing, and it loses to them rather than
    // stealing from them: the arena is swept in favour of its first member, and
    // hit testing is deepest first, so a control in the row is always entered
    // before this detector is. What reaches [WindowChrome.titleBarClick] is
    // therefore a click on the bar itself and never one a control took — the
    // same division AppKit draws in a title bar of its own — and the window
    // side is what pairs two of them into a double click.
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      // **And a two-finger gesture may not either.** A trackpad pan is not a
      // button press, so the recogniser's button filter never sees it and it
      // wins the arena on the start event — a two-finger scroll anywhere over
      // the menu bar handed the window to the compositor to drag. See
      // [kDragDevices].
      // It bounds the tap as well, which costs nothing: a click on a trackpad
      // is reported as a mouse, and that kind is used for pan and zoom alone.
      supportedDevices: kDragDevices,
      onTap: WindowChrome.titleBarClick,
      onPanStart: (_) => WindowChrome.startDrag(),
      child: child,
    );
  }
}
