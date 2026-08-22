// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Registers Open Audio Analyzer's own two channels alongside the generated
 * ones.
 *
 * Both exist for the same reason: Android is the platform where two things the
 * rest of the application takes from the environment are not in it. Multicast
 * arrives only while a `WifiManager.MulticastLock` is held, and the directory
 * this app may write to is not derivable from any variable it is given. Each is
 * one platform call, and each has a file saying what breaks without it —
 * `OaaMulticastLock.kt` and `OaaFilesDir.kt`.
 */
class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    // The generated registrant first; ours are additions to it, not a
    // replacement for it.
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(OaaMulticastLock())
    flutterEngine.plugins.add(OaaFilesDir())
  }
}
