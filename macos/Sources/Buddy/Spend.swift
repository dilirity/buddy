import Foundation

// What buddy may spend the user's Claude usage on, and with which models.
// Lives in ~/.buddy/spend.json; written by the Setup panel (with consent),
// migrated by setup.sh for existing installs. Fresh installs default to
// spending NOTHING - the never-silently-spend principle.
struct Spend {
    var chatEnabled: Bool
    var evolutionSchedule: String // off | manual | weekly | nightly
    var chatModel: String
    var evolutionModel: String    // empty = account default

    static let url = BuddyPaths.home.appendingPathComponent("spend.json")

    static func load() -> Spend {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Spend(chatEnabled: false, evolutionSchedule: "off", chatModel: "haiku", evolutionModel: "")
        }
        return Spend(
            chatEnabled: json["chatEnabled"] as? Bool ?? false,
            evolutionSchedule: json["evolutionSchedule"] as? String ?? "off",
            chatModel: json["chatModel"] as? String ?? "haiku",
            evolutionModel: json["evolutionModel"] as? String ?? "")
    }

    func save() {
        let json: [String: Any] = [
            "chatEnabled": chatEnabled,
            "evolutionSchedule": evolutionSchedule,
            "chatModel": chatModel,
            "evolutionModel": evolutionModel,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Spend.url)
        }
    }
}
