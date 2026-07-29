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
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sign

// Floating buddy: sprite view + speech bubble as overlay windows. The brain
// drives it through BuddyBrain.Shell; touch gestures feed events back.
// Long-press stays a native shell gesture (send home), like the mac menu.
@SuppressLint("ClickableViewAccessibility")
open class BuddyOverlay(
    private val context: Context,
    private val sheet: SpriteSheet,
    private val onSendHome: () -> Unit,
    private val onEvent: (String, org.json.JSONObject?) -> Unit,
) : BuddyBrain.Shell {
    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val ui = Handler(Looper.getMainLooper())
    private val scale = 14

    private var anim = "idle"
    private var frame = 0
    private var facingLeft = false
    private var currentProp: String? = null
    private var oneShotDone: (() -> Unit)? = null
    private var shown = false
    private var held = false
    private var dragMoved = false
    private var downTime = 0L

    // Movement (60fps stepper, mirrors the mac's move timer semantics)
    private var targetX = 0.0
    private var targetY = 0.0
    private var moving = false
    private var speed = 120.0

    private val view = object : View(context) {
        override fun onDraw(canvas: Canvas) {
            sheet.frame(anim, frame, scale, facingLeft, currentProp)?.let {
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

    private val animTicker = object : Runnable {
        override fun run() {
            if (!shown) return
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
            ui.postDelayed(this, 1000L / (sheet.anims[anim]?.fps ?: 4))
        }
    }

    private val moveTicker = object : Runnable {
        override fun run() {
            if (!shown || !moving) return
            val dx = targetX - viewParams.x
            val dy = targetY - viewParams.y
            val dist = hypot(dx, dy)
            val step = speed / 60.0 * context.resources.displayMetrics.density
            if (dist <= step) {
                viewParams.x = targetX.toInt()
                viewParams.y = targetY.toInt()
                moving = false
                wm.updateViewLayout(view, viewParams)
                onEvent("arrived", null)
            } else {
                viewParams.x += (dx / dist * step).toInt().let { if (it == 0) sign(dx).toInt() else it }
                viewParams.y += (dy / dist * step).toInt().let { if (it == 0) sign(dy).toInt() else it }
                if (abs(dx) > 2) facingLeft = dx < 0
                wm.updateViewLayout(view, viewParams)
                ui.postDelayed(this, 16)
            }
            positionBubble()
        }
    }

    init {
        view.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    downTime = System.currentTimeMillis()
                    dragMoved = false
                    held = true
                    moving = false
                    play("held")
                    onEvent("dragStart", null)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val nx = (ev.rawX - view.width / 2).toInt()
                    val ny = (ev.rawY - view.height / 2).toInt()
                    if (abs(nx - viewParams.x) > 8 || abs(ny - viewParams.y) > 8) dragMoved = true
                    viewParams.x = nx
                    viewParams.y = ny
                    wm.updateViewLayout(view, viewParams)
                    positionBubble()
                    true
                }
                MotionEvent.ACTION_UP -> {
                    held = false
                    val heldMs = System.currentTimeMillis() - downTime
                    when {
                        !dragMoved && heldMs > 1200 -> {
                            say("ok ok. going home", 3.0, null)
                            onSendHome()
                        }
                        !dragMoved -> {
                            play("excited")
                            onEvent("poked", null)
                            ui.postDelayed({ if (anim == "excited") play("idle") }, 2000)
                        }
                        else -> {
                            play("idle")
                            onEvent("dragEnd", org.json.JSONObject()
                                .put("x", viewParams.x).put("y", viewParams.y))
                        }
                    }
                    true
                }
                else -> false
            }
        }
    }

    // MARK: - Show / hide

    fun show(line: String?, onSettled: (() -> Unit)? = null) {
        if (!shown) {
            shown = true
            val dm = context.resources.displayMetrics
            viewParams.x = dm.widthPixels / 2 - sheet.pixelW * scale / 2
            viewParams.y = dm.heightPixels / 2
            wm.addView(view, viewParams)
            wm.addView(bubble, bubbleParams)
            ui.post(animTicker)
        }
        val entrance = if (sheet.anims.containsKey("portalout")) "portalout" else "walk.in"
        playOnce(entrance) {
            play("excited")
            line?.let { say(it, 8.0, null) }
            ui.postDelayed({ if (anim == "excited") play("idle") }, 2500)
            onSettled?.invoke()
        }
    }

    fun hide() {
        if (!shown) return
        shown = false
        moving = false
        wm.removeView(view)
        wm.removeView(bubble)
    }

    // MARK: - BuddyBrain.Shell

    override fun say(text: String, secs: Double, prop: String?) {
        if (!shown) return
        prop?.let { setProp(it) }
        bubble.text = text
        bubble.visibility = View.VISIBLE
        positionBubble()
        ui.removeCallbacks(hideBubble)
        ui.postDelayed(hideBubble, (secs * 1000).toLong())
    }

    override fun play(name: String) {
        anim = if (sheet.anims.containsKey(name)) name else "idle"
        frame = 0
        oneShotDone = null
    }

    override fun moveTo(x: Double, y: Double, speed: Double) {
        if (!shown || held) return
        val dm = context.resources.displayMetrics
        targetX = x.coerceIn(0.0, (dm.widthPixels - view.width).toDouble())
        targetY = y.coerceIn(0.0, (dm.heightPixels - view.height).toDouble())
        this.speed = speed
        if (!moving) {
            moving = true
            play("walk")
            ui.post(moveTicker)
        }
    }

    override fun stopMoving() {
        moving = false
        if (anim == "walk") play("idle")
    }

    override fun isMoving(): Boolean = moving

    override fun setOpacity(v: Double) {
        view.alpha = v.toFloat().coerceIn(0f, 1f)
    }

    override fun setProp(name: String?) {
        currentProp = if (name != null && sheet.props.containsKey(name)) name else null
        view.invalidate()
    }

    override fun pos(): Pair<Double, Double> =
        viewParams.x.toDouble() to viewParams.y.toDouble()

    override fun screen(): DoubleArray {
        val dm = context.resources.displayMetrics
        return doubleArrayOf(0.0, 0.0, dm.widthPixels.toDouble(), dm.heightPixels.toDouble())
    }

    override fun isHeld(): Boolean = held

    override fun phoneNotify(text: String): Boolean = false // service subclass overrides
    open override fun phoneReply(text: String): Boolean = false

    private fun playOnce(name: String, done: () -> Unit) {
        play(name)
        oneShotDone = done
    }

    private val hideBubble = Runnable {
        bubble.visibility = View.GONE
        setProp(null)
    }

    private fun positionBubble() {
        bubbleParams.x = maxOf(8, viewParams.x - 40)
        bubbleParams.y = maxOf(8, viewParams.y - 150)
        if (bubble.parent != null) wm.updateViewLayout(bubble, bubbleParams)
    }
}
