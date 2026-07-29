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

    func reload() {
        generation += 1
        for (_, t) in timers { t.invalidate() }
        timers.removeAll()
        handlers.removeAll()
        loadMemory()

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

    func emit(_ name: String, _ payload: [String: Any] = [:]) {
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

        let moveTo: @convention(block) (Double, Double, Double) -> Void = { [weak self] x, y, speed in
            self?.controller?.moveTo(NSPoint(x: x, y: y), speed: speed > 0 ? speed : 120)
        }
        set("moveTo", moveTo)

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

        // Append-only access to feedback.md - lets Pete file notes through chat.
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
                               "commit", "-m", "feedback from pete (via chat)", "--", "feedback.md"]
                g.standardOutput = Pipe()
                g.standardError = Pipe()
                try? g.run()
                g.waitUntilExit()
                buddyLog("feedback committed (exit \(g.terminationStatus))")
            }
        }
        set("feedback", feedbackJS)

        // Push to Pete's phone. Heavily rate-limited natively.
        let phoneJS: @convention(block) (String) -> Bool = { [weak self] text in
            self?.controller?.phoneNotify(text) ?? false
        }
        set("phone", phoneJS)

        // Reply to a message Pete sent from his phone - lightly rate-limited,
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

        // buddy.prop("glasses") dons an accessory from sprites.json props;
        // buddy.prop(null) removes it.
        let propJS: @convention(block) (JSValue) -> Void = { [weak self] v in
            self?.controller?.setProp(v.isString ? v.toString() : nil)
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
        // Clamped to the trait's min/max bounds - for acting on Pete's chat
        // requests ("be quieter"). Bounds stay Pete-only.
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

        let thinkJS: @convention(block) (String, JSValue) -> Void = { [weak self] prompt, cb in
            guard let self else { return }
            let gen = self.generation
            self.think.ask(prompt) { [weak self] reply in
                guard let self, self.generation == gen else { return }
                cb.call(withArguments: [reply ?? NSNull()])
            }
        }
        set("think", thinkJS)

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
