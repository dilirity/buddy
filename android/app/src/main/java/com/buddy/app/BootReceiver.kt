package com.buddy.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings

// Survival: buddy comes back after a reboot without being asked. Skipped when
// the overlay permission is missing - a headless buddy is worse than none.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!Settings.canDrawOverlays(context)) return
        context.startForegroundService(Intent(context, BuddyService::class.java))
    }
}
