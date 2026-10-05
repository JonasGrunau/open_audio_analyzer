// SPDX-License-Identifier: GPL-3.0-or-later

package com.openaudioanalyzer.oaa

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Opens and saves documents the user chooses, through the system's own picker.
 *
 * **`file_selector` cannot save on Android at all.** `getSaveLocation` is not
 * implemented by `file_selector_android`, so Save as, Export this tab and every
 * report export threw on a tablet and did nothing a user could see. And its
 * `openFile` answers with a *copy* of the chosen file in the cache directory, so
 * a preset opened and then saved was written over that copy and never reached
 * the file the user had picked — a Save that succeeds and changes nothing.
 *
 * Both are the shape of Android's storage since 10: an application is handed a
 * `content://` URI by the Storage Access Framework, never a path, and reads and
 * writes go through the `ContentResolver`. So that is what crosses this channel:
 * `create` and `open` show the system picker and answer with the document's URI,
 * and `read`, `write` and `exists` act on one. The permission is taken as
 * *persistable*, which is what lets `session.json` remember the document and
 * have Save overwrite it the next morning.
 *
 * A document crosses as `<content uri>#<display name>`. Dart needs the name
 * synchronously — it is the preset's name, and what a notice quotes — and the
 * URI does not contain it: the Downloads provider answers `msf:1234`, and Drive
 * an opaque id. A content URI never carries a fragment of its own, so the name
 * rides there and is stripped here before the resolver sees it.
 *
 * Reads and writes run off the main thread and answer on it, because a
 * provider may be a network drive.
 */
class OaaDocuments : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

  private companion object {
    /** Must match `documentsChannel` in `storage/picked_documents.dart`; its iOS twin is `ios/Runner/OaaDocuments.swift`. */
    const val CHANNEL = "com.openaudioanalyzer.oaa/documents"

    const val CREATE_CODE = 4824
    const val OPEN_CODE = 4825

    const val GRANT =
      Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
  }

  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var binding: ActivityPluginBinding? = null
  private val io = Executors.newSingleThreadExecutor()
  private val main = Handler(Looper.getMainLooper())

  /** The picker still on screen, or null. One at a time, like the mic request. */
  private var pending: MethodChannel.Result? = null

  private val listener = PluginRegistry.ActivityResultListener { code, resultCode, data ->
    if (code != CREATE_CODE && code != OPEN_CODE) return@ActivityResultListener false
    val result = pending ?: return@ActivityResultListener true
    pending = null

    val uri = data?.data
    if (resultCode != Activity.RESULT_OK || uri == null) {
      // Dismissed. Not an error: the Dart side treats it as a cancelled dialog.
      result.success(null)
      return@ActivityResultListener true
    }
    try {
      // Persistable, so the document stays writable after a relaunch. A
      // provider that offers no persistable grant still answers this session.
      context?.contentResolver?.takePersistableUriPermission(
        uri,
        if (code == CREATE_CODE) GRANT else Intent.FLAG_GRANT_READ_URI_PERMISSION or
          (data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION),
      )
    } catch (_: SecurityException) {
    }
    result.success("$uri#${Uri.encode(displayName(uri) ?: uri.lastPathSegment ?: "")}")
    true
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    pending?.success(null)
    pending = null
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    io.shutdown()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.binding = binding.also { it.addActivityResultListener(listener) }
  }

  override fun onDetachedFromActivityForConfigChanges() {
    // The picker is its own activity and survives a rotation of ours; the
    // result arrives on the new binding, so the pending call is kept.
    binding?.removeActivityResultListener(listener)
    binding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    pending?.success(null)
    pending = null
    binding?.removeActivityResultListener(listener)
    binding = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "create" -> pick(result, CREATE_CODE) {
        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
          addCategory(Intent.CATEGORY_OPENABLE)
          type = call.argument<String>("mime") ?: "application/octet-stream"
          putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "")
        }
      }
      "open" -> pick(result, OPEN_CODE) {
        // Every type. A JSON file is `application/json` to one provider and
        // `application/octet-stream` to the next, and a filter would grey out
        // the preset somebody is looking straight at. Anything that is not a
        // preset is refused by name on the Dart side.
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
          addCategory(Intent.CATEGORY_OPENABLE)
          type = "*/*"
        }
      }
      "read" -> background(call, result) { uri ->
        resolver().openInputStream(uri)?.use { it.readBytes() }
          ?: throw java.io.IOException("The provider returned nothing.")
      }
      "write" -> {
        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
        background(call, result) { uri ->
          // "wt" truncates. Plain "w" does not on every provider, and a shorter
          // preset written over a longer one would then end in the old one's
          // tail — a file that no longer parses.
          val stream = try {
            resolver().openOutputStream(uri, "wt")
          } catch (_: IllegalArgumentException) {
            resolver().openOutputStream(uri, "rwt")
          } ?: throw java.io.IOException("The provider refused the write.")
          stream.use { it.write(bytes) }
          null
        }
      }
      "exists" -> background(call, result) { uri ->
        resolver().query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
          ?.use { it.moveToFirst() } ?: false
      }
      else -> result.notImplemented()
    }
  }

  private fun pick(result: MethodChannel.Result, code: Int, intent: () -> Intent) {
    val activity = binding?.activity ?: return result.success(null)
    if (pending != null) {
      return result.error("picker-in-flight", "A document picker is already open.", null)
    }
    pending = result
    activity.startActivityForResult(intent(), code)
  }

  /** Runs [work] on the I/O thread with the call's URI, and answers on the main one. */
  private fun background(call: MethodCall, result: MethodChannel.Result, work: (Uri) -> Any?) {
    val path = call.argument<String>("path")
      ?: return result.error("document", "No document was named.", null)
    // The name rides in the fragment; the provider must never see it.
    val uri = Uri.parse(path.substringBefore('#'))
    io.execute {
      try {
        val value = work(uri)
        main.post { result.success(value) }
      } catch (error: Exception) {
        main.post { result.error("document", error.message ?: error.javaClass.simpleName, null) }
      }
    }
  }

  /**
   * The application's resolver, not the activity's: a grant belongs to the
   * application, and a write that outlives a rotation must not lose its
   * resolver halfway through.
   */
  private fun resolver(): ContentResolver =
    context?.contentResolver ?: throw java.io.IOException("Detached from the engine.")

  private fun displayName(uri: Uri): String? = try {
    context?.contentResolver
      ?.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
      ?.use { if (it.moveToFirst()) it.getString(0) else null }
  } catch (_: Exception) {
    null
  }
}
