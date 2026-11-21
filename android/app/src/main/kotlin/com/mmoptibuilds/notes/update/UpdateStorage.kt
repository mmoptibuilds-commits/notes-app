package com.mmoptibuilds.notes.update

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files

/** App-private, persistent storage used by both the updater and replacement
 * receiver. Migrates only the old updater marker from cache, then removes that
 * updater-scoped cache directory. */
internal fun appUpdatesDirectory(context: Context): File {
    val app = context.applicationContext
    val current = File(app.filesDir, "updates")
    val legacy = File(app.cacheDir, "updates")
    require(!Files.isSymbolicLink(current.toPath())) { "unsafe update directory" }
    require(!Files.isSymbolicLink(legacy.toPath())) { "unsafe legacy update directory" }
    if (!current.exists() && !current.mkdirs()) {
        throw IllegalStateException("could not create update storage")
    }
    val oldMarker = File(legacy, "pending.json")
    val newMarker = File(current, "pending.json")
    if (!newMarker.exists() && oldMarker.isFile && oldMarker.length() <= 4096) {
        val temporary = File(current, "pending.json.migrate")
        oldMarker.inputStream().use { input ->
            FileOutputStream(temporary).use { output ->
                input.copyTo(output)
                output.fd.sync()
            }
        }
        if (!temporary.renameTo(newMarker)) {
            temporary.delete()
            throw IllegalStateException("could not migrate update marker")
        }
    }
    if (legacy.exists()) legacy.deleteRecursively()
    return current
}
