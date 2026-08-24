import Cocoa
import FlutterMacOS

/// The application's File menu, built here because Flutter cannot build one.
///
/// `PlatformMenuBar` is the obvious tool and it cannot do this job: the
/// `flutter/menu` channel carries no checked state — two of these six rows *are*
/// a state — and `setMenus` replaces the entire main menu, which would take the
/// stock Edit menu with it and leave nothing to rebuild Cut, Copy and Paste
/// from. So one `NSMenu` is inserted after the application menu and everything
/// else in `MainMenu.xib` is left alone. The reasoning is written out once more
/// in `lib/src/app/file_menu.dart`.
///
/// **Nothing here decides anything.** The labels, the ticks, the enabled state
/// and the key equivalents all arrive from Dart, because the chords belong to
/// the table in `lib/src/app/shortcuts.dart` and a chord declared in Swift would
/// be a binding that works and is documented nowhere. This file knows how to
/// draw a menu and how to report a click, and that is all it knows.
final class OaaFileMenu: NSObject {
  /// The same name as the channel in `lib/src/app/file_menu.dart`. A typo here
  /// is silent.
  private static let channelName = "oaa/file_menu"

  /// Retained, because a `FlutterMethodChannel` that nobody holds is collected
  /// and takes its handler with it — the calls then simply stop arriving. The
  /// same reason `MainFlutterWindow` holds on to `chrome`.
  private let channel: FlutterMethodChannel

  /// The item in the main menu whose submenu this is, kept so that a hot
  /// restart replaces the menu rather than inserting a second one beside it.
  private var installed: NSMenuItem?

  /// The rows, by the id Dart calls them. `update` addresses them by id and not
  /// by index: inserting a row would otherwise silently re-point every row
  /// below it.
  private var rows: [String: NSMenuItem] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: OaaFileMenu.channelName, binaryMessenger: messenger)
    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let items = arguments["items"] as? [[String: Any]]
    else {
      result(
        FlutterError(
          code: "bad-arguments",
          message: "\(call.method) wants a list of items",
          details: nil))
      return
    }

    switch call.method {
    case "install":
      install(items)
      result(nil)

    case "update":
      update(items)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Builds the menu and puts it in the bar.
  ///
  /// Called from Dart rather than from `awakeFromNib` for two reasons: the
  /// commands need a `Navigator` to open a dialog over, which does not exist
  /// until Dart has drawn a frame, and `NSApp.mainMenu` is set by the nib whose
  /// load order relative to the window's is not something to depend on.
  private func install(_ items: [[String: Any]]) {
    guard let bar = NSApp.mainMenu else { return }

    let menu = NSMenu(title: "File")

    // **Automatic enabling off.** By default AppKit decides whether a menu item
    // is enabled by looking for a responder that implements its action, which
    // would overrule everything Dart says about it — and what Dart says is the
    // only thing that knows whether a panel is open in front of the canvas.
    menu.autoenablesItems = false

    rows.removeAll()
    for item in items {
      if item["divider"] as? Bool == true {
        menu.addItem(.separator())
      }
      guard let row = makeRow(item) else { continue }
      menu.addItem(row)
    }

    let entry = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    entry.submenu = menu

    // After the application menu, which is where a File menu is on every Mac.
    // A hot restart re-installs, so the previous one goes first.
    if let previous = installed, let index = bar.items.firstIndex(of: previous) {
      bar.removeItem(at: index)
      bar.insertItem(entry, at: index)
    } else {
      bar.insertItem(entry, at: min(1, bar.items.count))
    }
    installed = entry
  }

  private func makeRow(_ item: [String: Any]) -> NSMenuItem? {
    guard let id = item["id"] as? String, let label = item["label"] as? String
    else { return nil }

    let row = NSMenuItem(
      title: label, action: #selector(fire(_:)), keyEquivalent: "")
    row.target = self
    row.representedObject = id
    apply(item, to: row)

    rows[id] = row
    return row
  }

  /// Pushes the labels, the ticks and the enabled state again.
  ///
  /// The titles are fixed, so in practice this is the ticks on the two carry
  /// rows and the enabled state of the whole menu; the title is written anyway
  /// because the payload carries it and a row is cheap to set.
  private func update(_ items: [[String: Any]]) {
    for item in items {
      guard let id = item["id"] as? String, let row = rows[id] else { continue }
      if let label = item["label"] as? String { row.title = label }
      apply(item, to: row)
    }
  }

  private func apply(_ item: [String: Any], to row: NSMenuItem) {
    row.isEnabled = item["enabled"] as? Bool ?? true

    // Null is a row that is an action rather than a state. `.off` is the same
    // pixels as no state at all, and AppKit reserves the state column for the
    // whole menu either way, so every row stays on one left edge.
    switch item["checked"] as? Bool {
    case .some(true): row.state = .on
    default: row.state = .off
    }

    // Command is implied: a key equivalent in a Mac menu is a ⌘ chord, and the
    // Dart side sends nothing for a chord that is not one.
    if let key = item["key"] as? String, !key.isEmpty {
      row.keyEquivalent = key
      var modifiers: NSEvent.ModifierFlags = [.command]
      if item["shift"] as? Bool == true { modifiers.insert(.shift) }
      if item["alt"] as? Bool == true { modifiers.insert(.option) }
      if item["control"] as? Bool == true { modifiers.insert(.control) }
      row.keyEquivalentModifierMask = modifiers
    } else {
      row.keyEquivalent = ""
    }
  }

  @objc private func fire(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("command", arguments: id)
  }
}
