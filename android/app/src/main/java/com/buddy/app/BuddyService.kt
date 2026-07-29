package com.buddy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.File

// Foreground service hosting the overlay body, the QuickJS brain, the
// coordination client, and the phone senses. The brain is the same JS the
// mac runs; the service is just the phone-shaped shell around it.
class BuddyService : Service() {
    companion object {
        // Read by MainActivity for menu labels; written only here.
        @Volatile var frozenState = false
        @Volatile var testModeUntil = 0L
        val testMode: Boolean get() = System.currentTimeMillis() < testModeUntil
    }

    private lateinit var coordination: Coordination
    private lateinit var brain: BuddyBrain
    private var overlay: BuddyOverlay? = null
    private val disruptions = ArrayDeque<Long>()
    private var lastPhonePush = 0L

    // Phone invariants: tighter than the mac - a buzzing phone is worse than
    // a talking desktop. Pete-editable via files, not the mutator.
    private var maxDisruptivePerHour = 3

    override fun onCreate() {
        super.onCreate()
        startForeground(1, buildNotification())
        loadInvariants()

        val sheet = SpriteSheet(this)
        val shell = object : BuddyOverlay(
            this, sheet,
            onSendHome = { sendHome() },
            onEvent = { name, payload -> brain.emit(name, payload) },
        ) {
            override fun phoneNotify(text: String): Boolean = pushNotification(text, hard = true)
            override fun phoneReply(text: String): Boolean = pushNotification(text, hard = false)
            override fun isFrozen(): Boolean = frozenState
            // Frozen = buddy sleeps, brain output muted (mirrors the mac's
            // freeze guards on say/move; "sleep" stays allowed like the mac).
            override fun say(text: String, secs: Double, prop: String?) {
                if (frozenState) return
                super.say(text, secs, prop)
            }
            override fun moveTo(x: Double, y: Double, speed: Double) {
                if (frozenState) return
                super.moveTo(x, y, speed)
            }
            override fun play(anim: String) {
                if (frozenState && anim != "sleep") return
                super.play(anim)
            }
        }
        overlay = shell
        brain = BuddyBrain(this, shell)
        brain.start()

        coordination = Coordination(this)
        coordination.onArrive = { payload ->
            payload.optJSONObject("traitSpecs")?.let { Traits.replaceSpecs(this, it) }
                ?: payload.optJSONObject("traits")?.let { Traits.replaceAll(this, it) }
            overlay?.show(payload.optString("line").takeIf { it.isNotEmpty() }) {
                brain.emit("travelArrived", payload)
            }
        }
        coordination.onDepart = {
            brain.emit("travelDeparted")
            overlay?.hide()
        }
        // Mac crashed while owning buddy: resume from the last replicated
        // snapshot with emergency-arrival fiction.
        // Owner's periodic snapshots keep the phone's traits (and their
        // bounds) in sync even when buddy has never visited.
        coordination.onSnapshot = { snapshot ->
            snapshot.optJSONObject("traitSpecs")?.let { Traits.replaceSpecs(this, it) }
        }
        coordination.onEmergencyClaim = { snapshot ->
            snapshot.optJSONObject("traitSpecs")?.let { Traits.replaceSpecs(this, it) }
                ?: snapshot.optJSONObject("traits")?.let { Traits.replaceAll(this, it) }
            overlay?.show("uh. the mac just died?? im living here now") {
                brain.emit("travelArrived", snapshot)
            }
        }
        coordination.start()

        registerSenses()

        // Buddy was here when the service died (crash/reboot): resume it.
        if (coordination.ownsBuddy) {
            overlay?.show("whoa. where was i. anyway im back") {
                brain.emit("travelArrived", JSONObject())
            }
        }
    }

    // MARK: - Senses (phone-native events, same buddy.on pattern)

