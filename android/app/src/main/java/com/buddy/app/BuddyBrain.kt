package com.buddy.app

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.whl.quickjs.android.QuickJSLoader
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.JSFunction
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.QuickJSContext
import org.json.JSONObject
import java.io.File

// The same brain JS the mac runs, hosted in QuickJS. Implements the buddy.*
// contract from protocol/shell-api.md; verbs whose actuator the phone lacks
// no-op and return their failure value, events the phone cannot sense are
// never emitted. All JS runs on one dedicated thread - QuickJS is not
// thread-safe, emit() from any thread trampolines onto it.
class BuddyBrain(private val appContext: Context, private val shell: Shell) {
    companion object { const val TAG = "BuddyBrain" }

    // What the service must provide. All called on the MAIN thread.
    interface Shell {
        fun say(text: String, secs: Double, prop: String?)
        fun play(anim: String)
        fun moveTo(x: Double, y: Double, speed: Double)
        fun stopMoving()
        fun isMoving(): Boolean
        fun setOpacity(v: Double)
        fun setProp(name: String?)
        fun pos(): Pair<Double, Double>
        fun screen(): DoubleArray // x, y, w, h
        fun isHeld(): Boolean
        fun phoneNotify(text: String): Boolean
        fun phoneReply(text: String): Boolean
        fun isFrozen(): Boolean
    }

    private val thread = HandlerThread("buddy-brain").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(appContext.mainLooper)

    private var ctx: QuickJSContext? = null
    private val handlers = HashMap<String, MutableList<Pair<JSFunction, Boolean>>>()
    private val timers = HashMap<Int, Runnable>()
    private var nextTimerId = 1
    var loadErrors = 0
        private set

    private val brainDir = File(appContext.filesDir, "brain")
    private val memoryFile = File(appContext.filesDir, "memory.json")
    private var memory = JSONObject()

    fun start() {
        handler.post {
            seedBrainFromAssets()
            reload()
        }
    }

    fun shutdown() {
        handler.post {
            ctx?.destroy()
            ctx = null
            thread.quitSafely()
        }
    }

    // Seed bundled brain files once; never overwrite an existing (possibly
    // synced/evolved) file - same rule as the mac installer.
    private fun seedBrainFromAssets() {
        brainDir.mkdirs()
        val assets = appContext.assets
        for (name in assets.list("brain") ?: emptyArray()) {
            val dst = File(brainDir, name)
            if (!dst.exists()) {
                assets.open("brain/$name").use { input ->
                    dst.outputStream().use { input.copyTo(it) }
                }
            }
        }
    }

    fun reload() {
        handler.post {
            timers.values.forEach { handler.removeCallbacks(it) }
            timers.clear()
            handlers.clear()
            ctx?.destroy()
            loadMemory()

            QuickJSLoader.init()
            val c = QuickJSContext.create()
            ctx = c
            installAPI(c)

            loadErrors = 0
            val files = brainDir.listFiles { f -> f.name.endsWith(".js") }
                ?.sortedBy { it.name } ?: emptyList()
            for (f in files) {
                try {
                    c.evaluate(f.readText(), f.name)
                } catch (e: Exception) {
                    loadErrors++
                    Log.w(TAG, "JS exception in ${f.name}: ${e.message}")
                }
            }
            Log.i(TAG, "brain loaded (${files.size} files, $loadErrors errors)")
            emitOnThread("brainLoaded", null)
            if (loadErrors > 0) emitOnThread("brainDamaged", JSONObject().put("errors", loadErrors))
        }
    }

    // MARK: - Events

    fun emit(name: String, payload: JSONObject? = null) {
        handler.post { emitOnThread(name, payload) }
    }

    private fun emitOnThread(name: String, payload: JSONObject?) {
        val c = ctx ?: return
        val hs = handlers[name] ?: return
        handlers[name] = hs.filter { !it.second }.toMutableList()
        val arg = c.parseJSON((payload ?: JSONObject()).toString())
        for ((fn, _) in hs) {
            try {
                fn.call(arg)
            } catch (e: Exception) {
                Log.w(TAG, "JS exception in handler $name: ${e.message}")
            }
        }
    }

    // MARK: - API surface

    // The no-crash contract: a mutated brain must be UNABLE to kill the shell.
    // Every verb body runs through this - bad args log and return null, never
    // propagate.
    private fun jsFn(name: String, body: (Array<out Any?>) -> Any?) = JSCallFunction { args ->
        try {
            body(args)
        } catch (e: Exception) {
            Log.w(TAG, "verb $name: ${e.message}")
            null
        }
    }

