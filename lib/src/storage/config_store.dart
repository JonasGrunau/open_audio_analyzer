// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oaa_core/oaa_core.dart';

/// A JSON document as it was found on disk, with the file it came from.
///
/// The filename is carried alongside rather than derived from the document,
/// because the two can disagree — a user renames `spotify.json` to
/// `mastering.json` without touching the `id` inside it, and deleting the
/// preset has to remove the file that actually exists.
typedef StoredJson = ({String fileName, Map<String, Object?> json});

/// Reads and writes everything Open Audio Analyzer remembers.
///
/// Three properties, each of which is there because of a specific way
/// persistence layers fail:
///
/// **Writes are atomic.** Every write goes to a temporary file and is renamed
/// over the target, so a crash or a power cut during a save leaves the previous
/// version intact rather than a half-written one. The failure this prevents is
/// the worst one available here — a user loses not the last edit but the entire
/// preset, and they find out at the moment they try to open it.
///
/// **Nothing here throws.** A read that fails returns null, a write that fails
/// returns false, and the reason lands in [lastError] for the interface to
/// show. A metering session that has been running for three hours must not end
/// because a config directory went read-only.
///
/// **Session saves are debounced.** The canvas commits a layout on every drag,
/// resize and option change; without [scheduleWrite] a user rearranging a tab
/// would issue a hundred small writes in a few seconds. [flush] exists for
/// shutdown, when the pending one has to land before the process goes away.
class ConfigStore {
  ConfigStore._(this.root, this._error);

  /// Opens the store for the current platform.
  ///
  /// [operatingSystem] and [environment] are injectable so that a test can
  /// exercise every platform's path rules from any one of them, and so that the
  /// whole suite can point at a temporary directory. [configDir] is the
  /// `--config-dir` flag and beats both.
  ///
  /// `Directory.systemTemp` is read here rather than in [resolveConfigRoot]
  /// because that function reads nothing. It is the iPad's container — see
  /// `config_paths.dart` — and is ignored on every other platform.
  static Future<ConfigStore> open({
    String? operatingSystem,
    Map<String, String>? environment,
    String? configDir,
  }) async {
    final path = resolveConfigRoot(
      operatingSystem: operatingSystem ?? Platform.operatingSystem,
      environment: environment ?? Platform.environment,
      override: configDir,
      temporaryDirectory: Directory.systemTemp.path,
    );

    if (path == null) {
      return ConfigStore._(
        null,
        'No configuration directory: neither --config-dir nor '
        '$kConfigDirEnvVar nor a location this platform offers. Settings and '
        'presets will not be saved this session.',
      );
    }

    final directory = Directory(path);
    try {
      await directory.create(recursive: true);
    } on FileSystemException catch (error) {
      return ConfigStore._(
        null,
        'Could not create $path: ${error.osError?.message ?? error.message}',
      );
    }

    return ConfigStore._(directory, null);
  }

  /// A store that persists nothing.
  ///
  /// For tests and for the case above where the environment offers nowhere to
  /// write. Everything still works; nothing is remembered.
  factory ConfigStore.disabled() =>
      ConfigStore._(null, 'Persistence is disabled.');

  /// Where everything lives. Null when persistence is unavailable.
  final Directory? root;

  String? _error;

  /// Why the last operation failed, or null. Cleared by the next success.
  String? get lastError => _error;

  bool get isAvailable => root != null;

  final Map<String, Timer> _pending = {};
  final Map<String, Map<String, Object?>> _pendingContent = {};

  /// How long a debounced write waits for the drag to finish.
  ///
  /// Long enough that a continuous rearrangement writes once at the end of it,
  /// short enough that a user who quits by force-killing the window a second
  /// after their last edit still keeps it.
  static const Duration writeDelay = Duration(milliseconds: 600);

  // --- Reading ------------------------------------------------------------

