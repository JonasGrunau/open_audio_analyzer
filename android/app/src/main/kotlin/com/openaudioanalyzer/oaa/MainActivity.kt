// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Registers Open Audio Analyzer's own five channels alongside the generated
 * ones.
 *
 * The first three exist for the same reason: Android is the platform where
 * things the rest of the application takes from the environment are not in it.
 * Multicast arrives only while a `WifiManager.MulticastLock` is held, the
 * directory this app may write to is not derivable from any variable it is
 * given, and the microphone is not openable until the user has been asked for
 * it in a dialog. Each is one platform call, and each has a file saying what
 * breaks without it — `OaaMulticastLock.kt`, `OaaFilesDir.kt` and
 * `OaaMicPermission.kt`.
 *
 * They are the same failure shape three times over: the capability is *absent*
 * rather than broken, every call below it succeeds, and nothing is logged. Two
 * of the three shipped missing.
 *
 * The fourth is a different kind of thing: `OaaKeepAwake.kt` keeps the screen
 * on while the tablet is a display, which Flutter has no way to ask for. The
 * fifth, `OaaDocuments.kt`, opens and saves the files a user picks through the
 * system's own picker, because `file_selector` cannot save on Android and opens
 * a copy rather than the file.
 */
class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    // The generated registrant first; ours are additions to it, not a
    // replacement for it.
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(OaaMulticastLock())
    flutterEngine.plugins.add(OaaFilesDir())
    flutterEngine.plugins.add(OaaMicPermission())
    flutterEngine.plugins.add(OaaKeepAwake())
    flutterEngine.plugins.add(OaaDocuments())
  }
}
