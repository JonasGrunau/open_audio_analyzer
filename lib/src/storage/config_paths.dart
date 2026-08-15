// SPDX-License-Identifier: GPL-3.0-or-later

/// Where Bel keeps the things it remembers.
///
/// The resolution below is written out by hand rather than delegated to
/// `path_provider`, and the reason is not purity. `path_provider` is a Flutter
/// plugin: it needs a `WidgetsBinding` and a platform channel, so it throws in
/// exactly the two places Bel most needs these paths — the `bel analyze` CLI,
/// which is a plain Dart entrypoint with no engine attached, and a unit test.
/// Both have to read the same presets and the same calibrations as the app, and
/// a second implementation of "where the config lives" is a second answer that
/// will drift from the first.
///
/// It also names the conventional directory on each platform explicitly, rather
/// than asking `path_provider` for one, so that the CLI and the app cannot
/// disagree about where a preset lives.
///
/// **These paths are only true because the macOS app is not sandboxed.** A
/// sandboxed app has its `HOME` redirected into
/// `~/Library/Containers/<bundle id>/Data`, so every path below would silently
/// resolve inside a container that no user goes looking in and that
/// [kConfigDirEnvVar] cannot escape. `macos/Runner/*.entitlements` therefore
/// omits `com.apple.security.app-sandbox` deliberately, and says why. The code
/// here needs no knowledge of that — it uses whatever `HOME` the process was
/// given — which is exactly why the decision has to be defended in the
/// entitlements rather than here.
///
/// **iPadOS is the one platform where the environment answers nothing.** An iOS
/// process gets a data container and no usable `HOME`, so the Unix branch below
/// resolved to null on an iPad and the app opened with a "no configuration
/// directory" notice and remembered nothing between launches. `TMPDIR` *is*
/// set, and it is the container's own `tmp`, so the container is one path
/// component up from the temporary directory — which is why [resolveConfigRoot]
/// takes that directory as an argument. It is the only value that identifies
/// the container without a platform channel, and a platform channel is
/// `path_provider`, which the first paragraph rules out.
library;

/// The environment variable that overrides the platform's convention.
///
/// For tests, for portable installs on a USB stick, and for anybody who keeps
/// their dotfiles in a repository and wants Bel's config alongside them.
///
/// Subject to the platform's own file access: it can only name a directory the
/// process is allowed to read. That is unrestricted today on all three desktop
/// platforms, and would stop being true on macOS the moment anybody re-enabled
/// the sandbox.
///
/// **`--config-dir` exists as well, and beats this.** Not redundancy: handing an
/// environment variable to a Mac application means launching the binary inside
/// the bundle, which changes how TCC attributes the microphone request — so this
/// variable and device capture could not be used in the same launch. See
/// `lib/src/app/launch_options.dart`.
const String kConfigDirEnvVar = 'BEL_CONFIG_DIR';

/// The configuration root for [operatingSystem], as a path string.
///
/// Pure: it reads nothing and creates nothing, which is what makes all three
/// platforms testable from any one of them, and what lets the `bel` CLI call it
/// with no Flutter binding. [operatingSystem] takes the values
/// `Platform.operatingSystem` produces, and [override] arrives from the
/// `--config-dir` flag — passed *in* rather than read here, so that the
/// precedence between flag, environment and convention is visible in one place
/// and this function still reads nothing.
///
/// Returns null when the environment gives it nothing to work with — no `HOME`
/// on a Unix, no `APPDATA` on Windows. That happens in stripped service
/// environments and in some CI containers, and it is a legitimate state rather
/// than an error: Bel runs perfectly well without persistence, it just does not
/// remember anything. Guessing `/` and failing at write time instead would be
/// worse.
///
/// [temporaryDirectory] is `Directory.systemTemp.path`, and is read by the iOS
/// branch alone — see the library comment. Passing it in rather than reading it
/// keeps this function free of `dart:io` and lets a test on any platform
/// exercise an iPad's paths, which is otherwise a device build away.
String? resolveConfigRoot({
  required String operatingSystem,
  required Map<String, String> environment,
  String? override,
  String? temporaryDirectory,
}) {
  // The flag beats the environment variable, which beats the platform. A flag
  // is typed for this launch and an environment variable is usually inherited
  // from a shell profile, so the more deliberate of the two wins.
  if (override != null && override.isNotEmpty) return override;

  final fromEnvironment = environment[kConfigDirEnvVar];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }

  switch (operatingSystem) {
    case 'windows':
      final appData = environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return '$appData\\Bel';

    case 'macos':
      final home = environment['HOME'];
      if (home == null || home.isEmpty) return null;
      // The platform convention, and where an unsandboxed app's HOME actually
      // points — see the library comment on why that second half is not free.
      return '$home/Library/Application Support/Bel';

    case 'ios':
      // `HOME` is deliberately not consulted. It is either absent — which is
      // what an iPad actually does, and what made this branch necessary — or
      // pointing at `/var/mobile`, which the app may not write to. Both fail,
      // and the second fails as a permission error at save time rather than as
      // a notice at launch. The container is the only place there is.
      final container = _containerOf(temporaryDirectory);
      if (container == null) return null;
      // Apple's own convention, and the same shape as the macOS row above.
      // Nothing here is user-visible: an iPad shows its configuration through
      // Settings → Session, not through the Files app.
      return '$container/Library/Application Support/Bel';

    // Linux and anything else Unix-shaped — including Android, which has no
    // `HOME` either and therefore no configuration directory. Its container is
    // not derivable the way iOS's is: Dart's temporary directory there is
    // `/data/local/tmp`, which belongs to no app and is not writable by one.
    // An Android tablet is a display and persists nothing; giving it a
    // configuration means a platform channel to `getFilesDir()`.
    //
    // XDG first, because a user who has set XDG_CONFIG_HOME has said where
    // they want this.
    default:
      final xdg = environment['XDG_CONFIG_HOME'];
      if (xdg != null && xdg.isNotEmpty) return '$xdg/bel';
      final home = environment['HOME'];
      if (home == null || home.isEmpty) return null;
      return '$home/.config/bel';
  }
}

