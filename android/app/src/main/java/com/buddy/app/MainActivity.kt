package com.buddy.app

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

// Setup screen. The real UI is the overlay buddy; this exists to grant the
// permissions Android demands and to show honest status.
class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var overlayBtn: Button
    private lateinit var batteryBtn: Button
    private lateinit var serviceBtn: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(60, 120, 60, 60)
        }
        status = TextView(this).apply { textSize = 15f; setPadding(0, 0, 0, 40) }
        overlayBtn = Button(this).apply {
            text = "grant overlay permission"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")))
            }
        }
        batteryBtn = Button(this).apply {
            text = "allow background survival"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")))
            }
        }
        serviceBtn = Button(this).apply {
            setOnClickListener {
                if (serviceRunning()) {
                    stopService(Intent(this@MainActivity, BuddyService::class.java))
                } else {
                    startForegroundService(Intent(this@MainActivity, BuddyService::class.java))
                }
                postDelayed()
            }
        }
        root.addView(status)
        root.addView(overlayBtn)
        root.addView(batteryBtn)
        root.addView(serviceBtn)
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun postDelayed() {
        status.postDelayed({ refresh() }, 600)
    }

    private fun refresh() {
        val overlay = Settings.canDrawOverlays(this)
        val battery = getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(packageName)
        val running = serviceRunning()

        overlayBtn.isEnabled = !overlay
        overlayBtn.text = if (overlay) "overlay permission: granted" else "grant overlay permission"
        batteryBtn.isEnabled = !battery
        batteryBtn.text = if (battery) "battery exemption: granted" else "allow background survival"
        serviceBtn.text = if (running) "stop buddy" else "start buddy"
        serviceBtn.isEnabled = overlay

        status.text = when {
            !overlay -> "buddy needs the overlay permission to exist here."
            !running -> "ready. start the service and buddy can travel to this phone."
            else -> "buddy service is running. buddy appears when it travels here.\n" +
                "tap buddy: poke. drag: carry. hold 1.5s: send home."
        }
    }

    private fun serviceRunning(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return am.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == BuddyService::class.java.name }
    }
}
