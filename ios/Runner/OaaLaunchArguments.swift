import Flutter
import UIKit

/// The command line, because iOS will not give it to Flutter.
///
/// On the three desktops the process arguments arrive at Dart's `main` — Windows
/// and Linux forward them out of the box, and `macos/Runner/MainFlutterWindow.swift`
/// sets `dartEntrypointArguments` so that macOS does too. On iOS there is
/// nowhere to set that: the engine is created implicitly by the
/// `FlutterViewController` the storyboard builds, and `FlutterImplicitEngineBridge`
/// vends a plugin registry and nothing else. So `main` is handed an empty list.
///
/// The obvious way round it is not one. Dart's `Platform.environment` is
/// **empty** on iOS — not missing the variable, empty, every time — so
/// `xcrun simctl launch`'s `SIMCTL_CHILD_…` passthrough reaches the process
/// (`ps eww` shows it) and stops at the VM. `Platform.executableArguments` is
/// empty too. There is no route from the launcher into the application that does
/// not cross a channel.
///
/// So this is that channel, and it answers the whole command line rather than
/// one question, because the four flags in `lib/src/app/launch_options.dart` are
/// already one parser and a platform that has to be asked twice will eventually
/// be asked for something it was not told. `CommandLine.arguments` is the real
/// argv, so `xcrun simctl launch <device> <bundle> --args --attach=oaa://host:port`
/// works on a simulator exactly as `open --args` does on a Mac.
///
/// What it buys is a tablet that can be driven without touching it. The
/// signal-path photographs on the website are a desktop and an iPad drawing one
/// published frame, which needs PUBLISH pressed at one end and ATTACH at the
/// other; before this the only way to press the second was to post synthetic
/// mouse events at the Simulator's window, which takes the pointer away from
/// whoever is at the machine. See `packaging/signal_path.sh`.
enum OaaLaunchArguments {
  static let channelName = "oaa/launch_arguments"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger())

    channel.setMethodCallHandler { call, result in
      guard call.method == "arguments" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Dropping argv[0], which is the executable and not an argument, so that
      // the list is the same shape `main(List<String> arguments)` is handed
      // everywhere else.
      result(Array(CommandLine.arguments.dropFirst()))
    }
  }
}
