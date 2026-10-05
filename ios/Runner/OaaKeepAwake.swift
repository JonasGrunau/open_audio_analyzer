import Flutter
import UIKit

/// Keeps the screen on while this iPad is somebody else's display.
///
/// A display is a screen nobody touches — it stands on a desk across the room
/// showing a machine somebody else is working at — and iPadOS's Auto-Lock turns
/// exactly that screen off, because nothing has pressed it. The application
/// knows when it is a display and the system does not, so this is the
/// application asking, and only while it is one: the system's own setting
/// governs everything else, which is what the person who asked for it wanted.
///
/// `isIdleTimerDisabled` is per application and the system restores the timer
/// by itself when the application leaves the foreground, so there is nothing
/// here to leak. It is set on the main thread, which is the only thread
/// `UIApplication` may be touched from; the handler already runs there.
enum OaaKeepAwake {
  /// Must match `keepAwakeChannel` in `lib/src/remote/keep_awake.dart`.
  static let channelName = "com.openaudioanalyzer.oaa/keep_awake"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger())

    channel.setMethodCallHandler { call, result in
      guard call.method == "set" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(true)
    }
  }
}
