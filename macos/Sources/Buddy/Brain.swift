import AppKit
import Foundation
import JavaScriptCore

// The buddy's behavior engine. All personality lives in ~/.buddy/brain/*.js;
// this class only provides the sandboxed `buddy` API and hot reload.
final class Brain {
    weak var controller: BuddyController?

    private struct Handler {
        let fn: JSValue
        let once: Bool
    }

    private var context: JSContext!
    private var handlers: [String: [Handler]] = [:]
    private var timers: [Int: Timer] = [:]
    private var nextTimerID = 1
    // Bumped on every reload so in-flight think() callbacks from a dead context are dropped.
    private var generation = 0
    private(set) var loadErrors = 0
    private var loading = false
    private var memory: [String: Any] = [:]
    private let think = Think()
    // Interactive lane: the human's chats get their own warm session so they never
    // queue behind ambient musings; recycled fast to keep context lean.
    private let thinkFast = Think(maxTurns: 12)

    // Spend config changed: restart (or shut down) the warm sessions so the
    // new model/enabled state applies immediately, not at next brain reload.
    func spendConfigChanged() {
        think.reset()
        thinkFast.reset()
    }

    // Registry sync audit defined in 00-core (brainSelfCheck): every advertised
    // test id needs a handler, every registered act a tests.json entry. Empty
    // when clean; a brain predating the function counts as clean.
    func selfCheck() -> [String] {
        guard let v = context?.evaluateScript(
            "typeof brainSelfCheck === 'function' ? brainSelfCheck() : []") else { return [] }
        return v.toArray() as? [String] ?? []
    }

    func reload() {
        generation += 1
        for (_, t) in timers { t.invalidate() }
        timers.removeAll()
        handlers.removeAll()
        // Placed props belong to the outgoing brain's acts; the new brain
        // re-places from memory, so clear instead of duplicating.
        controller?.unplaceAll()
        loadMemory()
        // Persona may have evolved - restart the warm think sessions on it.
        think.reset()
        thinkFast.reset()

        context = JSContext()
        context.exceptionHandler = { [weak self] _, exc in
            buddyLog("JS exception: \(exc?.toString() ?? "?")")
            if self?.loading == true { self?.loadErrors += 1 }
        }
        installAPI()

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: BuddyPaths.brain, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        loadErrors = 0
        loading = true
        for f in files {
            guard let src = try? String(contentsOf: f, encoding: .utf8) else { continue }
            context.evaluateScript(src, withSourceURL: f)
        }
        loading = false
        buddyLog("brain loaded (\(files.count) files, \(loadErrors) errors)")
        emit("brainLoaded", [:])
        if loadErrors > 0 {
            emit("brainDamaged", ["errors": loadErrors])
        }
    }

    // Whether the brain is mid-act (state.busy) - the anim watchdog leaves
    // poses alone while true.
    func isBusyState() -> Bool {
        context?.evaluateScript("!!(globalThis.state && state.busy)")?.toBool() ?? false
    }

    func emit(_ name: String, _ payload: [String: Any] = [:]) {
        buddyActivity("emit", ["name": name])
        guard let hs = handlers[name] else { return }
        // Drop once-handlers before calling so re-registration inside a handler works.
        handlers[name] = hs.filter { !$0.once }
        for h in hs {
            h.fn.call(withArguments: [payload])
        }
    }