    private fun installAPI(c: QuickJSContext) {
        val buddy = c.createNewJSObject()

        buddy.setProperty("on", jsFn("on") { args ->
            val name = args[0] as String
            val fn = args[1] as JSFunction
            fn.hold()
            handlers.getOrPut(name) { mutableListOf() }.add(fn to false)
            null
        })
        buddy.setProperty("once", jsFn("once") { args ->
            val name = args[0] as String
            val fn = args[1] as JSFunction
            fn.hold()
            handlers.getOrPut(name) { mutableListOf() }.add(fn to true)
            null
        })
        buddy.setProperty("emit", jsFn("emit") { args ->
            val name = args[0] as String
            val payload = if (args.size > 1 && args[1] is JSObject)
                JSONObject((args[1] as JSObject).stringify()) else null
            emitOnThread(name, payload)
            null
        })
        buddy.setProperty("log", jsFn("log") { args ->
            Log.i(TAG, "brain: ${args.getOrNull(0)}")
            null
        })

        // What is real on THIS device - the brain gates behaviors on it.
        buddy.setProperty("caps", jsFn("caps") { _ -> 
            c.parseJSON(
                """{"cursor":false,"windows":false,"layer":false,"music":false,""" +
                """"think":false,"phonePush":true,"feedback":true,"claudeEvents":false}"""
            )
        })

        // Speech and looks
        buddy.setProperty("say", jsFn("say") { args ->
            val text = args[0] as String
            val secs = (args.getOrNull(1) as? Number)?.toDouble() ?: 4.0
            val prop = args.getOrNull(2) as? String
            main.post { shell.say(text, if (secs > 0) secs else 4.0, prop) }
            null
        })
        buddy.setProperty("play", jsFn("play") { args ->
            val name = args[0] as String
            main.post { shell.play(name) }
            null
        })
        buddy.setProperty("prop", jsFn("prop") { args ->
            val name = args.getOrNull(0) as? String
            main.post { shell.setProp(name) }
            null
        })
        buddy.setProperty("opacity", jsFn("opacity") { args ->
            val v = (args[0] as Number).toDouble()
            main.post { shell.setOpacity(v) }
            null
        })
        buddy.setProperty("layer", jsFn("layer") { _ ->  null }) // no window layers on a phone

        // Movement
        buddy.setProperty("moveTo", jsFn("moveTo") { args ->
            val x = (args[0] as Number).toDouble()
            val y = (args[1] as Number).toDouble()
            val speed = ((args.getOrNull(2) as? Number)?.toDouble() ?: 120.0)
            main.post { shell.moveTo(x, y, if (speed > 0) speed else 120.0) }
            null
        })
        buddy.setProperty("stop", jsFn("stop") { _ -> 
            main.post { shell.stopMoving() }
            null
        })
        buddy.setProperty("chase", jsFn("chase") { _ ->  null })    // no cursor; never emits "caught"
        buddy.setProperty("approach", jsFn("approach") { _ ->  null }) // no cursor; never emits "arrived"
        buddy.setProperty("isMoving", jsFn("isMoving") { _ ->  shell.isMoving() })
        buddy.setProperty("pos", jsFn("pos") { _ -> 
            val (x, y) = shell.pos()
            c.parseJSON("""{"x":$x,"y":$y}""")
        })
        buddy.setProperty("screen", jsFn("screen") { _ -> 
            val s = shell.screen()
            c.parseJSON("""{"x":${s[0]},"y":${s[1]},"w":${s[2]},"h":${s[3]}}""")
        })
        buddy.setProperty("isHeld", jsFn("isHeld") { _ ->  shell.isHeld() })
        buddy.setProperty("isFrozen", jsFn("isFrozen") { _ ->  shell.isFrozen() })

        // Cursor: phone has none - documented no-ops.
        val cursor = c.createNewJSObject()
        cursor.setProperty("pos", jsFn("pos") { _ ->  c.parseJSON("""{"x":0,"y":0}""") })
        cursor.setProperty("warp", jsFn("warp") { _ ->  false })
        cursor.setProperty("grab", jsFn("grab") { _ ->  false })
        buddy.setProperty("cursor", cursor)

        // Windows: not sensable on Android v1.
        buddy.setProperty("windows", jsFn("windows") { _ ->  c.parseJSON("[]") })

        // Phone: buddy IS on the phone - "texting Pete" is a local notification.
        buddy.setProperty("phone", jsFn("phone") { args ->
            shell.phoneNotify(args[0] as String)
        })
        buddy.setProperty("phoneReply", jsFn("phoneReply") { args ->
            shell.phoneReply(args[0] as String)
        })

        // Music: no whitelisted player integration on the phone yet.
        val music = c.createNewJSObject()
        music.setProperty("play", jsFn("play") { _ ->  false })
        music.setProperty("pause", jsFn("pause") { _ ->  null })
        music.setProperty("next", jsFn("next") { _ ->  false })
        music.setProperty("status", jsFn("status") { args ->
            (args.getOrNull(0) as? JSFunction)?.let { cb ->
                cb.hold()
                handler.post {
                    try { cb.call(c.parseJSON("""{"app":"none","state":"unavailable"}""")) }
                    catch (e: Exception) { Log.w(TAG, "status cb: ${e.message}") }
                }
            }
            null
        })
        buddy.setProperty("music", music)

        // Traits: replicated from the travel payload; clamped 0..1 locally.
        val traits = c.createNewJSObject()
        traits.setProperty("get", jsFn("get") { args ->
            Traits.get(appContext, args[0] as String)
        })
        traits.setProperty("all", jsFn("all") { _ -> 
            c.parseJSON(Traits.all(appContext).toString())
        })
        traits.setProperty("set", jsFn("set") { args ->
            Traits.set(appContext, args[0] as String, (args[1] as Number).toDouble())
        })
        buddy.setProperty("traits", traits)

        // Memory: persisted JSON key-value, mirrors ~/.buddy/memory.json.
        val mem = c.createNewJSObject()
        mem.setProperty("get", jsFn("get") { args ->
            val v = memory.opt(args[0] as String) ?: return@JSCallFunction null
            when (v) {
                is JSONObject -> c.parseJSON(v.toString())
                is org.json.JSONArray -> c.parseJSON(v.toString())
                else -> v
            }
        })
        mem.setProperty("set", jsFn("set") { args ->
            val key = args[0] as String
            val value = args.getOrNull(1)
            if (value == null) memory.remove(key)
            else memory.put(key, if (value is JSObject) JSONObject(value.stringify()) else value)
            saveMemory()
            null
        })
        buddy.setProperty("memory", mem)

        // Read-only JSON loader, brain dir only - same restrictions as mac.
        buddy.setProperty("data", jsFn("data") { args ->
            val name = args[0] as String
            if (name.contains("/") || name.contains("..") || !name.endsWith(".json"))
                return@JSCallFunction null
            val f = File(brainDir, name)
            if (!f.exists()) return@JSCallFunction null
            try { c.parseJSON(f.readText()) } catch (e: Exception) { null }
        })

        // Append-only feedback, mirrors the mac verb (no git on the phone;
        // the file rides replication back later).
        buddy.setProperty("feedback", jsFn("feedback") { args ->
            val date = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                .format(java.util.Date())
            File(brainDir, "feedback.md").appendText("- $date: ${args[0]} (via chat)\n")
            null
        })

        // No claude CLI on the phone: think() answers null, which the brain
        // already treats as "no thought available".
        buddy.setProperty("think", jsFn("think") { args ->
            (args.getOrNull(1) as? JSFunction)?.let { cb ->
                cb.hold()
                handler.post {
                    try { cb.call() } catch (e: Exception) { Log.w(TAG, "think cb: ${e.message}") }
                }
            }
            null
        })

        // Timers - all on the brain thread.
        buddy.setProperty("after", jsFn("after") { args ->
            addTimer((args[0] as Number).toLong(), false, args[1] as JSFunction)
        })
        buddy.setProperty("every", jsFn("every") { args ->
            addTimer((args[0] as Number).toLong(), true, args[1] as JSFunction)
        })
        buddy.setProperty("cancel", jsFn("cancel") { args ->
            val id = (args[0] as Number).toInt()
            timers.remove(id)?.let { handler.removeCallbacks(it) }
            null
        })

        c.getGlobalObject().setProperty("buddy", buddy)
    }

    private fun addTimer(ms: Long, repeats: Boolean, fn: JSFunction): Int {
        fn.hold()
        val id = nextTimerId++
        val delay = maxOf(50L, ms)
        val r = object : Runnable {
            override fun run() {
                if (!repeats) timers.remove(id)
                try { fn.call() } catch (e: Exception) { Log.w(TAG, "timer JS: ${e.message}") }
                if (repeats && timers.containsKey(id)) handler.postDelayed(this, delay)
            }
        }
        timers[id] = r
        handler.postDelayed(r, delay)
        return id
    }

    private fun loadMemory() {
        memory = try { JSONObject(memoryFile.readText()) } catch (e: Exception) { JSONObject() }
    }

    private fun saveMemory() {
        try { memoryFile.writeText(memory.toString(2)) } catch (e: Exception) {
            Log.w(TAG, "memory save: $e")
        }
    }
}
