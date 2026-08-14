import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Flutter's stock 800x600 is too small for a canvas of meters — the status
  /// bar alone has to drop controls to fit. These are the sizes a metering
  /// workspace is actually usable at.
  private static let defaultSize = NSSize(width: 1440, height: 900)
  private static let minimumSize = NSSize(width: 720, height: 480)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.contentMinSize = MainFlutterWindow.minimumSize

    // Only size the window on a genuinely fresh launch. AppKit restores a saved
    // frame through the autosave mechanism, and overriding it every time would
    // throw away the position and size the user chose. Checking the defaults
    // key is how you ask "has this ever been saved?" — `frameAutosaveName` is
    // read-only and tells you nothing about whether a frame exists for it.
    let autosaveName = "BelMainWindow"
    let hasSavedFrame =
      UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil

    self.setFrameAutosaveName(autosaveName)

    if !hasSavedFrame {
      self.setContentSize(MainFlutterWindow.defaultSize)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
