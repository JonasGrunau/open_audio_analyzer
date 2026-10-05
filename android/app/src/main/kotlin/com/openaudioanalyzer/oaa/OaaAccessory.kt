// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.Socket

/**
 * A desktop on a USB cable with no USB debugging: the Android accessory.
 *
 * A publishing desktop finds this tablet on the bus and asks it, over AOSP's
 * accessory protocol, to become an accessory of the desktop's — see
 * `lib/src/remote/accessory_usb.dart`. Android then offers to open this
 * application, because of the filter in the manifest, and opening it grants the
 * permission to open the accessory: a pair of bulk endpoints, as a file
 * descriptor.
 *
 * **This file only moves bytes.** It connects to the relay's cable port on
 * loopback — `TabletRelay` in `lib/src/remote/usb_relay.dart`, the same port an
 * iPad's `usbmuxd` tunnel arrives at — and pumps the accessory into it and it
 * into the accessory. Everything the bytes mean is the relay's, in Dart, and is
 * the same code an iPad runs. There is no method channel: nothing here is
 * asked anything.
 *
 * One accessory at a time, and the pump stops when either end does. If the
 * accessory is still attached it is opened again a second later, which is what
 * a desktop that restarted its end of the cable looks like from here.
 */
class OaaAccessory : FlutterPlugin, ActivityAware {

  private companion object {
    /** Must match `kUsbPipePort` in `lib/src/remote/usb_relay.dart`. */
    const val PIPE_PORT = 47823
    const val MANUFACTURER = "Open Audio Analyzer"
    const val MODEL = "Display"
    const val PERMISSION = "com.openaudioanalyzer.oaa.USB_ACCESSORY_PERMISSION"
    /** AOA's own advice: read at least 16 kB, or a transfer is truncated. */
    const val BUFFER = 16384
  }

  private var context: Context? = null
  private var binding: ActivityPluginBinding? = null
  private val main = Handler(Looper.getMainLooper())

  @Volatile private var open: Pump? = null

  private val newIntent = PluginRegistry.NewIntentListener { intent ->
    if (intent.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) look()
    false
  }

  private val receiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      when (intent.action) {
        PERMISSION -> look()
        UsbManager.ACTION_USB_ACCESSORY_DETACHED -> open?.stop()
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    val filter = IntentFilter().apply {
      addAction(PERMISSION)
      addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
    }
    if (Build.VERSION.SDK_INT >= 33) {
      binding.applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      @Suppress("UnspecifiedRegisterReceiverFlag")
      binding.applicationContext.registerReceiver(receiver, filter)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    try {
      binding.applicationContext.unregisterReceiver(receiver)
    } catch (_: IllegalArgumentException) {
    }
    open?.stop()
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.binding = binding.also { it.addOnNewIntentListener(newIntent) }
    // Launched by the attach intent, or opened by hand with a cable already in.
    look()
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    binding?.removeOnNewIntentListener(newIntent)
    binding = null
  }

  /** Opens the desktop's accessory if there is one and nothing is open yet. */
  private fun look() {
    val context = context ?: return
    if (open != null) return
    val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
    val accessory = manager.accessoryList?.firstOrNull {
      it.manufacturer == MANUFACTURER && it.model == MODEL
    } ?: return

    if (!manager.hasPermission(accessory)) {
      // Granted already when the attach intent launched us; asked for when the
      // application was opened by hand with the cable in.
      val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
      val intent = Intent(PERMISSION).setPackage(context.packageName)
      manager.requestPermission(
        accessory,
        PendingIntent.getBroadcast(context, 0, intent, flags),
      )
      return
    }
    val descriptor = try {
      manager.openAccessory(accessory)
    } catch (_: Exception) {
      null
    } ?: return
    open = Pump(accessory, descriptor).also { it.start() }
  }

  private inner class Pump(
    private val accessory: UsbAccessory,
    private val descriptor: ParcelFileDescriptor,
  ) {
    @Volatile private var stopped = false
    @Volatile private var socket: Socket? = null

    fun start() {
      Thread({ run() }, "oaa-accessory").start()
    }

    private fun run() {
      val input = FileInputStream(descriptor.fileDescriptor)
      val output = FileOutputStream(descriptor.fileDescriptor)
      // The relay binds at launch; the attach intent may arrive before it has.
      var relay: Socket? = null
      while (!stopped && relay == null) {
        relay = try {
          Socket(InetAddress.getLoopbackAddress(), PIPE_PORT).apply { tcpNoDelay = true }
        } catch (_: Exception) {
          Thread.sleep(300)
          null
        }
      }
      if (relay == null) return finish()
      socket = relay

      val toDesktop = Thread({
        val buffer = ByteArray(BUFFER)
        try {
          val from = relay.getInputStream()
          while (!stopped) {
            val read = from.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
          }
        } catch (_: Exception) {
        }
        stop()
      }, "oaa-accessory-out")
      toDesktop.start()

      val buffer = ByteArray(BUFFER)
      try {
        val to = relay.getOutputStream()
        while (!stopped) {
          val read = input.read(buffer)
          if (read < 0) break
          if (read > 0) to.write(buffer, 0, read)
        }
      } catch (_: Exception) {
      }
      stop()
      finish()
    }

    fun stop() {
      if (stopped) return
      stopped = true
      try {
        socket?.close()
      } catch (_: Exception) {
      }
      try {
        // Unblocks the read on most devices; detaching the cable does on all.
        descriptor.close()
      } catch (_: Exception) {
      }
    }

    private fun finish() {
      main.post {
        if (open === this) open = null
        // Still attached: the desktop restarted its end. Open it again.
        main.postDelayed({ look() }, 1000)
      }
    }
  }
}