    private val senses = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_POWER_CONNECTED -> brain.emit("charging", JSONObject().put("on", true))
                Intent.ACTION_POWER_DISCONNECTED -> brain.emit("charging", JSONObject().put("on", false))
                Intent.ACTION_SCREEN_ON -> brain.emit("screenOn")
                Intent.ACTION_SCREEN_OFF -> brain.emit("screenOff")
                Intent.ACTION_USER_PRESENT -> brain.emit("unlocked")
            }
        }
    }

    private fun registerSenses() {
        registerReceiver(senses, IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        })
    }

    // MARK: - Travel

    private fun snapshotPayload(): JSONObject = JSONObject()
        .put("traits", Traits.all(this))
        .put("traitSpecs", JSONObject().also { specs ->
            for (name in Traits.names(this)) {
                val (lo, hi) = Traits.bounds(this, name)
                specs.put(name, JSONObject()
                    .put("value", Traits.get(this, name)).put("min", lo).put("max", hi))
            }
        })

    private fun sendHome() {
        val payload = snapshotPayload()
            .put("line", "im BACK. phones are small")
        coordination.travel(payload) { ok ->
            if (!ok) overlay?.say("hm. cant find the mac. staying here i guess", 5.0, null)
        }
    }

    // MARK: - Notifications ("buddy texting" while it lives here)

    private fun allowDisruptive(): Boolean {
        if (testMode) return true // same bypass as the mac's Chaos Test Mode
        val now = System.currentTimeMillis()
        while (disruptions.isNotEmpty() && now - disruptions.first() > 3_600_000) {
            disruptions.removeFirst()
        }
        if (disruptions.size >= maxDisruptivePerHour) return false
        disruptions.addLast(now)
        return true
    }

    private fun pushNotification(text: String, hard: Boolean): Boolean {
        loadInvariants() // Pete may have moved the leash in settings
        val now = System.currentTimeMillis()
        if (hard) {
            if (now - lastPhonePush < 600_000) return false
            if (!allowDisruptive()) return false
            lastPhonePush = now
        } else if (now - lastPhonePush < 15_000) {
            return false
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("buddy-says", "Buddy says", NotificationManager.IMPORTANCE_DEFAULT))
        nm.notify(2, Notification.Builder(this, "buddy-says")
            .setContentTitle("buddy")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.star_on)
            .build())
        return true
    }

    private fun loadInvariants() {
        val f = File(filesDir, "invariants.json")
        if (!f.exists()) {
            f.writeText(JSONObject().put("maxDisruptivePerHour", 3).toString(2))
        }
        maxDisruptivePerHour = try {
            JSONObject(f.readText()).optInt("maxDisruptivePerHour", 3)
        } catch (e: Exception) { 3 }
    }

    private fun buildNotification(): Notification {
        val channel = NotificationChannel("buddy", "Buddy", NotificationManager.IMPORTANCE_MIN)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        return Notification.Builder(this, "buddy")
            .setContentTitle("buddy is around")
            .setSmallIcon(android.R.drawable.star_on)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Settings screen pipes config edits in as events, so buddy notices
        // being tweaked here exactly like it notices traits.json edits.
        intent?.getStringExtra("emit")?.let { name ->
            val payload = intent.getStringExtra("payload")?.let {
                try { JSONObject(it) } catch (e: Exception) { null }
            }
            brain.emit(name, payload)
            // Spec: every state change replicates immediately. A trait edit
            // while buddy lives here pushes to the mac right away.
            if (name == "configChanged") coordination.broadcastState(snapshotPayload())
        }
        // Menu commands from MainActivity (the phone's ᴥ equivalent).
        when (intent?.getStringExtra("cmd")) {
            "toggleFreeze" -> {
                frozenState = !frozenState
                if (frozenState) {
                    overlay?.stopMoving()
                    overlay?.play("sleep")
                } else {
                    overlay?.play("idle")
                    brain.emit("unfrozen")
                }
            }
            "reload" -> brain.reload()
            "testMode" -> {
                testModeUntil = if (testMode) 0L else System.currentTimeMillis() + 3_600_000
                overlay?.say(if (testMode) "NO LIMITS?? oh this is gonna be GREAT"
                             else "aww. limits are back.", 4.0, null)
                brain.emit("testMode", JSONObject().put("on", testMode))
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        try { unregisterReceiver(senses) } catch (e: Exception) { Log.w("BuddyService", "$e") }
        coordination.stop()
        brain.shutdown()
        overlay?.hide()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
