package com.mmoptibuilds.notes.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Android half of the in-app updater, on its own MethodChannel.
 *
 * Register from MainActivity.configureFlutterEngine with
 * `UpdaterPlugin.register(flutterEngine, this)`.
 *
 * What it does: reports the installed version, reads an APK's package name,
 * versionCode and signing certificates, and installs an APK through a
 * PackageInstaller session. What it never does: install silently, use root,
 * hand out file:// or content:// URIs, or write outside the app's cache
 * directory. The Dart side decides whether an APK is acceptable (package id,
 * versionCode, pinned certificate); this class only reports facts and moves
 * bytes.
 */
class UpdaterPlugin private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "installedVersion" -> result.success(installedVersion())
                "updateCacheDir" -> result.success(updatesDir().absolutePath)
                "freeSpace" -> result.success(freeSpace(call.argument<String>("path")))
                "inspectApk" -> inspectApk(call.argument<String>("path"), result)
                "canInstall" -> result.success(canInstall())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                "install" -> install(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("updater_error", e.message, null)
        }
    }

    private fun updatesDir(): File =
        File(context.applicationContext.cacheDir, "updates").also { it.mkdirs() }

    /** The APK must be a regular .apk file inside the updates cache directory. */
    private fun checkedApk(path: String?): File {
        require(!path.isNullOrEmpty()) { "path is required" }
        val dir = updatesDir().canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == dir && file.isFile && file.name.endsWith(".apk")) {
            "not an update file"
        }
        return file
    }

    private fun installedVersion(): Map<String, Any?> {
        val pm = context.packageManager
        val info = pm.getPackageInfo(context.packageName, 0)
        val code: Long = if (Build.VERSION.SDK_INT >= 28) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf(
            "packageName" to context.packageName,
            "versionCode" to code,
            "versionName" to (info.versionName ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
        )
    }

    private fun freeSpace(path: String?): Long {
        val p = if (path.isNullOrEmpty()) updatesDir().absolutePath else path
        var dir = File(p)
        while (!dir.exists()) dir = dir.parentFile ?: break
        return StatFs(dir.absolutePath).availableBytes
    }

    private fun canInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= 26) context.packageManager.canRequestPackageInstalls() else true

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < 26) return
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:" + context.packageName)
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun inspectApk(path: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 28) {
            result.success(mapOf("supported" to false))
            return
        }
        val file = checkedApk(path)
        Thread {
            try {
                val pm = context.packageManager
                val flags = PackageManager.GET_SIGNING_CERTIFICATES
                val info = if (Build.VERSION.SDK_INT >= 33) {
                    pm.getPackageArchiveInfo(
                        file.absolutePath,
                        PackageManager.PackageInfoFlags.of(flags.toLong())
                    )
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageArchiveInfo(file.absolutePath, flags)
                }
                if (info == null) {
                    main.post { result.error("unreadable", "Android could not read the package.", null) }
                    return@Thread
                }
                // The certificates that sign the APK contents (the current
                // signer). More than one entry means a multi-signer APK, which
                // the Dart side rejects.
                val signers = info.signingInfo?.apkContentsSigners?.map { sha256Hex(it.toByteArray()) }
                    ?: emptyList()
                val out = mapOf(
                    "supported" to true,
                    "packageName" to info.packageName,
                    "versionCode" to info.longVersionCode,
                    "signerSha256" to signers,
                )
                main.post { result.success(out) }
            } catch (e: Exception) {
                main.post { result.error("inspect_failed", e.message, null) }
            }
        }.start()
    }

    private fun install(path: String?, result: MethodChannel.Result) {
        val file = checkedApk(path)
        if (!InstallStatusHub.begin(result)) {
            result.error("busy", "An installation is already in progress.", null)
            return
        }
        Thread {
            val installer = context.packageManager.packageInstaller
            var sessionId = -1
            try {
                val params = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL
                )
                params.setAppPackageName(APP_ID)
                params.setSize(file.length())
                if (Build.VERSION.SDK_INT >= 31) {
                    params.setRequireUserAction(
                        PackageInstaller.SessionParams.USER_ACTION_REQUIRED
                    )
                }
                sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("base.apk", 0, file.length()).use { out ->
                            input.copyTo(out)
                            session.fsync(out)
                        }
                    }
                    // Explicit intent to a non-exported receiver. The system
                    // adds the status extras, so the PendingIntent must be
                    // mutable on API 31+.
                    val intent = Intent(context.applicationContext, InstallResultReceiver::class.java)
                        .setAction(ACTION_RESULT)
                        .setPackage(context.packageName)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pending = PendingIntent.getBroadcast(
                        context.applicationContext, sessionId, intent, flags
                    )
                    session.commit(pending.intentSender)
                }
            } catch (e: Exception) {
                if (sessionId >= 0) {
                    try {
                        installer.abandonSession(sessionId)
                    } catch (_: Exception) {
                    }
                }
                main.post {
                    InstallStatusHub.deliver("failed", e.message ?: "Could not start the installation.")
                }
            }
        }.start()
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    companion object {
        const val CHANNEL = "com.mmoptibuilds.notes/updater"
        private const val APP_ID = "com.mmoptibuilds.notes"
        private const val ACTION_RESULT = "com.mmoptibuilds.notes.update.INSTALL_RESULT"

        @JvmStatic
        fun register(flutterEngine: FlutterEngine, context: Context) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(UpdaterPlugin(context))
        }
    }
}
