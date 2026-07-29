import AppKit

// Feeds the brain: Claude Code hook events, ambient system signals,
// and awareness of anyone editing buddy's own config/brain files.
final class Senses {
    weak var controller: BuddyController?

    private var timers: [Timer] = []
    private var eventsOffset: UInt64 = 0
    private var traitsSnapshot: [String: Double] = [:]
    private var brainSignature = ""
    private var idle = false
    private var keyMonitor: Any?
    private var lastEsc = Date.distantPast
    private var keystrokes = 0

    func start() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: BuddyPaths.events.path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value {
            eventsOffset = size
        }
        traitsSnapshot = Traits.values()
        brainSignature = Self.currentBrainSignature()

        schedule(0.5) { [weak self] in self?.pollEvents() }
        schedule(2.0) { [weak self] in self?.pollEvolveLock() }
        schedule(2.0) { [weak self] in self?.pollTraits() }
        schedule(2.0) { [weak self] in self?.pollBrain() }
        schedule(5.0) { [weak self] in self?.pollIdle() }
        schedule(10.0) { [weak self] in self?.flushTyping() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.controller?.brain.emit("appChanged", ["name": app.localizedName ?? "?"])
        }

        // Needs Input Monitoring/Accessibility permission; silently inert without it.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.handleKey(e)
        }
    }

    private func schedule(_ interval: TimeInterval, _ fn: @escaping () -> Void) {
        let t = commonTimer(interval, repeats: true) { _ in fn() }
        timers.append(t)
    }

    private func handleKey(_ e: NSEvent) {
        if e.keyCode == 53 { // esc
            let now = Date()
            if now.timeIntervalSince(lastEsc) < 0.5 {
                lastEsc = .distantPast
                controller?.togglePanic()
                return
            }
            lastEsc = now
            return
        }
        keystrokes += 1
    }

    private func flushTyping() {
        guard keystrokes > 0 else { return }
        let n = keystrokes
        keystrokes = 0
        if n >= 30 {
            controller?.brain.emit("typing", ["keys": n])
        }
    }

    private func pollEvents() {
        guard let h = FileHandle(forReadingAtPath: BuddyPaths.events.path) else { return }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        if size < eventsOffset { eventsOffset = 0 } // truncated/rotated
        guard size > eventsOffset else { return }
        h.seek(toFileOffset: eventsOffset)
        let data = h.readData(ofLength: Int(size - eventsOffset))
        eventsOffset = size
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let name = json["_event"] as? String ?? "unknown"
            controller?.brain.emit("claude:\(name)", json)
        }
    }

    // Called after an evolution run: adopt the new state silently so buddy
    // doesn't grudge-comment its own mutations.
    func resync() {
        brainSignature = Self.currentBrainSignature()
        traitsSnapshot = Traits.values()
    }

    private var evolveLockSeen = false

    private func pollEvolveLock() {
        let exists = FileManager.default.fileExists(atPath: BuddyPaths.home.appendingPathComponent("evolving.lock").path)
        guard exists != evolveLockSeen else { return }
        evolveLockSeen = exists
        controller?.evolveLockChanged(exists: exists)
    }

    private func pollTraits() {
        guard controller?.evolving != true else { return }
        let now = Traits.values()
        var changed = false
        for (name, value) in now {
            if let old = traitsSnapshot[name], abs(old - value) > 0.001 {
                controller?.brain.emit("configChanged", ["trait": name, "from": old, "to": value])
                changed = true
            }
        }
        traitsSnapshot = now
        // Spec: replication on every state change, not on a timer - any trait
        // edit (settings window, chat, hand-edited json) broadcasts right away.
        if changed { controller?.coordination?.broadcastState() }
    }

    private func pollBrain() {
        // Mid-evolution files are half-written; reload once when it finishes.
        guard controller?.evolving != true else { return }
        let sig = Self.currentBrainSignature()
        guard sig != brainSignature else { return }
        brainSignature = sig
        controller?.reloadBrainAndSprites()
    }

    private func pollIdle() {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        let secs = types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        if !idle && secs > 120 {
            idle = true
            controller?.brain.emit("idle", ["seconds": secs])
        } else if idle && secs < 5 {
            idle = false
            controller?.brain.emit("active")
        }
    }

    // Name + mtime of every brain file, so additions, edits, AND deletions all
    // change the signature and trigger a hot reload.
    static func currentBrainSignature() -> String {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: BuddyPaths.brain, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> String in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return "\(url.lastPathComponent):\(m.timeIntervalSince1970)"
            }
            .sorted()
            .joined(separator: "|")
    }
}
