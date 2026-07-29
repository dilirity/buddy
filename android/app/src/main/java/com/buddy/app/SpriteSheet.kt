package com.buddy.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import org.json.JSONObject

// Same sprites.json as the mac shell (bundled in assets, synced from the
// brain). Pixel-grid frames + palette; rendered to scaled bitmaps on demand.
class SpriteSheet(context: Context) {
    data class Anim(val fps: Int, val loop: Boolean, val frames: List<List<String>>)

    private val palette = HashMap<Char, Int>()
    val anims = HashMap<String, Anim>()
    val props = HashMap<String, List<String>>()
    val pixelW: Int
    val pixelH: Int
    private val bitmapCache = HashMap<String, Bitmap>()

    init {
        val json = JSONObject(context.assets.open("sprites.json").bufferedReader().readText())
        val pal = json.getJSONObject("palette")
        for (key in pal.keys()) {
            val v = pal.getString(key)
            palette[key[0]] = if (v == "transparent") Color.TRANSPARENT else Color.parseColor(v)
        }
        val propsJson = json.optJSONObject("props")
        if (propsJson != null) {
            for (name in propsJson.keys()) {
                val rows = propsJson.getJSONArray(name)
                props[name] = (0 until rows.length()).map { rows.getString(it) }
            }
        }
        val a = json.getJSONObject("anims")
        for (name in a.keys()) {
            val o = a.getJSONObject(name)
            val framesJson = o.getJSONArray("frames")
            val frames = ArrayList<List<String>>()
            for (i in 0 until framesJson.length()) {
                val rowsJson = framesJson.getJSONArray(i)
                frames.add((0 until rowsJson.length()).map { rowsJson.getString(it) })
            }
            anims[name] = Anim(o.optInt("fps", 4), o.optBoolean("loop", true), frames)
        }
        val first = anims["idle"]?.frames?.firstOrNull() ?: emptyList()
        pixelH = first.size
        pixelW = first.firstOrNull()?.length ?: 0
    }

    fun frame(anim: String, index: Int, scale: Int, flip: Boolean, prop: String? = null): Bitmap? {
        val a = anims[anim] ?: return null
        val idx = index.coerceIn(0, a.frames.size - 1)
        val key = "$anim:$idx:$scale:$flip:$prop"
        bitmapCache[key]?.let { return it }
        val rows = a.frames[idx]
        val h = rows.size
        val w = rows.firstOrNull()?.length ?: return null
        val bmp = Bitmap.createBitmap(w * scale, h * scale, Bitmap.Config.ARGB_8888)
        fun paint(grid: List<String>) {
            for (y in 0 until minOf(h, grid.size)) {
                val row = grid[y]
                for (x in 0 until minOf(w, row.length)) {
                    val ch = if (flip) row[w - 1 - x] else row[x]
                    val color = palette[ch] ?: Color.TRANSPARENT
                    if (color == Color.TRANSPARENT) continue
                    for (py in 0 until scale) {
                        for (px in 0 until scale) {
                            bmp.setPixel(x * scale + px, y * scale + py, color)
                        }
                    }
                }
            }
        }
        paint(rows)
        prop?.let { props[it] }?.let { paint(it) } // accessory composited on top
        bitmapCache[key] = bmp
        return bmp
    }
}
