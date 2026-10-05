// SPDX-License-Identifier: GPL-3.0-or-later

/// The files a user picks on a tablet, which are documents and not paths.
///
/// `file_selector` cannot save on Android or iOS — `getSaveLocation` is
/// implemented by neither, so Save as, Export this tab and the report exports
/// threw and did nothing visible on both tablets — and on both its `openFile`
/// answers with a *copy* of the chosen file, so Save after Open overwrote the
/// copy and never the file. Both systems hand an application a grant rather
/// than a path: a `content://` URI from Android's Storage Access Framework, and
/// a security-scoped URL from iPadOS's document picker, which is reachable only
/// between a start and a stop of access and survives a relaunch only as a
/// bookmark. So the native halves — `android/.../OaaDocuments.kt` and
/// `ios/Runner/OaaDocuments.swift`, over one channel name — show the system's
/// picker and do the reading and the writing themselves.
///
/// **A document is carried as a string, `<handle>#<display name>`,** so it can
/// stand wherever a path stands: in `PresetDocument`, in `session.json`, and in
/// `ConfigStore.readJsonAt` and `writeJsonAt`, which recognise it with
/// [isPickedDocument] and route it here. The handle is the content URI on
/// Android and `oaa-bookmark:` plus the bookmark's base64 on iOS. The name rides
/// in the fragment because the handle does not contain it — the Downloads
/// provider answers `document/12` — and a preset is named by its file. See
/// [documentName].
library;

import 'package:flutter/services.dart';

/// The channel `OaaDocuments` answers on, on both tablets.
const MethodChannel documentsChannel = MethodChannel(
  'com.openaudioanalyzer.oaa/documents',
);

/// Whether [path] is a document from the system picker rather than a file.
bool isPickedDocument(String path) =>
    path.startsWith('content://') || path.startsWith('oaa-bookmark:');

/// The name a user would recognise [path] by: the document's display name, or
/// the file's last path component.
String documentName(String path, {String separator = '/'}) {
  if (isPickedDocument(path)) {
    final hash = path.lastIndexOf('#');
    if (hash < 0) return path;
    try {
      return Uri.decodeComponent(path.substring(hash + 1));
    } on ArgumentError {
      return path.substring(hash + 1);
    }
  }
  return path.split(separator).last;
}

/// A read or a write the system refused, with its reason.
class DocumentException implements Exception {
  const DocumentException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract final class PickedDocuments {
  /// Shows the system's save picker. The new document, or null if dismissed.
  ///
  /// The document exists, empty, once this answers; the caller writes it.
  static Future<String?> create({
    required String suggestedName,
    required String mimeType,
  }) => _pick('create', {'name': suggestedName, 'mime': mimeType});

  /// Shows the system's open picker. The document, or null if dismissed.
  static Future<String?> open() => _pick('open', const {});

  static Future<Uint8List> read(String path) async {
    final bytes = await _call<Uint8List>('read', {'path': path});
    return bytes ?? Uint8List(0);
  }

  static Future<void> write(String path, List<int> bytes) =>
      _call<void>('write', {'path': path, 'bytes': Uint8List.fromList(bytes)});

  /// Whether [path] still answers. False on anything that cannot be told —
  /// a deleted document and a revoked grant both mean the same thing to Save.
  static Future<bool> exists(String path) async {
    try {
      return await _call<bool>('exists', {'path': path}) ?? false;
    } on DocumentException {
      return false;
    }
  }

  static Future<String?> _pick(String method, Map<String, Object?> args) async {
    try {
      return await documentsChannel.invokeMethod<String>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await documentsChannel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      throw DocumentException(error.message ?? error.code);
    } on MissingPluginException {
      throw const DocumentException('This build cannot reach the document.');
    }
  }
}
