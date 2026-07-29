package com.buddy.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

// Launcher: request the overlay permission, start the service. The real UI is
// the overlay buddy; this screen exists only for setup.
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(60, 120, 60, 60)
        }
        val status = TextView(this).apply { textSize = 16f }
        val button = Button(this).apply { text = "start buddy" }
        root.addView(status)
        root.addView(button)
        setContentView(root)

        fun refresh() {
            status.text = if (Settings.canDrawOverlays(this))
                "overlay permission OK. buddy service ready."
            else
                "buddy needs the 'display over other apps' permission to exist."
        }
        refresh()

        button.setOnClickListener {
            if (!Settings.canDrawOverlays(this)) {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")))
            } else {
                startForegroundService(Intent(this, BuddyService::class.java))
                status.text = "buddy service running. buddy appears when it travels here."
            }
        }
    }

    override fun onResume() {
        super.onResume()
    }
}
