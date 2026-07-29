package com.buddy.app

import android.content.ComponentName
import android.content.Context
import android.util.Log
import com.nothing.ketchum.Common
import com.nothing.ketchum.GlyphManager

// The Nothing Phone glyph lights, wrapped in the no-crash contract: every call
// is best-effort, silently inert on non-Nothing devices or when the service
// refuses us. Buddy flashing the glyphs is flavor - it must never be a crash.
class GlyphBridge(private val context: Context) {
    companion object { const val TAG = "GlyphBridge" }

    private var gm: GlyphManager? = null
    private var connected = false

    fun init() {
        try {
            if (!Common.is22111() && !Common.is20111() && !Common.is23111() && !Common.is23113()) {
                Log.i(TAG, "not a glyph device")
                return
            }
            val m = GlyphManager.getInstance(context.applicationContext)
            m.init(object : GlyphManager.Callback {
                override fun onServiceConnected(name: ComponentName?) {
                    connected = true
                    try { m.register() } catch (e: Exception) { Log.w(TAG, "register: ${e.message}") }
                    Log.i(TAG, "glyph service connected")
                }
                override fun onServiceDisconnected(name: ComponentName?) {
                    connected = false
                }
            })
            gm = m
        } catch (e: Exception) {
            Log.w(TAG, "init: ${e.message}")
            gm = null
        }
    }

    fun shutdown() {
        try {
            gm?.closeSession()
            gm?.unInit()
        } catch (e: Exception) {
            Log.w(TAG, "shutdown: ${e.message}")
        }
    }

    val available: Boolean get() = gm != null && connected

    // Breathing pulse across the C strip - buddy's "I'm in here" flourish.
    // cycles ~ how many breaths; period/interval shape each breath.
    fun pulse(cycles: Int) {
        val m = gm ?: return
        if (!connected) return
        try {
            m.openSession()
            val frame = m.glyphFrameBuilder
                .buildChannelC()
                .buildPeriod(900)
                .buildInterval(180)
                .buildCycles(cycles.coerceIn(1, 6))
                .build()
            m.animate(frame)
            // animate() runs async in the service; close the session after the
            // show is over so we release the interface for the system.
            android.os.Handler(context.mainLooper).postDelayed({
                try {
                    m.turnOff()
                    m.closeSession()
                } catch (e: Exception) { Log.w(TAG, "pulse cleanup: ${e.message}") }
            }, (900L + 180L) * cycles.coerceIn(1, 6) + 400L)
        } catch (e: Exception) {
            Log.w(TAG, "pulse: ${e.message}")
        }
    }
}
