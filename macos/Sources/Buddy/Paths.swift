import Foundation

enum BuddyPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".buddy")
    static let brain = home.appendingPathComponent("brain")
    static let sprites = brain.appendingPathComponent("sprites.json")
    static let persona = brain.appendingPathComponent("persona.md")
    static let traits = home.appendingPathComponent("traits.json")
    static let invariants = home.appendingPathComponent("invariants.json")
    static let memory = home.appendingPathComponent("memory.json")
    static let events = home.appendingPathComponent("events.jsonl")
    static let log = home.appendingPathComponent("buddy.log")

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        // Dev convenience: when launched from a checkout via `swift run`, seed the
        // live brain from ./brain so the app works before install.sh ever runs.
        if !fm.fileExists(atPath: brain.path) {
            let local = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("brain")
            if fm.fileExists(atPath: local.path) {
                try? fm.copyItem(at: local, to: brain)
            } else {
                try? fm.createDirectory(at: brain, withIntermediateDirectories: true)
            }
        }
        if !fm.fileExists(atPath: traits.path) {
            try? defaultTraits.data(using: .utf8)?.write(to: traits)
        }
        if !fm.fileExists(atPath: invariants.path) {
            try? defaultInvariants.data(using: .utf8)?.write(to: invariants)
        }
        if !fm.fileExists(atPath: events.path) {
            fm.createFile(atPath: events.path, contents: nil)
        }
    }

    static let defaultTraits = """
    {
      "mischief":   { "value": 0.6, "min": 0.2, "max": 0.9 },
      "chattiness": { "value": 0.5, "min": 0.0, "max": 1.0 },
      "energy":     { "value": 0.7, "min": 0.1, "max": 1.0 },
      "clinginess": { "value": 0.5, "min": 0.0, "max": 1.0 },
      "weirdness":  { "value": 0.3, "min": 0.0, "max": 1.0 }
    }
    """

    static let defaultInvariants = """
    { "maxDisruptivePerHour": 12, "panicFreezeMinutes": 10 }
    """
}

// All buddy timers go through this: scheduled in .common run loop modes so
// animation, movement, and brain ticks keep running while a menu is open
// (default-mode timers pause during menu tracking - frozen buddy).
@discardableResult
func commonTimer(_ interval: TimeInterval, repeats: Bool, _ block: @escaping (Timer) -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: repeats, block: block)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// Behavioral telemetry: one JSONL line per observable act, so "are the
// settings actually shaping behavior" is answerable from data.
// Read it with ~/.buddy/bin/activity-report.
func buddyActivity(_ event: String, _ detail: [String: Any] = [:]) {
    var obj: [String: Any] = ["ts": Date().timeIntervalSince1970, "event": event]
    obj.merge(detail) { a, _ in a }
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0a)
    let url = BuddyPaths.home.appendingPathComponent("activity.jsonl")
    if let h = FileHandle(forWritingAtPath: url.path) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

func buddyLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: BuddyPaths.log.path) {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: BuddyPaths.log)
    }
    NSLog("[buddy] %@", msg)
}
