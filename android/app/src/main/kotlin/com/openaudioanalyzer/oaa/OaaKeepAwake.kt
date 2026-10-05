// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the screen on while this tablet is somebody else's display.
 *
 * A display is a screen nobody touches. That is the point of it — it stands on
 * a desk across the room showing the meters of a machine somebody else is
 * working at — and it is exactly the screen Android's idle timeout turns off,
 * because nothing has pressed it for a minute. The person who asked for this
 * did not want to change the system setting back and forth, and they were
 * right not to: the application knows when it is a display and the system
 * does not.
 *
 * `FLAG_KEEP_SCREEN_ON` rather than a `PowerManager` wake lock. The flag
 * belongs to the window, so it needs no permission, it cannot outlive the
 * activity that set it, and the system drops it by itself the moment the
 * application goes to the background — a wake lock that a crash forgot to
 * release keeps the screen on until the battery says otherwise. The cost is
 * that it needs the activity, which is why this is [ActivityAware] the way
 * [OaaMicPermission] is.
 *
 * The flag is **re-applied on a new activity**. A rotation destroys the window
 * it was set on, and a tablet on a stand is the device most likely to be
 * turned once it is on the stand; a flag set before that and lost with the old
 * window would put the screen to sleep on exactly the person who had asked it
 * not to.
 */
class OaaKeepAwake : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

  private companion object {
    /** Must match `keepAwakeChannel` in `lib/src/remote/keep_awake.dart`. */
    const val CHANNEL = "com.openaudioanalyzer.oaa/keep_awake"
  }

  private var channel: MethodChannel? = null
  private var activity: Activity? = null

  /** What Dart last asked for, so a new window can be given the same answer. */
  private var wanted = false

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    apply()
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "set" -> {
        wanted = call.argument<Boolean>("on") == true
        apply()
        result.success(activity != null)
      }
      else -> result.notImplemented()
    }
  }

  /** On the UI thread, which is the only thread a window's flags may be set from. */
  private fun apply() {
    val activity = activity ?: return
    val on = wanted
    activity.runOnUiThread {
      if (on) {
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
      } else {
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
      }
    }
  }
}
