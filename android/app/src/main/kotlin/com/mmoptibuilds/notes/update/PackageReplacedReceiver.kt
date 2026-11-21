package com.mmoptibuilds.notes.update

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.mmoptibuilds.notes.MainActivity
import org.json.JSONObject
import java.io.File

/** Posts a notification only for a replacement that matches Notes' durable
 * pending-install marker. The receiver never starts an Activity itself. */
class PackageReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val pending = try {
            File(appUpdatesDirectory(context), "pending.json")
        } catch (_: Exception) {
            return
        }
        val marker = try {
            if (!pending.isFile || pending.length() > 4096) return
            JSONObject(pending.readText())
        } catch (_: Exception) {
            return
        }
        val expectedCode = marker.optLong("toVersionCode", -1)
        if (expectedCode <= 0) return
        val installedCode = try {
            context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
        } catch (_: Exception) {
            return
        }
        if (installedCode != expectedCode) return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as
            NotificationManager
        val channelId = "notes_updates"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "App updates",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Notifications about Notes updates"
                }
            )
        }
        val openNotes = Intent(context, MainActivity::class.java).apply {
            action = "com.mmoptibuilds.notes.OPEN_AFTER_UPDATE"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            8125,
            openNotes,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val version = marker.optString("toVersion", "")
        val text = if (version.isBlank()) "Tap to open Notes" else "Updated to $version — tap to open"
        val notification = Notification.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Notes updated — tap to open")
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        manager.notify(8125, notification)
    }
}
