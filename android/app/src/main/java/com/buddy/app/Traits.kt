package com.buddy.app

import android.content.Context
import org.json.JSONObject

// Personality sliders, replicated from the mac via the travel payload.
// Values clamp to 0..1; the real min/max bounds live with Pete on the mac.
object Traits {
    private const val PREFS = "traits"

    fun get(context: Context, name: String): Double =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(name, 0.5f).toDouble()

    fun all(context: Context): JSONObject {
        val out = JSONObject()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for ((k, v) in prefs.all) if (v is Float) out.put(k, v.toDouble())
        return out
    }

    fun set(context: Context, name: String, value: Double): Boolean {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putFloat(name, value.coerceIn(0.0, 1.0).toFloat()).apply()
        return true
    }

    fun replaceAll(context: Context, values: JSONObject) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (key in values.keys()) {
            editor.putFloat(key, values.optDouble(key, 0.5).coerceIn(0.0, 1.0).toFloat())
        }
        editor.apply()
    }
}
