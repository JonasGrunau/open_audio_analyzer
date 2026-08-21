// SPDX-License-Identifier: GPL-3.0-or-later

/// Where an Android process is allowed to write, which is the one thing about
/// this platform that no environment variable answers.
///
/// Every other platform's configuration root is a pure function of the
/// environment, and `resolveConfigRoot` in `oaa_core` is that function — which
/// is what lets the `oaa` CLI, which has no Flutter binding, agree with the app
/// about where a preset lives. Android sets no `HOME`; its temporary directory
/// is `/data/local/tmp`, which belongs to no application, so the iPad's trick of
/// deriving the container from `TMPDIR` yields nothing; and the container's own
/// path contains the Android *user* — 0 on a tablet, 10 in a work profile — so
/// it cannot be guessed either. `getFilesDir()` is the only correct answer, and
/// it is a platform call.
///
/// So this asks for it, once, and hands the answer to the pure resolver.
/// **Deliberately not `path_provider`**, for the reason in that resolver's
/// header: a plugin needs a binding, and half of what reads these paths does not
/// have one. The native half is
/// `android/app/src/main/kotlin/dev/openaudioanalyzer/oaa/OaaFilesDir.kt`.
///
/// An Android tablet remembered nothing between launches for eight phases
/// because of the missing line this file replaces. It is a display: it forgot
/// which host it was showing, which tab, and every skin choice, every time it
/// was picked up.
library;

import 'package:flutter/services.dart';

/// The channel `OaaFilesDir` answers on.
const MethodChannel filesDirChannel = MethodChannel(
  'dev.openaudioanalyzer.oaa/files_dir',
);

/// `getFilesDir()`, or null if the platform will not name one.
///
/// Never throws. Null is a state Open Audio Analyzer already handles everywhere
/// — the app runs and remembers nothing, and says so at launch — and it is the
/// honest answer for a build whose runner has lost the channel, which is
/// otherwise a `MissingPluginException` on the path to the first frame.
Future<String?> androidFilesDirectory() async {
  try {
    final path = await filesDirChannel.invokeMethod<String>('path');
    return (path == null || path.isEmpty) ? null : path;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
