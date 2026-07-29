package com.buddy.app

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import org.json.JSONObject
import java.io.File

// Setup screen. The real UI is the overlay buddy; this exists to grant the
// permissions Android demands and to show honest status.
class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var overlayBtn: Button
    private lateinit var batteryBtn: Button
    private lateinit var serviceBtn: Button
    private lateinit var freezeBtn: Button
    private lateinit var testModeBtn: Button
    private lateinit var reloadBtn: Button
    private lateinit var talkBtn: Button
    private lateinit var testsBtn: Button
    private val refreshTick = object : Runnable {
        override fun run() {
            refresh()
            status.postDelayed(this, 1500)
        }
    }

    private fun buddyIsHere(): Boolean =
        getSharedPreferences("coordination", Context.MODE_PRIVATE).getBoolean("owner", false)

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(48), dp(20), dp(24))
        }
        status = TextView(this).apply { textSize = 15f; setPadding(0, 0, 0, dp(16)) }
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
        freezeBtn = Button(this).apply {
            setOnClickListener { cmdToService("toggleFreeze"); postDelayed() }
        }
        testModeBtn = Button(this).apply {
            setOnClickListener { cmdToService("testMode"); postDelayed() }
        }
        reloadBtn = Button(this).apply {
            text = "reload brain"
            setOnClickListener { cmdToService("reload") }
        }
        talkBtn = Button(this).apply {
            text = "talk to buddy"
            setOnClickListener { talkDialog() }
        }
        testsBtn = Button(this).apply {
            text = "test interactions"
            setOnClickListener { testsDialog() }
        }

        root.addView(status)
        root.addView(overlayBtn)
        root.addView(batteryBtn)
        root.addView(serviceBtn)
        root.addView(freezeBtn)
        root.addView(testModeBtn)
        root.addView(reloadBtn)
        root.addView(talkBtn)
        root.addView(testsBtn)
        settingsSection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(settingsSection)
        buildSettings()
        setContentView(android.widget.ScrollView(this).apply { addView(root) })

        // Arrived via the ntfy wake poke (buddy:// link): revive the service.
        if (intent?.data?.scheme == "buddy" && Settings.canDrawOverlays(this)) {
            startForegroundService(Intent(this, BuddyService::class.java))
        }
    }

    override fun onResume() {
        super.onResume()
        buildSettings() // traits may have just arrived with buddy
        status.removeCallbacks(refreshTick)
        status.post(refreshTick) // live: buddy can arrive/leave while visible
    }

    override fun onPause() {
        super.onPause()
        status.removeCallbacks(refreshTick)
    }

    private fun postDelayed() {
        status.postDelayed({ refresh() }, 600)
    }

    private fun refresh() {
        val overlay = Settings.canDrawOverlays(this)
        val battery = getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(packageName)
        val running = serviceRunning()

        val here = running && buddyIsHere()

        overlayBtn.isEnabled = !overlay
        overlayBtn.text = if (overlay) "overlay permission: granted" else "grant overlay permission"
        batteryBtn.isEnabled = !battery
        batteryBtn.text = if (battery) "battery exemption: granted" else "allow background survival"
        serviceBtn.text = if (running) "stop buddy" else "start buddy"
        serviceBtn.isEnabled = overlay
        reloadBtn.isEnabled = running
        // Buddy-facing controls need buddy actually on this device, not just
        // the service - a frozen/chatted-at empty screen is nonsense.
        freezeBtn.isEnabled = here
        freezeBtn.text = if (BuddyService.frozenState) "wake buddy" else "freeze buddy"
        testModeBtn.isEnabled = here
        testModeBtn.text = if (BuddyService.testMode)
            "chaos test mode: ON" else "chaos test mode (1h, no limits)"
        talkBtn.isEnabled = here
        testsBtn.isEnabled = here

        status.text = when {
            !overlay -> "buddy needs the overlay permission to exist here."
            !running -> "ready. start the service and buddy can travel to this phone."
            !here -> "service running, listening on the LAN. buddy is elsewhere -\n" +
                "it appears here when it travels over."
            else -> "buddy is HERE.\ntap: poke. drag: carry. hold still 1.2s: send home."
        }
    }

    private lateinit var settingsSection: LinearLayout

    // Settings parity with the mac's Buddy Settings window: personality
    // sliders inside each trait's drift bounds, plus the disruption leash.
    // Bounds arrive with buddy via replication; no traits yet = nothing to show.
    private fun buildSettings() {
        settingsSection.removeAllViews()
        val names = Traits.names(this)

        settingsSection.addView(header("Personality"))
        if (names.isEmpty()) {
            settingsSection.addView(note("no traits yet - they arrive with buddy's first visit."))
        }
        for (name in names) {
            val (lo, hi) = Traits.bounds(this, name)
            settingsSection.addView(sliderRow(name, lo, hi, Traits.get(this, name), "%.2f") { v ->
                if (buddyIsHere()) {
                    // Owner path: apply locally, tell the brain, replicate out.
                    val from = Traits.get(this, name)
                    Traits.set(this, name, v)
                    emitToService("configChanged", JSONObject()
                        .put("trait", name).put("from", from).put("to", v))
                } else {
                    // Buddy lives elsewhere: ask the owner over the network;
                    // its broadcast echoes the clamped result back here.
                    startService(Intent(this, BuddyService::class.java)
                        .putExtra("traitSet", name).putExtra("traitValue", v))
                }
            })
        }
        settingsSection.addView(note("one buddy, one soul - edits reach it wherever it lives."))

        settingsSection.addView(header("Limits"))
        val inv = File(filesDir, "invariants.json")
        val current = try { JSONObject(inv.readText()).optInt("maxDisruptivePerHour", 3) }
            catch (e: Exception) { 3 }
        settingsSection.addView(sliderRow("disruptive / hour", 0.0, 30.0, current.toDouble(), "%.0f") { v ->
            inv.writeText(JSONObject().put("maxDisruptivePerHour", v.toInt()).toString(2))
        })
        settingsSection.addView(note("the leash. tighter here than the mac - it buzzes in your pocket."))
    }

    private fun emitToService(event: String, payload: JSONObject) {
        if (!serviceRunning()) return
        startService(Intent(this, BuddyService::class.java)
            .putExtra("emit", event).putExtra("payload", payload.toString()))
    }

    private fun cmdToService(cmd: String) {
        if (!serviceRunning()) return
        startService(Intent(this, BuddyService::class.java).putExtra("cmd", cmd))
    }

    private fun talkDialog() {
        val input = android.widget.EditText(this).apply { hint = "say something to buddy" }
        android.app.AlertDialog.Builder(this)
            .setTitle("talk to buddy")
            .setView(input)
            .setPositiveButton("send") { _, _ ->
                val text = input.text.toString().trim()
                if (text.isNotEmpty()) emitToService("chat", JSONObject().put("text", text))
            }
            .setNegativeButton("cancel", null)
            .show()
    }

    private fun testsDialog() {
        val tests = try {
            val arr = org.json.JSONArray(File(filesDir, "brain/tests.json").readText())
            (0 until arr.length()).map { arr.getJSONObject(it) }
        } catch (e: Exception) { emptyList() }
        if (tests.isEmpty()) return
        android.app.AlertDialog.Builder(this)
            .setTitle("test interactions")
            .setItems(tests.map { it.optString("title", it.optString("id")) }.toTypedArray()) { _, i ->
                emitToService("test:${tests[i].optString("id")}", JSONObject())
            }
            .show()
    }

    private fun header(text: String) = TextView(this).apply {
        this.text = text
        textSize = 17f
        setTypeface(null, Typeface.BOLD)
        setPadding(0, dp(28), 0, dp(10))
    }

    private fun note(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12f
        alpha = 0.6f
        setPadding(0, dp(4), 0, dp(12))
    }

    private fun sliderRow(label: String, min: Double, max: Double, value: Double,
                          format: String, onChange: (Double) -> Unit): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        val name = TextView(this).apply {
            text = label
            textSize = 14f
            typeface = Typeface.MONOSPACE
            width = dp(120)
        }
        val valueLabel = TextView(this).apply {
            text = String.format(format, value)
            textSize = 14f
            typeface = Typeface.MONOSPACE
            width = dp(48)
            gravity = android.view.Gravity.END
        }
        val seek = SeekBar(this).apply {
            this.max = 100
            progress = if (max > min) (((value - min) / (max - min)) * 100).toInt() else 0
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                .apply { marginStart = dp(8); marginEnd = dp(8) }
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, p: Int, fromUser: Boolean) {
                    valueLabel.text = String.format(format, min + (max - min) * p / 100.0)
                }
                override fun onStartTrackingTouch(sb: SeekBar) {}
                override fun onStopTrackingTouch(sb: SeekBar) {
                    onChange(min + (max - min) * sb.progress / 100.0)
                }
            })
        }
        row.addView(name)
        row.addView(seek)
        row.addView(valueLabel)
        return row
    }

    // The service maintains its own flag - the getRunningServices API is
    // deprecated and unreliable, which had this button lying about state.
    private fun serviceRunning(): Boolean = BuddyService.running
}
