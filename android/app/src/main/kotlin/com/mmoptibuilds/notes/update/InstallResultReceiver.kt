package com.mmoptibuilds.notes.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/**
 * Receives the status of a PackageInstaller session. Not exported: the
 * PendingIntent that targets it is explicit and created by [UpdaterPlugin].
 *
 * It never reports "installed": at most the system confirmation was shown
 * (`handedToOs`). If the install succeeds Android replaces the app and the
 * process ends; the next launch compares versionCodes.
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= 34) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    InstallStatusHub.deliver("failed", "Android sent no confirmation screen.")
                    return
                }
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(confirm)
                    InstallStatusHub.deliver("handedToOs")
                } catch (e: Exception) {
                    InstallStatusHub.deliver("failed", e.message ?: "Could not open the installer.")
                }
            }
            PackageInstaller.STATUS_SUCCESS -> InstallStatusHub.deliver("handedToOs")
            PackageInstaller.STATUS_FAILURE_ABORTED -> InstallStatusHub.deliver("cancelled")
            else -> InstallStatusHub.deliver("failed", message ?: "Android could not install the update.")
        }
    }
}
