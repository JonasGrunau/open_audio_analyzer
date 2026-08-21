// SPDX-License-Identifier: GPL-3.0-or-later

package dev.openaudioanalyzer.oaa

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Lets Open Audio Analyzer receive multicast DNS on Android.
 *
 * **This is the whole reason discovery did not work here.** The socket in
 * `lib/src/remote/mdns/mdns_service.dart` binds on Android, joins 224.0.0.251
 * and sends its query perfectly; what it never gets is an answer, because the
 * Wi-Fi driver drops every multicast packet not addressed to this device unless
 * somebody holds a [WifiManager.MulticastLock]. Nothing logs that and no call
 * fails — the browse simply sits there, which is how it shipped for eight
 * phases under a panel that said "Looking for hosts on this network…".
 *
 * `CHANGE_WIFI_MULTICAST_STATE` in the manifest is necessary and not
 * sufficient: it is what allows the lock to be taken, and it is an install-time
 * permission, so there is no dialog and nothing to ask the user for. Taking the
 * lock is a platform call, which is why this file exists rather than more Dart.
 * `NEARBY_WIFI_DEVICES` is **not** required — that covers the APIs that manage
 * or scan Wi-Fi networks, not multicast delivery, and asking for it would put a
 * nearby-devices prompt in front of a metering tool that never learns where it
 * is.
 *
 * The lock is not reference counted *here*. Dart holds it for as long as
 * somebody is searching and gives it back when the last searcher stops — see
 * `MulticastLock` in `lib/src/remote/mdns/multicast_lock.dart` — so this side
 * only has to be idempotent, and a non-counted lock is the one that cannot
 * drift out of step with a caller that crashed. `release` on a lock that is not
 * held would throw, so it is asked whether it is.
 *
 * Held only while a search is running, which matters: the lock ends multicast
 * filtering for the whole device, and that costs battery on a tablet whose only
 * job is to sit on a stand showing meters.
 */
class OaaMulticastLock : FlutterPlugin, MethodChannel.MethodCallHandler {
  /** Must match `multicastLockChannel` in `mdns/multicast_lock.dart`. */
  private companion object {
    const val CHANNEL = "dev.openaudioanalyzer.oaa/multicast_lock"

    /** What `dumpsys wifi` shows while this is held. */
    const val TAG = "Open Audio Analyzer mDNS"
  }

  private var channel: MethodChannel? = null
  private var wifi: WifiManager? = null
  private var lock: WifiManager.MulticastLock? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // The application context, not the activity's: a WifiManager outlives every
    // activity that asks for one, and holding it against one leaks the
    // activity across a rotation.
    wifi =
      binding.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // The Dart side releases what it took, but a hot restart or a killed engine
    // never gets to: the lock would then be held by a process with nothing
    // listening for as long as it lives.
    release()
    channel?.setMethodCallHandler(null)
    channel = null
    wifi = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "acquire" -> {
        val failure = acquire()
        if (failure == null) result.success(null)
        // A failure is reported as an error rather than as a value, so that a
        // channel that is not there at all and a lock that cannot be taken
        // arrive at the same `catch` in Dart. The message is shown to a person.
        else result.error("multicast-lock-unavailable", failure, null)
      }
      "release" -> {
        release()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  /** Null once the lock is held; otherwise a sentence for the panel. */
  private fun acquire(): String? {
    lock?.let { if (it.isHeld) return null }

    val manager = wifi
      // A device with no Wi-Fi hardware at all — an emulator image without it,
      // a set-top box on Ethernet. Ethernet does not filter multicast, so the
      // browse is worth running anyway; the caller says so and carries on.
      ?: return "This device has no Wi-Fi, so Open Audio Analyzer cannot lift " +
        "multicast filtering. Discovery works over Ethernet; otherwise enter " +
        "an address below."

    return try {
      val held = lock ?: manager.createMulticastLock(TAG).also {
        it.setReferenceCounted(false)
        lock = it
      }
      held.acquire()
      null
    } catch (error: Exception) {
      // `SecurityException` if the manifest permission ever goes missing, and
      // whatever an OEM Wi-Fi stack decides to throw. Either way the search can
      // still be attempted and will find nothing, so this has to reach the
      // panel as words.
      "Android is not letting Open Audio Analyzer receive multicast " +
        "(${error.javaClass.simpleName}). Enter an address below."
    }
  }

  private fun release() {
    val held = lock ?: return
    try {
      if (held.isHeld) held.release()
    } catch (_: Exception) {
      // Nothing to do about a lock that will not be given back, and nothing
      // that depends on it: the process exiting releases it.
    }
  }
}
