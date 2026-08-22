import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Flutter's stock 800x600 is too small for a canvas of meters — the status
  /// bar alone has to drop controls to fit. These are the sizes a metering
  /// workspace is actually usable at.
  ///
  /// The minimum is arithmetic, not taste. The canvas is a fixed 24x16 cells at
  /// every window size, so the row height is `(height - 104) / 16` after the
  /// status bar, the tab strip and the canvas inset; the smallest module in the
  /// default preset is two rows, and it needs 24 px of body left over once its
  /// title bar and margin are taken. That puts the floor at 768. The old 480
  /// gave a two-row module 12 px of body, which is why every Number Box on the
  /// default tab was an empty panel. The width is the point below which the
  /// status bar starts dropping controls it should not have to.
  private static let defaultSize = NSSize(width: 1440, height: 900)
  private static let minimumSize = NSSize(width: 960, height: 768)

  /// The height of the bar Flutter draws across the top of the window.
  ///
  /// **The same number as `_StatusBar.height` in `lib/src/app/oaa_app.dart`.**
  /// There is no way to share it — this file is compiled before Dart runs, and
  /// the buttons have to be in the right place in the first frame, not after a
  /// round trip. What it buys is the window buttons sitting on the row they are
  /// now part of; if the two drift apart they sit slightly above or below it,
  /// which reads as a rendering fault rather than a style.
  private static let statusBarHeight: CGFloat = 40

  /// The default skin's `panel`, so that the window that appears before Flutter
  /// has drawn anything is already the colour the status bar will be. Dart
  /// replaces it with the active skin's on the first build — see
  /// `lib/src/app/window_chrome.dart`.
  private static let initialBackground = NSColor(
    srgbRed: 0x12 / 255, green: 0x14 / 255, blue: 0x17 / 255, alpha: 1)

  /// Retained, because a `FlutterMethodChannel` that nobody holds is collected
  /// and takes its handler with it — the calls then simply stop arriving.
  private var chrome: FlutterMethodChannel?

  /// When the status bar last reported a click, on the monotonic clock.
  ///
  /// The distant past rather than zero: `systemUptime` starts at zero, so a
  /// click in the first half second after a boot would otherwise be the second
  /// of a pair that never had a first.
  private var lastTitleBarClick: TimeInterval = -.greatestFiniteMagnitude

  override func awakeFromNib() {
    // The Windows and Linux runners forward the command line to the Dart
    // entrypoint themselves; the stock macOS one builds a bare
    // FlutterViewController and forwards nothing. Without these two lines
    // `--config-dir` and `--open-panel` work on two platforms out of three and
    // are silently ignored on the one where they exist for — `open --args` is
    // the only way to hand a Mac application arguments without launching the
    // binary inside the bundle, which is what breaks device capture.
    //
    // argv[0] is dropped. Everything else is passed through, including the
    // `-psn_0_…` the Finder appends and the flags Xcode adds in a debug launch,
    // because the parser ignores what it does not recognise and a runner that
    // filtered here would be a second place to keep that list.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())

    let flutterViewController = FlutterViewController(project: project)
    self.contentViewController = flutterViewController

    self.contentMinSize = MainFlutterWindow.minimumSize

    // **The window has no title bar of its own.** `fullSizeContentView` gives
    // the whole frame to Flutter, `titlebarAppearsTransparent` stops AppKit
    // painting a system material over the top of it, and hiding the title
    // removes the one piece of text in the window whose font, colour and weight
    // Open Audio Analyzer does not choose. What is left is a single bar of
    // `panel` from the top edge down, with the three window buttons sitting
    // inside it on the same row as OAA and the source.
    //
    // Dragging the window goes with the title bar, and so does zooming it by
    // double-clicking one; the status bar asks for both back over the channel
    // below. Neither is a style choice — a window that cannot be moved is a
    // regression, and a Mac window whose top edge ignores a double click is one
    // that answers a gesture every other window on the machine answers.
    //
    // What the status bar sends is one click at a time. Recognising the pair in
    // Flutter costs a `DoubleTapGestureRecognizer`, and everything under one of
    // those answers 300 ms late — see `WindowDragArea`.
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.backgroundColor = MainFlutterWindow.initialBackground

    self.chrome = FlutterMethodChannel(
      name: "oaa/window_chrome",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.chrome?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    // Only size the window on a genuinely fresh launch. AppKit restores a saved
    // frame through the autosave mechanism, and overriding it every time would
    // throw away the position and size the user chose. Checking the defaults
    // key is how you ask "has this ever been saved?" — `frameAutosaveName` is
    // read-only and tells you nothing about whether a frame exists for it.
    let autosaveName = "OaaMainWindow"
    let hasSavedFrame =
      UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil

    self.setFrameAutosaveName(autosaveName)

    if !hasSavedFrame {
      self.setContentSize(MainFlutterWindow.defaultSize)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    alignWindowButtons()
  }

  /// AppKit restores the frames of the views it owns on every layout pass — a
  /// resize, a full-screen transition, a move to a display with a different
  /// scale — so the alignment has to be reasserted rather than set once.
  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    alignWindowButtons()
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "setPalette":
      guard let arguments = call.arguments as? [String: Any],
        let red = arguments["r"] as? Double,
        let green = arguments["g"] as? Double,
        let blue = arguments["b"] as? Double,
        let alpha = arguments["a"] as? Double,
        let isLight = arguments["light"] as? Bool
      else {
        result(
          FlutterError(
            code: "bad-arguments",
            message: "setPalette wants r, g, b, a and light",
            details: nil))
        return
      }
      apply(red: red, green: green, blue: blue, alpha: alpha, isLight: isLight)
      result(nil)

    case "startDrag":
      // `performDrag` continues the mouse event that is still in flight rather
      // than starting something new, so it is only meaningful while one is —
      // which is why this is called from a pan gesture and not from a tap.
      if let event = NSApp.currentEvent { self.performDrag(with: event) }
      result(nil)

    case "titleBarClick":
      titleBarClick()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(
    red: Double, green: Double, blue: Double, alpha: Double, isLight: Bool
  ) {
    // Flutter's colour channels arrive as floats in the same sRGB space AppKit
    // names here, so this is a relabelling and not a conversion.
    self.backgroundColor = NSColor(
      srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
      alpha: CGFloat(alpha))

    // The three buttons are the only pixels in the window Open Audio Analyzer
    // does not paint, and they are drawn by the appearance rather than by a
    // colour: under a light skin a dark appearance greys them the wrong way and
    // puts a dark focus ring around a light bar. This is the one thing the
    // skin's `light` flag decides that no colour value could.
    self.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
  }

  /// The status bar's own background answered a click.
  ///
  /// Dart sends one of these per click the bar wins outright — a click a control
  /// in the row took is never one of them, which is the division AppKit draws in
  /// a title bar of its own — and everything else about the gesture is decided
  /// here, because everything else about it belongs to the system.
  /// `NSEvent.doubleClickInterval` is the user's "Double-click speed", which is
  /// half a second by default and nothing like Flutter's fixed 300 ms, and
  /// `AppleActionOnDoubleClick` is what they asked "double-click a window's
  /// title bar to" for: a Mac set to Minimize expects this bar to minimise, and
  /// one set to do nothing expects nothing.
  ///
  /// **The click count is not read off the event, and that is not an
  /// oversight.** `NSApp.currentEvent` is what `startDrag` reads, and it is
  /// sound there because a drag keeps mouse events in flight for as long as it
  /// lasts. A click resolves in Dart on the pointer up and arrives back here a
  /// frame later, by which time any pointer movement at all has replaced the
  /// event — and `NSEvent.clickCount` raises on an event that is not a mouse
  /// click, so the gesture would be dead precisely when the hand was not
  /// perfectly still. One timestamp never misses.
  private func titleBarClick() {
    let now = ProcessInfo.processInfo.systemUptime
    let isPair = now - lastTitleBarClick <= NSEvent.doubleClickInterval
    // A third click in quick succession opens a new pair rather than completing
    // a second one, which is how AppKit counts them too.
    lastTitleBarClick = isPair ? -.greatestFiniteMagnitude : now
    guard isPair else { return }

    // In full screen there is no frame to zoom out of and no dock to fall into,
    // and AppKit's own title bar answers a double click with nothing there.
    // Zooming would leave a zoomed state behind for the window to come out of.
    guard !styleMask.contains(.fullScreen) else { return }

    // `perform*` rather than `zoom(nil)` / `miniaturize(nil)`: it is the button
    // being pressed, highlight and disabled state included, which is what a
    // double click on a title bar has always been a shortcut for.
    //
    // An unrecognised value zooms. That is the default when the key has never
    // been written, and it is what the option has meant each time Apple has
    // renamed it in System Settings.
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": performMiniaturize(nil)
    case "None": break
    default: performZoom(nil)
    }
  }

  /// Centres the window buttons in the status bar.
  ///
  /// AppKit centres them in a 28 pt title bar. There is no title bar; there is
  /// a 40 pt status bar, and buttons sitting 6 pt above the row they are part
  /// of look like a bug in the row rather than a decision about the buttons.
  ///
  /// Only the vertical position moves. The horizontal one is AppKit's and is
  /// what `WindowChrome.statusBarLeading` on the Dart side leaves room for; a
  /// window whose buttons are not where every other window's are is a window
  /// people miss.
  private func alignWindowButtons() {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { self.standardWindowButton($0) }
    guard let container = buttons.first?.superview else { return }

    // Not flipped: y counts up from the bottom of the container, whose top edge
    // is the top edge of the window.
    let centre = container.bounds.height - MainFlutterWindow.statusBarHeight / 2

    for button in buttons {
      var frame = button.frame
      // Clamped, because in full screen the container is shorter than the
      // status bar and an unclamped origin would push the buttons out of it.
      frame.origin.y = max(0, (centre - frame.height / 2).rounded())
      button.frame = frame
    }
  }
}
