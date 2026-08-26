// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The microphone, on the one platform that will not open one without being
/// asked in so many words.
///
/// **Android is the only caller here, and the asymmetry is the point.** Every
/// other platform grants capture through the act of opening a device: macOS and
/// iOS put up their own dialog the first time `AVAudioSession` or Core Audio is
/// touched, and Windows and Linux have nothing to grant. Android has a manifest
/// entry *and* a runtime request, and having only the first is indistinguishable
/// from having neither — `AudioRecord` refuses to construct, miniaudio reports a
/// device that will not start, and the application shows the sentence it shows
/// for an interface that has been unplugged.
///
/// That is how the Android build came to be described as a display rather than
/// an analyser. It is the same application as the desktop one, with the same
/// engine compiled into it; what it did not have was permission to hear
/// anything, and nothing anywhere said so.
///
/// Asked when somebody chooses an input, not at launch — see
/// `OaaMicPermission.kt` for why that matters and what a refusal means.
abstract final class MicPermission {
  /// Must match `CHANNEL` in `OaaMicPermission.kt`.
  static const _channel = MethodChannel(
    'com.openaudioanalyzer.oaa/mic_permission',
  );

  /// Whether this platform needs asking at all.
  ///
  /// A `const` on every other platform, so the call sites below compile out and
  /// nothing but Android ever touches the channel. `kIsWeb` first because
  /// `Platform` throws there, and the analyzer demo on the website is a web
  /// build of this same tree.
  static bool get isRequired => !kIsWeb && Platform.isAndroid;

  /// Whether the permission is already held. False if it is not, and false on
  /// any platform that does not need asking — callers want [ensure].
  static Future<bool> get isGranted async {
    if (!isRequired) return true;
    return await _invoke('has');
  }

  /// Asks for the microphone, returning whether it may now be opened.
  ///
  /// Returns true immediately where nothing needs asking, so a call site reads
  /// the same on all six platforms. A refusal is `false` and not an exception:
  /// the user answering "no" is an answer, and the caller's job is to say so
  /// and leave the previous source running rather than to treat it as a fault.
  static Future<bool> ensure() async {
    if (!isRequired) return true;
    return await _invoke('request');
  }

  /// A channel that is not there is a build without the plugin registered —
  /// and, before this existed, every Android build. Answering `false` rather
  /// than throwing keeps that failure on the same path as a refusal: the
  /// application says the input cannot be opened, which is true, instead of
  /// crashing on a platform channel.
  static Future<bool> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