/// The data container [temporaryDirectory] belongs to, or null if it is not
/// inside one.
///
/// An iOS app's `TMPDIR` is `<container>/tmp`, so the container is the parent.
/// The check that the last component really is `tmp` is not defensive
/// programming: a process whose `TMPDIR` is unset gets `/tmp`, whose parent is
/// `/`, and returning that would put the configuration root at
/// `/Library/Application Support/Bel` — a path outside the sandbox that fails
/// at write time with a permission error, which reads like a broken install
/// rather than an environment Bel cannot place anything in.
String? _containerOf(String? temporaryDirectory) {
  if (temporaryDirectory == null) return null;

  var path = temporaryDirectory;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  final separator = path.lastIndexOf('/');
  // `/tmp`, or a relative path. Neither names a container.
  if (separator <= 0) return null;
  if (path.substring(separator + 1) != 'tmp') return null;

  return path.substring(0, separator);
}

/// The subdirectories under the root.
///
/// One file per preset, per calibration and per skin rather than one document
/// containing all of them. That is a deliberate trade: a single `presets.json`
/// is one atomic write and slightly less code, but it also means a user cannot
/// send somebody a preset without extracting it by hand, cannot drop one in
/// from a forum post, and loses every preset they own to one corrupted file.
/// A directory of small documents is the format that survives a text editor.
abstract final class ConfigDir {
  static const String presets = 'presets';
  static const String calibrations = 'calibrations';
  static const String skins = 'skins';
}

/// Files that live directly in the root.
abstract final class ConfigFile {
  static const String settings = 'settings.json';

  /// The canvas as it was left, autosaved.
  ///
  /// Separate from the preset library on purpose. A working layout is not a
  /// preset until somebody names it, and silently mutating the preset a user
  /// loaded — because they dragged a module while checking something — is how
  /// a preset library becomes untrustworthy.
  static const String session = 'session.json';
}

/// A filename-safe form of [name], for a preset or skin the user just named.
///
/// Not reversible and not meant to be: the id inside the document is the
/// identity, this only decides what the file is called. Everything outside a
/// conservative set becomes `-`, because these strings reach three filesystems
/// with three different opinions and one of them reserves `CON`, `AUX` and a
/// trailing dot.
String slugify(String name) {
  final buffer = StringBuffer();
  var lastWasDash = false;

  for (final rune in name.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final isSafe =
        (rune >= 0x61 && rune <= 0x7A) || // a-z
        (rune >= 0x30 && rune <= 0x39); // 0-9

    if (isSafe) {
      buffer.write(char);
      lastWasDash = false;
    } else if (!lastWasDash && buffer.isNotEmpty) {
      buffer.write('-');
      lastWasDash = true;
    }
  }

  var slug = buffer.toString();
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }

  // Everything was punctuation, or the name was empty. "untitled" is a
  // filename; the empty string is a bug that shows up as a hidden file.
  if (slug.isEmpty) return 'untitled';

  // Long names come from "Copy of Copy of …". 64 characters is well inside
  // every filesystem's limit and still readable in a directory listing.
  return slug.length > 64 ? slug.substring(0, 64) : slug;
}
