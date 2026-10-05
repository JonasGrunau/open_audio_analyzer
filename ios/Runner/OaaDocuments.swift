import Flutter
import UIKit
import UniformTypeIdentifiers

/// Opens and saves documents the user chooses, through the system's own picker.
///
/// **`file_selector` cannot save on iPadOS at all.** `getSaveLocation` is not
/// implemented by `file_selector_ios`, so Save as, Export this tab and every
/// report export threw on an iPad and did nothing a user could see. Its
/// `openFile` picks *as a copy*, so a preset opened and then saved was written
/// over that copy in the container and never reached the file in Files.
///
/// What iPadOS hands an application is a security-scoped URL: reachable only
/// between `startAccessingSecurityScopedResource` and its stop, and kept across
/// a relaunch only as a bookmark. So this keeps the bookmark and does the I/O
/// itself, with the Android half's channel and methods — see
/// `lib/src/storage/picked_documents.dart`. A document crosses as
/// `oaa-bookmark:<base64>#<display name>`.
///
/// **Save is an export of an empty file.** The picker has no "choose where to
/// create" mode; `forExporting` moves a file that exists. So `create` writes an
/// empty one under the suggested name into the temporary directory, exports it,
/// and answers with the destination — which the Dart side writes the moment it
/// arrives, as it does on Android.
///
/// Writes go through an `NSFileCoordinator`, because a document in iCloud Drive
/// is also being written by the system's own daemon, and are not atomic: a
/// scope granted to one file does not extend to a sibling to rename from.
final class OaaDocuments: NSObject, UIDocumentPickerDelegate {
  /// Must match `documentsChannel` in `lib/src/storage/picked_documents.dart`.
  static let channelName = "com.openaudioanalyzer.oaa/documents"
  static let scheme = "oaa-bookmark:"

  /// The picker holds its delegate weakly; this is what keeps it alive.
  private static var shared: OaaDocuments?

  /// The picker still on screen, or nil. One at a time.
  private var pending: FlutterResult?
  private var exporting: URL?
  private let io = DispatchQueue(label: "com.openaudioanalyzer.oaa.documents")

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = OaaDocuments()
    shared = instance
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in instance.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      create(name: args["name"] as? String ?? "Untitled", result)
    case "open":
      present(
        UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false),
        result)
    case "read":
      access(args, result) { url in
        var data = Data()
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) {
          do { data = try Data(contentsOf: $0) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return FlutterStandardTypedData(bytes: data)
      }
    case "write":
      let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
      access(args, result) { url in
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(
          writingItemAt: url, options: .forReplacing, error: &coordination
        ) {
          do { try bytes.write(to: $0) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return nil
      }
    case "exists":
      access(args, { value in
        // A bookmark that no longer resolves is the same answer as a file
        // that has gone: Save must ask where to go.
        result(value is FlutterError ? false : value)
      }) { url in FileManager.default.fileExists(atPath: url.path) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(name: String, _ result: @escaping FlutterResult) {
    let safe = name.replacingOccurrences(of: "/", with: "-")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = folder.appendingPathComponent(safe.isEmpty ? "Untitled" : safe)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data().write(to: file)
    } catch {
      result(nil)
      return
    }
    exporting = folder
    present(UIDocumentPickerViewController(forExporting: [file], asCopy: false), result)
  }

  private func present(_ picker: UIDocumentPickerViewController, _ result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "picker-in-flight", message: "A document picker is already open.", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(nil)
      return
    }
    pending = result
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func finish(_ url: URL?) {
    let result = pending
    pending = nil
    if let folder = exporting {
      try? FileManager.default.removeItem(at: folder)
      exporting = nil
    }
    guard let url else {
      result?(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let bookmark = try? url.bookmarkData() else {
      result?(nil)
      return
    }
    let name = url.lastPathComponent
      .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["#", "/"])) ?? ""
    result?("\(Self.scheme)\(bookmark.base64EncodedString())#\(name)")
  }

  /// Resolves the call's bookmark, runs [work] inside its scope off the main
  /// thread, and answers on the main thread.
  private func access(
    _ args: [String: Any], _ result: @escaping FlutterResult, _ work: @escaping (URL) throws -> Any?
  ) {
    guard
      let path = args["path"] as? String, path.hasPrefix(Self.scheme),
      let data = Data(base64Encoded: String(
        path.dropFirst(Self.scheme.count).prefix { $0 != "#" }))
    else {
      result(FlutterError(code: "document", message: "Not a document.", details: nil))
      return
    }
    io.async {
      var answer: Any?
      do {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        answer = try work(url)
      } catch {
        answer = FlutterError(code: "document", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }
}
