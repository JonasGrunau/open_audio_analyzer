// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel `android/.../OaaKeepAwake.kt` and `ios/Runner/OaaKeepAwake.swift`
/// answer on.
const MethodChannel keepAwakeChannel = MethodChannel(
  'com.openaudioanalyzer.oaa/keep_awake',
);

/// Whether the screen stays on, asked of the platform.
///
/// **A display is a screen nobody touches, which is exactly the screen a
/// tablet's idle timeout switches off.** The person holding one should not have
/// to change a system setting to use it as a display and change it back
/// afterwards, and the application is the only party that knows when it is
/// one. So the display screen asks while it is showing a host and lets go when
/// it stops — see `RemoteDisplayScreen` — and the system's own timeout governs
/// everything else.
///
/// Only Android and iOS answer. A desktop's screen saver is the user's
/// business, and a Mac on a desk is not the device this is for.
///
/// **Failure is silent**, like every other convenience on a channel here: a
/// screen that goes to sleep is the behaviour the tablet had before this
/// existed, and a display that refused to draw because the channel was not
/// registered yet would be trading the meters for it.
class KeepAwake {
  KeepAwake._();

  /// Whether this platform has anything to ask. Overridden by the suite, which
  /// runs on a host where the channel is unimplemented.
  @visibleForTesting
  static bool? platformSupported;

  static bool get _supported =>
      platformSupported ?? (Platform.isAndroid || Platform.isIOS);

  /// The last answer asked for, so that a screen rebuilt thirty times with the
  /// same setting crosses the channel once.
  static bool? _current;

  /// What was last asked for, for a test to read.
  @visibleForTesting
  static bool? get current => _current;

  @visibleForTesting
  static void reset() => _current = null;

  static Future<void> set(bool on) async {
    if (!_supported || _current == on) return;
    _current = on;
    try {
      await keepAwakeChannel.invokeMethod<bool>('set', {'on': on});
    } on Object catch (error) {
      debugPrint('Could not ask the screen to stay on: $error');
    }
  }
}
