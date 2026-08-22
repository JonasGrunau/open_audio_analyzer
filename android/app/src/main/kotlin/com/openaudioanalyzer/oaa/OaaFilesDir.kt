// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Tells Open Audio Analyzer where its files live on Android.
 *
 * **The one thing an Android process cannot work out for itself.** Every other
 * platform's configuration directory is derivable from the environment —
 * `HOME`, `APPDATA`, `XDG_CONFIG_HOME`, or on an iPad the container the
 * temporary directory sits in — and `resolveConfigRoot` in `oaa_core` is a pure
 * function because of it. Android sets no `HOME`, and its temporary directory
 * is `/data/local/tmp`, which belongs to no application and is not writable by
 * one, so the iPad's trick does not work either. `getFilesDir()` is the answer
 * and it is only reachable through a platform call, which is why this file
 * exists; the resolver stays pure and is handed the path.
 *
 * That is not the same as calling `path_provider`. The paths have to agree
 * between the app, a unit test and the `oaa` CLI, and the CLI has no Flutter
 * binding at all — see the header of `packages/oaa_core/lib/src/config_locations.dart`.
 * This channel answers one question on one platform; the rules about what is
 * then put where stay in one pure function.
 *
 * Internal storage, not external: this is the tablet's own copy of a layout and
 * a skin, nobody else on the device has any business reading it, and it needs
 * no permission of any kind.
 */
class OaaFilesDir : FlutterPlugin, MethodChannel.MethodCallHandler {
  /** Must match `filesDirChannel` in `lib/src/storage/android_files_dir.dart`. */
  private companion object {
    const val CHANNEL = "com.openaudioanalyzer.oaa/files_dir"
  }

  private var channel: MethodChannel? = null
  private var path: String? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    path = binding.applicationContext.filesDir?.absolutePath
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    path = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // Null rather than an error when the platform will not name one, which
      // is what the Dart side already does with every other environment that
      // offers nowhere to write: the app runs and remembers nothing, and says
      // so at launch.
      "path" -> result.success(path)
      else -> result.notImplemented()
    }
  }
}
