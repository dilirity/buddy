import Foundation

struct Trait {
    var value: Double
    var min: Double
    var max: Double

    var clamped: Double { Swift.min(Swift.max(value, min), max) }
}

enum Traits {
    static func load() -> [String: Trait] {
        guard let data = try? Data(contentsOf: BuddyPaths.traits),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            return [:]
        }
        var out: [String: Trait] = [:]
        for (name, spec) in json {
            let v = (spec["value"] as? NSNumber)?.doubleValue ?? 0.5
            let lo = (spec["min"] as? NSNumber)?.doubleValue ?? 0
            let hi = (spec["max"] as? NSNumber)?.doubleValue ?? 1
            out[name] = Trait(value: v, min: lo, max: hi)
        }
        return out
    }

    static func values() -> [String: Double] {
        load().mapValues { $0.clamped }
    }

    // Full spec (value + drift bounds) for replication: follower devices
    // need the bounds so their settings UIs clamp exactly like this one.
    static func specs() -> [String: [String: Double]] {
        load().mapValues { ["value": $0.clamped, "min": $0.min, "max": $0.max] }
    }

    // Write one trait's value, clamped to its bounds. The bounds themselves
    // are only ever edited by Pete.
    static func setValue(_ name: String, to value: Double) -> Bool {
        guard let data = try? Data(contentsOf: BuddyPaths.traits),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var spec = json[name] as? [String: Any] else { return false }
        let lo = (spec["min"] as? NSNumber)?.doubleValue ?? 0
        let hi = (spec["max"] as? NSNumber)?.doubleValue ?? 1
        spec["value"] = (Swift.min(Swift.max(value, lo), hi) * 100).rounded() / 100
        json[name] = spec
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? out.write(to: BuddyPaths.traits)
        return true
    }
}

struct Invariants {
    var maxDisruptivePerHour = 6
    var panicFreezeMinutes = 10

    static func load() -> Invariants {
        var inv = Invariants()
        guard let data = try? Data(contentsOf: BuddyPaths.invariants),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return inv
        }
        if let v = (json["maxDisruptivePerHour"] as? NSNumber)?.intValue { inv.maxDisruptivePerHour = v }
        if let v = (json["panicFreezeMinutes"] as? NSNumber)?.intValue { inv.panicFreezeMinutes = v }
        return inv
    }
}
