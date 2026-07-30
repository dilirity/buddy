import AppKit

// First-run interview: what buddy calls you, pronouns, what you love, how
// much of a menace to be. It is just a friendly face over the same stores
// settings uses: declared facts land in ~/.buddy/config.json, the menace
// slider seeds the mischief trait. think() appends the facts to the persona
// at use time; persona.md itself is buddy's own evolving prose and no UI
// ever writes it. Skippable; editable later from settings.
final class OnboardingWindow: NSObject {
    private var window: NSWindow?
    private let nameField = NSTextField(string: "")
    private let pronouns = NSPopUpButton(frame: .zero, pullsDown: false)
    private let interestsField = NSTextField(string: "")
    private let menace = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    static let pronounOptions = ["they/them", "she/her", "he/him"]
    // Fired after saving so the brain (and its warm think sessions) reload
    // onto the new facts.
    var onSaved: (() -> Void)?

    static var marker: URL { BuddyPaths.home.appendingPathComponent("onboarded") }
    static var needed: Bool { !FileManager.default.fileExists(atPath: marker.path) }

    static func userNameForDisplay() -> String? {
        (UserConfig.load()["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? memoryString("userName") ?? parsedFromPersona().name
    }

    static func parsedFromPersona() -> (name: String?, interests: String?) {
        guard let text = try? String(contentsOf: BuddyPaths.persona, encoding: .utf8) else { return (nil, nil) }
        func capture(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern),
                  let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        return (capture("lives on (.+?)'s "),
                capture("You love (.+?), and you sneak"))
    }

    func show() {
        window?.close()

        // Config is authoritative; memory keys cover pre-config installs, and
        // installs that predate the interview only have the facts as
        // persona.md prose - recover a best-effort prefill from the known
        // template phrasing.
        let parsed = Self.parsedFromPersona()
        let cfg = UserConfig.load()
        nameField.stringValue = (cfg["name"] as? String)
            ?? Self.memoryString("userName") ?? parsed.name ?? ""
        pronouns.addItems(withTitles: Self.pronounOptions)
        if let p = cfg["pronouns"] as? String, Self.pronounOptions.contains(p) {
            pronouns.selectItem(withTitle: p)
        }
        interestsField.stringValue = (cfg["loves"] as? [Any])
            .map { $0.compactMap { $0 as? String }.joined(separator: ", ") }
            ?? Self.memoryString("interests") ?? parsed.interests ?? ""

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let intro = NSTextField(wrappingLabelWithString:
            "hi. i'm buddy. i live here now.\nthree questions and i'll get out of your way:")
        intro.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        stack.addArrangedSubview(intro)

        stack.addArrangedSubview(field("what do i call you?", nameField, placeholder: "your name"))

        let pronounBox = NSStackView()
        pronounBox.orientation = .vertical
        pronounBox.alignment = .leading
        pronounBox.spacing = 3
        let pronounLabel = NSTextField(labelWithString: "pronouns?")
        pronounLabel.font = NSFont.systemFont(ofSize: 12)
        pronounBox.addArrangedSubview(pronounLabel)
        pronounBox.addArrangedSubview(pronouns)
        stack.addArrangedSubview(pronounBox)

        stack.addArrangedSubview(field("shows, games, movies you love? i steal references.",
                                       interestsField, placeholder: "e.g. Portal, Friends, Alien"))

        let menaceLabel = NSTextField(labelWithString: "how much of a menace should i be?")
        menaceLabel.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(menaceLabel)
        let menaceRow = NSStackView()
        menaceRow.orientation = .horizontal
        let calm = NSTextField(labelWithString: "calm")
        calm.font = NSFont.systemFont(ofSize: 10)
        calm.textColor = .secondaryLabelColor
        let chaos = NSTextField(labelWithString: "chaos")
        chaos.font = NSFont.systemFont(ofSize: 10)
        chaos.textColor = .secondaryLabelColor
        menace.widthAnchor.constraint(equalToConstant: 220).isActive = true
        menaceRow.addArrangedSubview(calm)
        menaceRow.addArrangedSubview(menace)
        menaceRow.addArrangedSubview(chaos)
        stack.addArrangedSubview(menaceRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let save = NSButton(title: "that's me", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let later = NSButton(title: "later", target: self, action: #selector(laterTapped))
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(later)
        stack.addArrangedSubview(buttons)

        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Meet Buddy"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    private func field(_ label: String, _ tf: NSTextField, placeholder: String) -> NSStackView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 12)
        tf.placeholderString = placeholder
        tf.widthAnchor.constraint(equalToConstant: 300).isActive = true
        box.addArrangedSubview(l)
        box.addArrangedSubview(tf)
        return box
    }

    @objc private func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let loves = interestsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        UserConfig.set("name", name.isEmpty ? nil : name)
        UserConfig.set("pronouns", pronouns.titleOfSelectedItem)
        UserConfig.set("loves", loves.isEmpty ? nil : loves)
        // Facts moved to config; stale memory copies would shadow edits in
        // the fallback readers, so clear them.
        Self.setMemory("userName", nil)
        Self.setMemory("interests", nil)
        // The menace slider seeds mischief; bounds in traits.json still clamp.
        _ = Traits.setValue("mischief", to: menace.doubleValue)

        Self.finish()
        window?.close()
        onSaved?()
    }

    @objc private func laterTapped() {
        Self.finish()
        window?.close()
    }

    private static func finish() {
        try? Data().write(to: marker)
    }

    // memory.json is the brain's store; merge keys without disturbing the rest.
    private static func memoryString(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: BuddyPaths.memory),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json[key] as? String
    }

    private static func setMemory(_ key: String, _ value: String?) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: BuddyPaths.memory),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        if let value {
            json[key] = value
        } else {
            json.removeValue(forKey: key)
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: BuddyPaths.memory)
        }
    }
}
