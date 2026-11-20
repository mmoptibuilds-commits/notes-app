package com.mmoptibuilds.notes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.mmoptibuilds.notes.update.UpdaterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * file_selector has no "save file" dialog on Android, so exports go through the
 * system document picker (ACTION_CREATE_DOCUMENT). The user chooses where the
 * file goes; nothing is written anywhere else.
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UpdaterPlugin.register(flutterEngine, this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val name = call.argument<String>("name")
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val bytes = call.argument<ByteArray>("bytes")
                if (name == null || bytes == null) {
                    result.error("bad_args", "name and bytes are required", null)
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "A save is already in progress", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                pendingBytes = bytes
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                try {
                    startActivityForResult(intent, REQUEST_SAVE)
                } catch (e: Exception) {
                    finishSave { it.error("no_picker", e.message, null) }
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_SAVE) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finishSave { it.success(null) } // cancelled
            return
        }
        val bytes = pendingBytes
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes!!) }
                val label = displayName(uri)
                runOnUiThread { finishSave { it.success(label) } }
            } catch (e: Exception) {
                runOnUiThread { finishSave { it.error("write_failed", e.message, null) } }
            }
        }.start()
    }

    private fun displayName(uri: Uri): String =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            ?: uri.lastPathSegment
            ?: "file"

    private fun finishSave(reply: (MethodChannel.Result) -> Unit) {
        val r = pendingResult
        pendingResult = null
        pendingBytes = null
        if (r != null) reply(r)
    }

    companion object {
        private const val CHANNEL = "com.mmoptibuilds.notes/save"
        private const val REQUEST_SAVE = 4711
    }
}
