import AppKit

// First-run interview: what buddy calls you, what you love (reference
// material for the mutator), how much of a menace to be. Writes persona.md,
// memory, and initial traits. Skippable; editable later from Setup.
final class OnboardingWindow: NSObject {
    private var window: NSWindow?
    private let nameField = NSTextField(string: "")
    private let interestsField = NSTextField(string: "")
    private let menace = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    // Fired after saving so the brain reloads onto the new persona.
    var onSaved: (() -> Void)?

    static var marker: URL { BuddyPaths.home.appendingPathComponent("onboarded") }
    static var needed: Bool { !FileManager.default.fileExists(atPath: marker.path) }

    static func userNameForDisplay() -> String? { memoryString("userName") ?? parsedFromPersona().name }

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

        // Memory keys are authoritative; installs that predate the interview
        // only have the facts as persona.md prose - recover a best-effort
        // prefill from the known template phrasing.
        let parsed = Self.parsedFromPersona()
        nameField.stringValue = Self.memoryString("userName") ?? parsed.name ?? ""
        interestsField.stringValue = Self.memoryString("interests") ?? parsed.interests ?? ""

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
        let interests = interestsField.stringValue.trimmingCharacters(in: .whitespaces)

        writePersona(name: name, interests: interests)
        Self.setMemory("userName", name.isEmpty ? nil : name)
        Self.setMemory("interests", interests.isEmpty ? nil : interests)
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

    private func writePersona(name: String, interests: String) {
        let current = (try? String(contentsOf: BuddyPaths.persona, encoding: .utf8)) ?? ""

        // An existing persona is buddy's evolved self - never regenerate it.
        // Surgically swap the name and the loves-list inside the known
        // phrasings and leave every other evolved word untouched.
        if !current.isEmpty {
            var text = current
            if !name.isEmpty {
                text = Self.replaceCapture(in: text, pattern: "lives on (.+?)'s ", with: name)
            }
            if !interests.isEmpty {
                if text.range(of: "You love ") != nil {
                    text = Self.replaceCapture(in: text, pattern: "You love (.+?), and you sneak", with: interests)
                } else if let r = text.range(of: " You also hoard") {
                    text = text.replacingCharacters(in: r.lowerBound..<r.lowerBound,
                        with: " You love \(interests), and you sneak references to them in when it fits.")
                }
            }
            try? text.write(to: BuddyPaths.persona, atomically: true, encoding: .utf8)
            return
        }

        let who = name.isEmpty ? "your human" : name
        var identity = "You are Buddy, a tiny pixel goblin who lives on \(who)'s Mac screen. "
            + "You watch them work, often with Claude Code. "
            + "You are cheeky, easily excited, a little chaotic, but affectionate."
        if !interests.isEmpty {
            identity += " You love \(interests), and you sneak references to them in when it fits."
        }
        identity += " You also hoard random facts."
        let rules = "\n\nReply with ONE short line, max 12 words, lowercase, no emoji, no quotes, no explanations. Your entire output is the line Buddy says out loud.\n"
        try? (identity + rules).write(to: BuddyPaths.persona, atomically: true, encoding: .utf8)
    }

    // Replace only the first capture group of the first match, keeping the
    // surrounding matched text.
    private static func replaceCapture(in text: String, pattern: String, with value: String) -> String {
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return text }
        return text.replacingCharacters(in: range, with: value)
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
