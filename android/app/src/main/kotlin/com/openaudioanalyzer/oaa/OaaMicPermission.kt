// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Asks for the microphone, so that Android can measure a live input at all.
 *
 * **This is the whole reason there was no input on Android.** The engine is
 * compiled for this platform with miniaudio in it, the canvas and the fourteen
 * modules are the same code the desktop runs, and every one of them worked —
 * against a device that never opened, because `RECORD_AUDIO` was not declared
 * and is not grantable without asking. miniaudio surfaces that as a device it
 * cannot start, which reaches the user as `_EngineFailure`'s sentence about an
 * interface being unplugged. Nothing said "permission" anywhere, which is why
 * the platform was described as display-only for a phase.
 *
 * The manifest entry is necessary and not sufficient: `RECORD_AUDIO` is a
 * *dangerous* permission, so it is granted by the user at runtime and not by
 * the install. That request needs an `Activity`, which is why this is
 * [ActivityAware] where [OaaMulticastLock] is not — a `MulticastLock` comes off
 * the application context and outlives any activity, and holding one against an
 * activity leaks it across a rotation. Here the opposite is true: without the
 * activity there is nobody to show the dialog and the request cannot be made.
 *
 * Asked when somebody chooses an input, never at launch. A tablet on a stand
 * mirroring another machine's meters has no use for a microphone and is never
 * asked for one — and a permission dialog in the first second of the first run,
 * before the application has shown what it is for, is the one most likely to be
 * refused.
 *
 * A refusal is a value and not an error: it is an answer to the question, and
 * the caller's next move is the same whether the user said no once or has
 * checked "don't ask again". `shouldShowRequestPermissionRationale` is
 * deliberately not consulted — the honest reading of it needs to be taken
 * *before* the first request to be meaningful, and what the Dart side does with
 * a refusal (say so, and leave the previous source running) does not change
 * with the reason.
 */
class OaaMicPermission :
  FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

  private companion object {
    /** Must match `micPermissionChannel` in `data/mic_permission.dart`. */
    const val CHANNEL = "com.openaudioanalyzer.oaa/mic_permission"

    /** Any value; it comes back in [onRequestPermissionsResult] to identify us. */
    const val REQUEST_CODE = 4823
  }

  private var channel: MethodChannel? = null
  private var binding: ActivityPluginBinding? = null

  /**
   * The call still waiting on a dialog, or null.
   *
   * At most one: the Dart side awaits its answer before asking again, and a
   * second [MethodChannel.Result] completed by the same system callback would
   * be a reply to a question nobody asked. A second request while one is open
   * is refused rather than queued.
   */
  private var pending: MethodChannel.Result? = null

  private val listener =
    PluginRegistry.RequestPermissionsResultListener { code, _, grants ->
      if (code != REQUEST_CODE) return@RequestPermissionsResultListener false
      // An empty array is Android saying the request was cancelled — a dialog
      // dismissed by a back press, or interrupted by the system. Not a
      // refusal, but not a grant either, and the caller treats it as "no" for
      // this attempt and may ask again next time an input is chosen.
      val granted =
        grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED
      pending?.success(granted)
      pending = null
      true
    }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // A `Result` that is never completed hangs the Dart future for the life of
    // the process. The engine going away is exactly when that would happen.
    pending?.success(false)
    pending = null
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.binding = binding.also { it.addRequestPermissionsResultListener(listener) }
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    // A rotation detaches the activity with a dialog on screen. The listener
    // goes with it, so the answer would never arrive; the caller is told no and
    // asks again on the next attempt rather than waiting forever.
    pending?.success(false)
    pending = null
    binding?.removeRequestPermissionsResultListener(listener)
    binding = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "has" -> result.success(granted())
      "request" -> request(result)
      else -> result.notImplemented()
    }
  }

  private fun granted(): Boolean {
    val activity = binding?.activity ?: return false
    return ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
      PackageManager.PERMISSION_GRANTED
  }

  private fun request(result: MethodChannel.Result) {
    if (granted()) {
      result.success(true)
      return
    }

    if (pending != null) {
      result.error(
        "mic-request-in-flight",
        "A microphone request is already open.",
        null,
      )
      return
    }

    val activity: Activity = binding?.activity
      // No activity means no dialog. The engine is attached and the activity is
      // not, which happens between a launch and the first frame.
      ?: run {
        result.success(false)
        return
      }

    pending = result
    ActivityCompat.requestPermissions(
      activity,
      arrayOf(Manifest.permission.RECORD_AUDIO),
      REQUEST_CODE,
    )
  }
}
