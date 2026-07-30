package com.buddy.app

import android.content.Context
import org.json.JSONObject

// Personality sliders, replicated from the mac (values + drift bounds via
// the travel payload / state snapshots). Writes clamp to each trait's bounds,
// exactly like the mac's traits.json rules. Bounds are the human's; the phone
// never invents them - traits without known bounds clamp to 0..1.
object Traits {
    private const val PREFS = "traits"

    private fun specs(context: Context): JSONObject =
        try {
            JSONObject(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("specs", "{}") ?: "{}")
        } catch (e: Exception) { JSONObject() }

    private fun saveSpecs(context: Context, specs: JSONObject) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString("specs", specs.toString()).apply()
    }

    fun get(context: Context, name: String): Double =
        specs(context).optJSONObject(name)?.optDouble("value", 0.5) ?: 0.5

    fun bounds(context: Context, name: String): Pair<Double, Double> {
        val spec = specs(context).optJSONObject(name) ?: return 0.0 to 1.0
        return spec.optDouble("min", 0.0) to spec.optDouble("max", 1.0)
    }

    fun all(context: Context): JSONObject {
        val out = JSONObject()
        val s = specs(context)
        for (name in s.keys()) out.put(name, s.getJSONObject(name).optDouble("value", 0.5))
        return out
    }

    fun names(context: Context): List<String> {
        val preferred = listOf("mischief", "chattiness", "energy", "clinginess", "weirdness")
        val s = specs(context)
        val known = s.keys().asSequence().toList()
        return preferred.filter { known.contains(it) } +
            known.filter { !preferred.contains(it) }.sorted()
    }

    fun set(context: Context, name: String, value: Double): Boolean {
        val s = specs(context)
        val spec = s.optJSONObject(name) ?: JSONObject().put("min", 0.0).put("max", 1.0)
        val lo = spec.optDouble("min", 0.0)
        val hi = spec.optDouble("max", 1.0)
        spec.put("value", Math.round(value.coerceIn(lo, hi) * 100) / 100.0)
        s.put(name, spec)
        saveSpecs(context, s)
        return true
    }

    // Replication intake: full specs replace bounds+values; a values-only
    // payload merges into whatever bounds are already known.
    fun replaceSpecs(context: Context, incoming: JSONObject) {
        val out = JSONObject()
        for (name in incoming.keys()) {
            val spec = incoming.optJSONObject(name) ?: continue
            out.put(name, JSONObject()
                .put("value", spec.optDouble("value", 0.5))
                .put("min", spec.optDouble("min", 0.0))
                .put("max", spec.optDouble("max", 1.0)))
        }
        saveSpecs(context, out)
    }

    fun replaceAll(context: Context, values: JSONObject) {
        for (name in values.keys()) set(context, name, values.optDouble(name, 0.5))
    }
}