    private func loadMemory() {
        if let data = try? Data(contentsOf: BuddyPaths.memory),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            memory = json
        }
    }

    private func saveMemory() {
        if let data = try? JSONSerialization.data(withJSONObject: memory, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: BuddyPaths.memory)
        }
    }

    private func installAPI() {
        let buddy = JSValue(newObjectIn: context)!

        func set(_ name: String, _ block: Any) {
            buddy.setObject(block, forKeyedSubscript: name as NSString)
        }

        let on: @convention(block) (String, JSValue) -> Void = { [weak self] name, fn in
            self?.handlers[name, default: []].append(Handler(fn: fn, once: false))
        }
        set("on", on)

        let once: @convention(block) (String, JSValue) -> Void = { [weak self] name, fn in
            self?.handlers[name, default: []].append(Handler(fn: fn, once: true))
        }
        set("once", once)

        let emitJS: @convention(block) (String, JSValue) -> Void = { [weak self] name, payload in
            let dict = payload.toDictionary() as? [String: Any] ?? [:]
            self?.emit(name, dict)
        }
        set("emit", emitJS)

        let log: @convention(block) (String) -> Void = { msg in
            buddyLog("brain: \(msg)")
        }
        set("log", log)

        // What is real on THIS device - the brain gates behaviors on it.
        // think reflects the spend config live: chat disabled = the brain
        // falls back to canned lines, exactly like a device with no claude.
        let caps: @convention(block) () -> [String: Bool] = {
            ["cursor": true, "windows": true, "layer": true, "music": true, "glyph": false,
             "think": Spend.load().chatEnabled, "phonePush": true, "feedback": true, "claudeEvents": true,
             "sfx": true, "place": true, "wear": true, "teleport": true,
             "tweet": Spend.load().tweetsEnabled]
        }
        set("caps", caps)

        // say(text, secs, prop?) - optional third arg wears a prop for the line.
        let say: @convention(block) (String, Double, JSValue) -> Void = { [weak self] text, secs, prop in
            self?.controller?.say(text, seconds: secs > 0 ? secs : 4,
                                  prop: prop.isString ? prop.toString() : nil)
        }
        set("say", say)

        let play: @convention(block) (String) -> Void = { [weak self] name in
            self?.controller?.play(name)
        }
        set("play", play)

        // Granted wish: short whitelisted sound (~/.buddy/sounds/<name>.wav).
        // Disruption-budgeted; returns false when denied or unknown.
        let sfxJS: @convention(block) (String) -> Bool = { [weak self] name in
            self?.controller?.sfx(name) ?? false
        }
        set("sfx", sfxJS)

        // Granted wish: post to buddy's own X account. The brain supplies
        // text only; the shell owns the 2/day cap, LLM safety gate, and
        // credentials. True = accepted into the pipeline (a "tweetPosted" or
        // "tweetRefused" event follows), false = refused outright.
        let tweetJS: @convention(block) (String) -> Bool = { [weak self] text in
            self?.controller?.tweet(text) ?? false
        }
        set("tweet", tweetJS)

        let moveTo: @convention(block) (Double, Double, Double) -> Void = { [weak self] x, y, speed in
            self?.controller?.moveTo(NSPoint(x: x, y: y), speed: speed > 0 ? speed : 120)
        }
        set("moveTo", moveTo)

        // Granted wish: instant blink. Emits "arrived" like moveTo so portal
        // choreography can drop it in where the ghost sprint used to be.
        let teleportJS: @convention(block) (Double, Double) -> Bool = { [weak self] x, y in
            self?.controller?.teleport(to: NSPoint(x: x, y: y)) ?? false
        }
        set("teleport", teleportJS)

        let stop: @convention(block) () -> Void = { [weak self] in
            self?.controller?.stopMoving()
        }
        set("stop", stop)

        let chase: @convention(block) (Double) -> Void = { [weak self] speed in
            self?.controller?.chaseCursor(speed: speed > 0 ? speed : 250)
        }
        set("chase", chase)

        // Live cursor-relative movement (emits "arrived") - use instead of
        // moveTo(cursor snapshot) for any go-near-the-cursor behavior.
        let approach: @convention(block) (Double, Double, Double) -> Void = { [weak self] speed, dx, dy in
            self?.controller?.approachCursor(speed: speed > 0 ? speed : 200, dx: dx, dy: dy)
        }
        set("approach", approach)

        let isMoving: @convention(block) () -> Bool = { [weak self] in
            self?.controller?.isMovingNow ?? false
        }
        set("isMoving", isMoving)

        // Append-only access to feedback.md - lets the human file notes through chat.
        // Deliberately not a general file-write.
        let feedbackJS: @convention(block) (String) -> Void = { text in
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let line = "- \(df.string(from: Date())): \(text) (via chat)\n"
            let url = BuddyPaths.brain.appendingPathComponent("feedback.md")
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile()
                if let d = line.data(using: .utf8) { h.write(d) }
                try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
            // Commit right away so runtime writes are never sitting loose in
            // the brain repo. (Nightly run.sh still sweeps up anything missed,
            // e.g. if commit signing is locked.)
            DispatchQueue.global(qos: .utility).async {
                let g = Process()
                g.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                g.arguments = ["-C", BuddyPaths.brain.path,
                               "commit", "-m", "feedback from the human (via chat)", "--", "feedback.md"]
                g.standardOutput = Pipe()
                g.standardError = Pipe()
                try? g.run()
                g.waitUntilExit()
                buddyLog("feedback committed (exit \(g.terminationStatus))")
            }
        }
        set("feedback", feedbackJS)

        // Push to the human's phone. Heavily rate-limited natively.
        let phoneJS: @convention(block) (String) -> Bool = { [weak self] text in
            self?.controller?.phoneNotify(text) ?? false
        }
        set("phone", phoneJS)

        // Real travel to a discovered peer device. cb(true) = target acked and
        // buddy is gone from this screen; cb(false) = no peer / timeout, stay.
        let travelJS: @convention(block) (String, JSValue) -> Void = { [weak self] line, cb in
            guard let self else { return }
            let gen = self.generation
            self.controller?.travelOut(line: line) { [weak self] ok in
                guard let self, self.generation == gen else { return }
                cb.call(withArguments: [ok])
            }
        }
        set("travel", travelJS)

        // Whether any peer device is reachable right now.
        let hasPeerJS: @convention(block) () -> Bool = { [weak self] in
            self?.controller?.coordination?.hasPeer ?? false
        }
        set("hasPeer", hasPeerJS)

        // Reply to a message the human sent from their phone - lightly rate-limited,
        // for use ONLY in response to phoneChat events.
        let phoneReplyJS: @convention(block) (String) -> Bool = { [weak self] text in
            self?.controller?.phoneReply(text) ?? false
        }
        set("phoneReply", phoneReplyJS)

        // buddy.music - narrow whitelisted verbs, Spotify or Apple Music.
        let musicObj = JSValue(newObjectIn: context)!
        let musicPlay: @convention(block) (JSValue) -> Bool = { [weak self] playlist in
            self?.controller?.musicPlay(playlist: playlist.isString ? playlist.toString() : nil) ?? false
        }
        musicObj.setObject(musicPlay, forKeyedSubscript: "play" as NSString)
        let musicPause: @convention(block) () -> Void = { [weak self] in
            self?.controller?.music.pause()
        }
        musicObj.setObject(musicPause, forKeyedSubscript: "pause" as NSString)
        let musicNext: @convention(block) () -> Bool = { [weak self] in
            self?.controller?.musicNext() ?? false
        }
        musicObj.setObject(musicNext, forKeyedSubscript: "next" as NSString)
        let musicStatus: @convention(block) (JSValue) -> Void = { [weak self] cb in
            guard let self else { return }
            let gen = self.generation
            self.controller?.music.status { [weak self] result in
                guard let self, self.generation == gen else { return }
                cb.call(withArguments: [result])
            }
        }
        musicObj.setObject(musicStatus, forKeyedSubscript: "status" as NSString)
        buddy.setObject(musicObj, forKeyedSubscript: "music" as NSString)

        // Granted wishes: window awareness + real hiding.
        let windows: @convention(block) () -> [[String: Any]] = { [weak self] in
            self?.controller?.windowList() ?? []
        }
        set("windows", windows)

        let layer: @convention(block) (String) -> Void = { [weak self] mode in
            self?.controller?.setLayer(behind: mode == "behind")
        }
        set("layer", layer)

        let opacity: @convention(block) (Double) -> Void = { [weak self] v in
            self?.controller?.setOpacity(v)
        }
        set("opacity", opacity)

        // Nothing Phone glyph lights - real only on the phone; stub here.
        let glyphJS: @convention(block) (Double) -> Void = { _ in }
        set("glyph", glyphJS)

        // Granted wish: persistent placed props (the hoard made visible).
        // place(name, x, y) pins a sprites.json prop to the screen until
        // removed - returns an id, 0 when refused (unknown prop, cap hit,
        // frozen/evolving/away). unplace(id) removes one; unplace() all.
        // Placements do not survive a brain reload - re-place from memory.
        let placeJS: @convention(block) (String, Double, Double) -> Int = { [weak self] name, x, y in
            self?.controller?.place(name, x: x, y: y) ?? 0
        }
        set("place", placeJS)

        let unplaceJS: @convention(block) (JSValue) -> Void = { [weak self] v in
            if v.isNumber {
                self?.controller?.unplace(Int(truncating: v.toNumber()))
            } else {
                self?.controller?.unplaceAll()
            }
        }
        set("unplace", unplaceJS)

        // placeMove(id, x, y) relocates a placed prop (returns false when
        // refused/unknown). The human can also drag placements by hand - those
        // drags emit "placementMoved", clicks emit "placementPoked"; the
        // brain's own placeMove calls do not echo back.
        let placeMoveJS: @convention(block) (Int, Double, Double) -> Bool = { [weak self] id, x, y in
            self?.controller?.placeMove(id, x: x, y: y) ?? false
        }
        set("placeMove", placeMoveJS)

        // placeSwap(id, propName) swaps a placement's art in place - no
        // unplace/place blink. Returns false when refused or unknown.
        let placeSwapJS: @convention(block) (Int, String) -> Bool = { [weak self] id, name in
            self?.controller?.placeSwap(id, to: name) ?? false
        }
        set("placeSwap", placeSwapJS)

        // wear(slot, name) - persistent accessory in a named slot ("hand" or
        // "head"), independent of speech: unlike a say() prop it survives the
        // bubble hiding and later prop-less says. wear(slot, null) removes it.
        // Returns false on unknown slot or prop.
        let wearJS: @convention(block) (String, JSValue) -> Bool = { [weak self] slot, v in
            self?.controller?.wear(slot, v.isString ? v.toString() : nil) ?? false
        }
        set("wear", wearJS)

        // buddy.prop("glasses") dons an accessory from sprites.json props;
        // buddy.prop(null) removes it. Legacy alias for wear("hand", ...).
        let propJS: @convention(block) (JSValue) -> Void = { [weak self] v in
            self?.controller?.wear("hand", v.isString ? v.toString() : nil)
        }
        set("prop", propJS)

        let pos: @convention(block) () -> [String: Double] = { [weak self] in
            let o = self?.controller?.spriteOrigin() ?? .zero
            return ["x": o.x, "y": o.y]
        }
        set("pos", pos)

        let screen: @convention(block) () -> [String: Double] = {
            let f = NSScreen.main?.visibleFrame ?? .zero
            return ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]
        }
        set("screen", screen)

        let isHeld: @convention(block) () -> Bool = { [weak self] in
            self?.controller?.held ?? false
        }
        set("isHeld", isHeld)

        let isFrozen: @convention(block) () -> Bool = { [weak self] in
            self?.controller?.isFrozen ?? false
        }
        set("isFrozen", isFrozen)

        // buddy.cursor
        let cursor = JSValue(newObjectIn: context)!
        let cursorPos: @convention(block) () -> [String: Double] = {
            let p = NSEvent.mouseLocation
            return ["x": p.x, "y": p.y]
        }
        cursor.setObject(cursorPos, forKeyedSubscript: "pos" as NSString)
        let cursorWarp: @convention(block) (Double, Double) -> Bool = { [weak self] x, y in
            self?.controller?.warpCursor(to: NSPoint(x: x, y: y)) ?? false
        }
        cursor.setObject(cursorWarp, forKeyedSubscript: "warp" as NSString)
        let cursorGrab: @convention(block) (Double) -> Bool = { [weak self] secs in
            self?.controller?.grabCursor(seconds: secs > 0 ? secs : 3) ?? false
        }
        cursor.setObject(cursorGrab, forKeyedSubscript: "grab" as NSString)
        buddy.setObject(cursor, forKeyedSubscript: "cursor" as NSString)

        // buddy.traits
        let traits = JSValue(newObjectIn: context)!
        let traitGet: @convention(block) (String) -> Double = { name in
            Traits.values()[name] ?? 0.5
        }
        traits.setObject(traitGet, forKeyedSubscript: "get" as NSString)
        let traitAll: @convention(block) () -> [String: Double] = {
            Traits.values()
        }
        traits.setObject(traitAll, forKeyedSubscript: "all" as NSString)
        // Clamped to the trait's min/max bounds - for acting on the human's chat
        // requests ("be quieter"). Bounds stay human-only.
        let traitSet: @convention(block) (String, Double) -> Bool = { name, value in
            Traits.setValue(name, to: value)
        }
        traits.setObject(traitSet, forKeyedSubscript: "set" as NSString)
        buddy.setObject(traits, forKeyedSubscript: "traits" as NSString)

        // buddy.memory
        let mem = JSValue(newObjectIn: context)!
        let memGet: @convention(block) (String) -> Any? = { [weak self] key in
            self?.memory[key]
        }
        mem.setObject(memGet, forKeyedSubscript: "get" as NSString)
        let memSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            if value.isNull || value.isUndefined {
                self.memory.removeValue(forKey: key)
            } else {
                self.memory[key] = value.toObject()
            }
            self.saveMemory()
        }
        mem.setObject(memSet, forKeyedSubscript: "set" as NSString)
        buddy.setObject(mem, forKeyedSubscript: "memory" as NSString)

        // Read-only JSON loader, restricted to files directly inside the brain dir.
        let dataJS: @convention(block) (String) -> Any? = { name in
            guard !name.contains("/"), !name.contains(".."), name.hasSuffix(".json") else { return nil }
            let url = BuddyPaths.brain.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        set("data", dataJS)

        // Raw-text sibling of data() for the brain's .md files (persona,
        // wishes) - chat feeds these to the LLM. Same directory jail.
        let textJS: @convention(block) (String) -> Any? = { name in
            guard !name.contains("/"), !name.contains(".."), name.hasSuffix(".md") else { return nil }
            let url = BuddyPaths.brain.appendingPathComponent(name)
            return try? String(contentsOf: url, encoding: .utf8)
        }
        set("text", textJS)

        // User preference values (~/.buddy/config.json) - outside the brain repo
        // on purpose: the mutator's failed-evolution revert wipes the brain dir,
        // and user preferences must survive that. Schema lives in the brain
        // (config-schema.json); cfg() in 00-core merges the two.
        let userConfigJS: @convention(block) () -> Any? = {
            guard let data = try? Data(contentsOf: BuddyPaths.config) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        set("userConfig", userConfigJS)

        // The one fenced crossing of the two-pen rule: the brain may record a
        // declared fact, but only one the human just explicitly confirmed
        // (chat "yes" to a promotion question) - contract in mutator/prompt.md.
        let configSetJS: @convention(block) (String, JSValue) -> Void = { key, value in
            let obj = (value.isNull || value.isUndefined) ? nil : value.toObject()
            UserConfig.set(key, obj)
            buddyActivity("configSet", ["key": key])
        }
        set("configSet", configSetJS)

        let thinkJS: @convention(block) (String, JSValue) -> Void = { [weak self] prompt, cb in
            guard let self else { return }
            let gen = self.generation
            self.think.ask(prompt) { [weak self] reply in
                guard let self, self.generation == gen else { return }
                cb.call(withArguments: [reply ?? NSNull()])
            }
        }
        set("think", thinkJS)

        // Interactive lane - for replying to the human, never blocked by ambient.
        let thinkNowJS: @convention(block) (String, JSValue) -> Void = { [weak self] prompt, cb in
            guard let self else { return }
            let gen = self.generation
            self.thinkFast.ask(prompt) { [weak self] reply in
                guard let self, self.generation == gen else { return }
                cb.call(withArguments: [reply ?? NSNull()])
            }
        }
        set("thinkNow", thinkNowJS)

        let after: @convention(block) (Double, JSValue) -> Int = { [weak self] ms, fn in
            self?.addTimer(ms: ms, repeats: false, fn: fn) ?? 0
        }
        set("after", after)

        let every: @convention(block) (Double, JSValue) -> Int = { [weak self] ms, fn in
            self?.addTimer(ms: ms, repeats: true, fn: fn) ?? 0
        }
        set("every", every)

        let cancel: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers[id]?.invalidate()
            self?.timers.removeValue(forKey: id)
        }
        set("cancel", cancel)

        context.setObject(buddy, forKeyedSubscript: "buddy" as NSString)
    }

    private func addTimer(ms: Double, repeats: Bool, fn: JSValue) -> Int {
        let id = nextTimerID
        nextTimerID += 1
        let t = commonTimer(max(0.05, ms / 1000), repeats: repeats) { [weak self] _ in
            if !repeats {
                self?.timers.removeValue(forKey: id)
            }
            _ = fn.call(withArguments: [])
        }
        timers[id] = t
        return id
    }
}
