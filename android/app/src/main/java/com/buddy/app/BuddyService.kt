package com.buddy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import org.json.JSONObject

// Foreground service hosting the overlay buddy and the coordination client.
// Survival hardening (boot receiver, battery exemption, ntfy wake) comes next;
// this is the minimum that keeps Android from killing buddy mid-visit.
class BuddyService : Service() {
    private lateinit var coordination: Coordination
    private var overlay: BuddyOverlay? = null

    override fun onCreate() {
        super.onCreate()
        startForeground(1, buildNotification())

        val sheet = SpriteSheet(this)
        overlay = BuddyOverlay(this, sheet) { sendHome() }

        coordination = Coordination(this)
        coordination.onArrive = { payload ->
            overlay?.show(payload.optString("line").takeIf { it.isNotEmpty() })
        }
        coordination.onDepart = { overlay?.hide() }
        coordination.start()

        // Buddy was here when the service died (crash/reboot): resume it.
        if (coordination.ownsBuddy) {
            overlay?.show("whoa. where was i. anyway im back")
        }
    }

    private fun sendHome() {
        coordination.travel(JSONObject().put("line", "im BACK. phones are small")) { ok ->
            if (!ok) overlay?.say("hm. cant find the mac. staying here i guess", 5)
        }
    }

    private fun buildNotification(): Notification {
        val channel = NotificationChannel("buddy", "Buddy", NotificationManager.IMPORTANCE_MIN)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        return Notification.Builder(this, "buddy")
            .setContentTitle("buddy is around")
            .setSmallIcon(android.R.drawable.star_on)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        coordination.stop()
        overlay?.hide()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
