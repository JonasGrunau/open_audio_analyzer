import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Open Audio Analyzer's own, and the only one: iOS will not let the
    // application hold the multicast socket the other platforms browse with.
    // See `OaaBonjour.swift`.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OaaBonjour") {
      OaaBonjour.register(with: registrar)
    }
    // And the second: iOS hands Dart's `main` an empty argument list, an empty
    // environment, and no way to set `dartEntrypointArguments` on an engine it
    // created itself. See `OaaLaunchArguments.swift`.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OaaLaunchArguments") {
      OaaLaunchArguments.register(with: registrar)
    }
  }
}
