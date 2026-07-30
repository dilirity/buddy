import Foundation

// Buddy's Claude Code hook entries in ~/.claude/settings.json: detect,
// merge in, strip out. Every buddy entry is identified by its command
// containing the buddy-hook script path - user-authored hooks are never
// touched. A timestamped backup lands in ~/.buddy/backups/ before any write.
enum Hooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                         "PostToolUse", "Stop", "Notification", "SessionEnd"]
    static let marker = "/.buddy/bin/buddy-hook"

    // Overridable for `Buddy --hooks-dry <file>`, which exercises these exact
    // code paths against a copy instead of the live settings.
    static var settingsURL: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    private static func hookCommand(_ event: String) -> String {
        BuddyPaths.home.appendingPathComponent("bin/buddy-hook").path + " " + event
    }

    static func installed() -> Bool {
        let content = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
        return content.contains(marker)
    }

    private static func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return json
    }

    // What install would add / remove would delete - shown verbatim in the
    // consent alert so the user approves the real change, not a description.
    static func installPlan() -> [String] {
        let hooks = loadSettings()["hooks"] as? [String: Any] ?? [:]
        return events.compactMap { event in
            if hasBuddyEntry(hooks, event: event) { return nil }
            return "+ \(event): \(hookCommand(event))"
        }
    }

    static func removePlan() -> [String] {
        let hooks = loadSettings()["hooks"] as? [String: Any] ?? [:]
        var out: [String] = []
        for (event, value) in hooks {
            for entry in value as? [[String: Any]] ?? [] {
                for h in entry["hooks"] as? [[String: Any]] ?? [] {
                    if let cmd = h["command"] as? String, cmd.contains(marker) {
                        out.append("- \(event): \(cmd)")
                    }
                }
            }
        }
        return out.sorted()
    }

    private static func hasBuddyEntry(_ hooks: [String: Any], event: String) -> Bool {
        for entry in hooks[event] as? [[String: Any]] ?? [] {
            for h in entry["hooks"] as? [[String: Any]] ?? [] {
                if (h["command"] as? String)?.contains(marker) == true { return true }
            }
        }
        return false
    }

    @discardableResult
    static func install() -> Bool {
        var settings = loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            guard !hasBuddyEntry(hooks, event: event) else { continue }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": hookCommand(event)]]]
            if event == "PreToolUse" || event == "PostToolUse" { entry["matcher"] = "*" }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(entry)
            hooks[event] = entries
            changed = true
        }
        guard changed else { return true }
        settings["hooks"] = hooks
        return write(settings)
    }

    @discardableResult
    static func remove() -> Bool {
        var settings = loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return true }
        for (event, value) in hooks {
            var entries: [[String: Any]] = []
            for entry in value as? [[String: Any]] ?? [] {
                var e = entry
                let kept = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(marker) != true
                }
                e["hooks"] = kept
                if !kept.isEmpty { entries.append(e) }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        settings["hooks"] = hooks
        return write(settings)
    }

    private static func write(_ settings: [String: Any]) -> Bool {
        backup()
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        do {
            try data.write(to: settingsURL)
            return true
        } catch {
            buddyLog("hooks: cannot write settings.json: \(error)")
            return false
        }
    }

    private static func backup() {
        let dir = BuddyPaths.home.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try? FileManager.default.copyItem(at: settingsURL,
                                          to: dir.appendingPathComponent("settings.json.\(stamp)"))
    }
}
