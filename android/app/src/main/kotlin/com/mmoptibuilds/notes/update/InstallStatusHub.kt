package com.mmoptibuilds.notes.update

import io.flutter.plugin.common.MethodChannel

/**
 * Holds the one Dart call that is waiting for the first answer from the
 * PackageInstaller. The result receiver calls [deliver]; only the first
 * delivery counts, because a MethodChannel result can be answered once.
 *
 * All calls happen on the main thread (method calls and broadcast receivers
 * both run there; the background copy thread posts back to the main looper).
 */
internal object InstallStatusHub {
    private var waiting: MethodChannel.Result? = null

    /** Returns false when an install is already waiting for an answer. */
    fun begin(result: MethodChannel.Result): Boolean {
        if (waiting != null) return false
        waiting = result
        return true
    }

    fun deliver(status: String, message: String? = null) {
        val r = waiting ?: return
        waiting = null
        val map = HashMap<String, Any?>()
        map["status"] = status
        if (message != null) map["message"] = message
        r.success(map)
    }
}
