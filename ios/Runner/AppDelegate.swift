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
    // Bel's own, and the only one: iOS will not let the application hold the
    // multicast socket the other platforms browse with. See `BelBonjour.swift`.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BelBonjour") {
      BelBonjour.register(with: registrar)
    }
  }
}
