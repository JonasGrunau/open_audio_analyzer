// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one line the canvas is allowed to say out loud.
///
/// Refusals are the whole of it — "no room for that" and nothing else. A layout
/// edit that silently does nothing is indistinguishable from a broken canvas,
/// so every path that can refuse ends here: a drop the grid will not take, and
/// a module added from the keyboard onto a tab that is already full.
///
/// It is a provider rather than a `ValueNotifier` held by the canvas because
/// since Phase 8 the shortcuts live *above* the canvas — see
/// `lib/src/app/shortcuts.dart` — and reporting from there would otherwise need
/// a second toast. Two toasts is two timeouts, two positions on screen, and
/// eventually two different wordings for the same refusal.
///
/// This is UI state and nothing reads it per frame, which is what makes
/// Riverpod the right place for it. The rule it does not break is the one that
/// matters: no measurement passes through here.
final canvasNoticeProvider = NotifierProvider<CanvasNoticeController, String?>(
  CanvasNoticeController.new,
);

class CanvasNoticeController extends Notifier<String?> {
  Timer? _timer;

  /// Long enough to read a sentence, short enough that it is not still sitting
  /// over a meter when the user looks back.
  static const Duration visible = Duration(seconds: 4);

  @override
  String? build() {
    // The timer outlives nothing. Assigning `state` after the notifier is gone
    // throws, and a four-second fuse is exactly long enough to survive a tab
    // being closed underneath it.
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void say(String message) {
    state = message;
    _timer?.cancel();
    _timer = Timer(visible, () => state = null);
  }

  void clear() {
    _timer?.cancel();
    state = null;
  }
}
