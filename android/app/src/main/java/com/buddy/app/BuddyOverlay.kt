package com.buddy.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView

// Floating buddy: sprite view + speech bubble as overlay windows.
// Phone-native body: perches at screen edges, draggable, long-press sends
// buddy home to the mac.
@SuppressLint("ClickableViewAccessibility")
class BuddyOverlay(
    private val context: Context,
    private val sheet: SpriteSheet,
    private val onSendHome: () -> Unit,
) {
    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val ui = Handler(Looper.getMainLooper())
    private val scale = 14

    private var anim = "idle"
    private var frame = 0
    private var facingLeft = false
    private var oneShotDone: (() -> Unit)? = null
    private var shown = false
    private var longPressStart = 0L

    private val view = object : View(context) {
        override fun onDraw(canvas: Canvas) {
            sheet.frame(anim, frame, scale, facingLeft)?.let {
                canvas.drawBitmap(it, 0f, 0f, null)
            }
        }
    }
    private val bubble = TextView(context).apply {
        setBackgroundColor(Color.parseColor("#1a1a24"))
        setTextColor(Color.parseColor("#e8e8f0"))
        setPadding(28, 20, 28, 20)
        textSize = 15f
        visibility = View.GONE
    }

    private val viewParams = WindowManager.LayoutParams(
        sheet.pixelW * scale, sheet.pixelH * scale,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT
    ).apply { gravity = Gravity.TOP or Gravity.START }

    private val bubbleParams = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
        PixelFormat.TRANSLUCENT
    ).apply { gravity = Gravity.TOP or Gravity.START }

    private val ticker = object : Runnable {
        override fun run() {
            val a = sheet.anims[anim] ?: return
            frame++
            if (frame >= a.frames.size) {
                if (!a.loop) {
                    frame = a.frames.size - 1
                    val done = oneShotDone
                    oneShotDone = null
                    done?.invoke()
                } else {
                    frame = 0
                }
            }
            view.invalidate()
            if (shown) ui.postDelayed(this, 1000L / (sheet.anims[anim]?.fps ?: 4))
        }
    }

    init {
        view.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    longPressStart = System.currentTimeMillis()
                    play("held")
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    viewParams.x = (ev.rawX - view.width / 2).toInt()
                    viewParams.y = (ev.rawY - view.height / 2).toInt()
                    wm.updateViewLayout(view, viewParams)
                    positionBubble()
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (System.currentTimeMillis() - longPressStart > 1200) {
                        say("ok ok. going home", 3)
                        onSendHome()
                    } else {
                        play("excited")
                        ui.postDelayed({ if (anim == "excited") play("idle") }, 2000)
                    }
                    true
                }
                else -> false
            }
        }
    }

    fun show(line: String?) {
        if (!shown) {
            shown = true
            val dm = context.resources.displayMetrics
            viewParams.x = dm.widthPixels / 2 - sheet.pixelW * scale / 2
            viewParams.y = dm.heightPixels / 2
            wm.addView(view, viewParams)
            wm.addView(bubble, bubbleParams)
            ui.post(ticker)
        }
        val entrance = if (sheet.anims.containsKey("portalout")) "portalout" else "walk.in"
        playOnce(entrance) {
            play("excited")
            line?.let { say(it, 8) }
            ui.postDelayed({ if (anim == "excited") play("idle") }, 2500)
        }
    }

    fun hide() {
        if (!shown) return
        shown = false
        wm.removeView(view)
        wm.removeView(bubble)
    }

    fun play(name: String) {
        anim = if (sheet.anims.containsKey(name)) name else "idle"
        frame = 0
        oneShotDone = null
    }

    private fun playOnce(name: String, done: () -> Unit) {
        play(name)
        oneShotDone = done
    }

    fun say(text: String, secs: Int) {
        bubble.text = text
        bubble.visibility = View.VISIBLE
        positionBubble()
        ui.removeCallbacks(hideBubble)
        ui.postDelayed(hideBubble, secs * 1000L)
    }

    private val hideBubble = Runnable { bubble.visibility = View.GONE }

    private fun positionBubble() {
        bubbleParams.x = viewParams.x - 40
        bubbleParams.y = viewParams.y - 140
        if (bubble.parent != null) wm.updateViewLayout(bubble, bubbleParams)
    }
}