  /// Reads one document, or null if it is absent, unreadable or not a JSON
  /// object.
  Future<Map<String, Object?>?> readJson(String relativePath) async {
    final file = _file(relativePath);
    if (file == null) return null;

    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        _error = '${file.path} is not a JSON object.';
        return null;
      }
      _error = null;
      return decoded.cast<String, Object?>();
    } on FormatException catch (error) {
      // A hand-edited file with a trailing comma. Naming the file is the whole
      // value of this message — the user can go and fix it.
      _error = 'Could not parse ${file.path}: ${error.message}';
      return null;
    } on FileSystemException catch (error) {
      _error =
          'Could not read ${file.path}: '
          '${error.osError?.message ?? error.message}';
      return null;
    }
  }

  /// Reads every `.json` document in a subdirectory, in filename order.
  ///
  /// Files that fail to parse are skipped rather than failing the batch: one
  /// broken skin must not cost the user their other nine.
  Future<List<StoredJson>> readDirectory(String directoryName) async {
    final base = root;
    if (base == null) return const [];

    final directory = Directory(
      '${base.path}${Platform.pathSeparator}'
      '$directoryName',
    );
    if (!await directory.exists()) return const [];

    final results = <StoredJson>[];
    try {
      final entries = await directory.list(followLinks: false).toList();
      entries.sort((a, b) => a.path.compareTo(b.path));

      for (final entry in entries) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final name = entry.uri.pathSegments.last;
        final json = await readJson('$directoryName/$name');
        if (json != null) results.add((fileName: name, json: json));
      }
    } on FileSystemException catch (error) {
      _error =
          'Could not list ${directory.path}: '
          '${error.osError?.message ?? error.message}';
    }

    return results;
  }

  // --- Writing ------------------------------------------------------------

  /// Writes a document atomically. Returns false if it could not be written.
  Future<bool> writeJson(String relativePath, Map<String, Object?> json) async {
    final file = _file(relativePath);
    if (file == null) return false;

    // Indented on purpose. These files are meant to be opened, read and edited
    // by hand — that is the entire argument for JSON over anything binary —
    // and a single-line document is not.
    final text = const JsonEncoder.withIndent('  ').convert(json);
    final temporary = File('${file.path}.tmp');

    try {
      await file.parent.create(recursive: true);
      await temporary.writeAsString(text, flush: true);

      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Windows will not always rename over an existing file. Removing the
        // target first opens a window where neither exists, which is why it is
        // the fallback and not the method.
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }

      _error = null;
      return true;
    } on FileSystemException catch (error) {
      _error =
          'Could not write ${file.path}: '
          '${error.osError?.message ?? error.message}';
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // Nothing useful to do, and the caller already has the real error.
        }
      }
      return false;
    }
  }

  /// Queues a write, replacing any write already queued for the same path.
  ///
  /// Fire-and-forget by design: the caller is a canvas edit, and a layout
  /// autosave that a user has to wait for is a layout autosave that stutters
  /// the meters.
  void scheduleWrite(String relativePath, Map<String, Object?> json) {
    if (root == null) return;

    _pendingContent[relativePath] = json;
    _pending[relativePath]?.cancel();
    _pending[relativePath] = Timer(writeDelay, () {
      final content = _pendingContent.remove(relativePath);
      _pending.remove(relativePath);
      if (content != null) unawaited(writeJson(relativePath, content));
    });
  }

  /// Writes everything queued, now. Call before the process exits.
  Future<void> flush() async {
    final paths = _pending.keys.toList();
    for (final path in paths) {
      _pending.remove(path)?.cancel();
      final content = _pendingContent.remove(path);
      if (content != null) await writeJson(path, content);
    }
  }

  Future<bool> delete(String relativePath) async {
    final file = _file(relativePath);
    if (file == null) return false;

    _pending.remove(relativePath)?.cancel();
    _pendingContent.remove(relativePath);

    try {
      if (await file.exists()) await file.delete();
      _error = null;
      return true;
    } on FileSystemException catch (error) {
      _error =
          'Could not delete ${file.path}: '
          '${error.osError?.message ?? error.message}';
      return false;
    }
  }

  /// Cancels pending writes without performing them. For teardown in tests.
  void dispose() {
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
    _pendingContent.clear();
  }

  File? _file(String relativePath) {
    final base = root;
    if (base == null) return null;
    // Forward slashes in the relative paths this class is called with; the
    // platform separator only matters for the part that came from the
    // environment.
    final parts = relativePath.split('/');
    return File([base.path, ...parts].join(Platform.pathSeparator));
  }
}
