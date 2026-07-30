import AppKit

// Native settings UI. Writes straight to traits.json / invariants.json, so the
// senses' file watchers (and buddy's opinions about being tweaked) fire as usual.
final class SettingsWindow: NSObject {
    private var window: NSWindow?
    private var valueLabels: [String: NSTextField] = [:]
    private var formats: [String: String] = [:]

    func show() {
        window?.close()
        valueLabels.removeAll()
        formats.removeAll()
        build()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header("Personality"))
        let traits = Traits.load()
        let preferred = ["mischief", "chattiness", "energy", "clinginess", "weirdness"]
        let names = preferred.filter { traits[$0] != nil }
            + traits.keys.filter { !preferred.contains($0) }.sorted()
        for name in names {
            guard let t = traits[name] else { continue }
            stack.addArrangedSubview(sliderRow(
                id: "trait:\(name)", label: name,
                min: t.min, max: t.max, value: t.clamped, format: "%.2f"))
        }
        stack.addArrangedSubview(note("Sliders move within each trait's min/max drift bounds (traits.json)."))

        let config = loadConfig()
        if !config.isEmpty {
            stack.addArrangedSubview(header("Your World"))
            for (key, entry) in config {
                stack.addArrangedSubview(configRow(key: key, entry: entry))
            }
            stack.addArrangedSubview(note("Facts buddy's behaviors rely on. Your values live in ~/.buddy/config.json; evolutions add new ones and they show up here on their own."))
        }

        stack.addArrangedSubview(header("Limits"))
        let inv = Invariants.load()
        stack.addArrangedSubview(sliderRow(
            id: "inv:maxDisruptivePerHour", label: "disruptive / hour",
            min: 0, max: 30, value: Double(inv.maxDisruptivePerHour), format: "%.0f"))
        stack.addArrangedSubview(sliderRow(
            id: "inv:panicFreezeMinutes", label: "panic freeze min",
            min: 1, max: 60, value: Double(inv.panicFreezeMinutes), format: "%.0f"))
        stack.addArrangedSubview(note("The leash. The nightly mutator cannot touch these."))

        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Buddy Settings"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        window = win
    }

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 13)
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 10)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func sliderRow(id: String, label: String, min: Double, max: Double,
                           value: Double, format: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let name = NSTextField(labelWithString: label)
        name.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        name.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let slider = NSSlider(value: value, minValue: min, maxValue: max,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(id)
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let val = NSTextField(labelWithString: String(format: format, value))
        val.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        val.widthAnchor.constraint(equalToConstant: 44).isActive = true
        valueLabels[id] = val
        formats[id] = format

        row.addArrangedSubview(name)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(val)
        return row
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue else { return }
        let value = sender.doubleValue
        valueLabels[id]?.stringValue = String(format: formats[id] ?? "%.2f", value)
        if id.hasPrefix("trait:") {
            saveTrait(String(id.dropFirst("trait:".count)), value: value)
        } else if id.hasPrefix("inv:") {
            saveInvariant(String(id.dropFirst("inv:".count)), value: Int(value.rounded()))
        }
    }

    // MARK: - Configurables
    // Schema (brain/config-schema.json, mutator-owned) declares {type, label,
    // default}; values (~/.buddy/config.json, human-owned, unversioned) hold
    // only keys the human changed. Split on purpose: the brain repo's
    // failed-evolution revert must never touch user preferences. Entries are
    // self-describing so evolutions add configurables without an app rebuild.

    private var schemaURL: URL { BuddyPaths.brain.appendingPathComponent("config-schema.json") }

    private func loadConfig() -> [(String, [String: Any])] {
        guard let data = try? Data(contentsOf: schemaURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let values = UserConfig.load()
        return json.compactMap { key, value in
            (value as? [String: Any]).map { entry in
                var e = entry
                e["value"] = values[key] ?? entry["default"]
                return (key, e)
            }
        }.sorted { $0.0 < $1.0 }
    }

    private func configRow(key: String, entry: [String: Any]) -> NSStackView {
        let type = entry["type"] as? String ?? "text"
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let name = NSTextField(labelWithString: entry["label"] as? String ?? key)
        name.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true
        row.addArrangedSubview(name)

        let id = NSUserInterfaceItemIdentifier("cfg:\(key)")
        switch type {
        case "hour":
            let v = (entry["value"] as? NSNumber)?.doubleValue ?? 0
            let slider = NSSlider(value: v, minValue: 0, maxValue: 24,
                                  target: self, action: #selector(configHourChanged(_:)))
            slider.identifier = id
            slider.isContinuous = false
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            row.addArrangedSubview(slider)
            let val = NSTextField(labelWithString: Self.hourText(v))
            val.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            val.widthAnchor.constraint(equalToConstant: 44).isActive = true
            valueLabels["cfg:\(key)"] = val
            row.addArrangedSubview(val)
        case "bool":
            let check = NSButton(checkboxWithTitle: "",
                                 target: self, action: #selector(configBoolChanged(_:)))
            check.identifier = id
            check.state = (entry["value"] as? Bool ?? false) ? .on : .off
            row.addArrangedSubview(check)
        case "weekday", "choice":
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = id
            let titles = type == "weekday" ? Self.weekdays : (entry["options"] as? [String] ?? [])
            popup.addItems(withTitles: titles)
            popup.selectItem(withTitle: entry["value"] as? String ?? titles.first ?? "")
            popup.target = self
            popup.action = #selector(configPopupChanged(_:))
            row.addArrangedSubview(popup)
        case "list":
            let joined = (entry["value"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ", ") ?? ""
            let field = NSTextField(string: joined)
            field.identifier = id
            field.placeholderString = "comma-separated"
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            field.target = self
            field.action = #selector(configTextChanged(_:))
            row.addArrangedSubview(field)
        case "date":
            let picker = NSDatePicker()
            picker.identifier = id
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay]
            picker.dateValue = Self.dateFormatter.date(from: entry["value"] as? String ?? "") ?? Date()
            picker.target = self
            picker.action = #selector(configDateChanged(_:))
            row.addArrangedSubview(picker)
        default: // number, text
            let field = NSTextField(string: "\(entry["value"] ?? "")")
            field.identifier = id
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            field.target = self
            field.action = #selector(configTextChanged(_:))
            row.addArrangedSubview(field)
        }
        return row
    }

    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func hourText(_ v: Double) -> String {
        String(format: "%d:%02d", Int(v), Int((v - Double(Int(v))) * 60))
    }

    @objc private func configHourChanged(_ sender: NSSlider) {
        guard let key = configKey(sender) else { return }
        // Snap to 15-minute steps - finer than that is false precision for routines.
        let v = (sender.doubleValue * 4).rounded() / 4
        sender.doubleValue = v
        valueLabels["cfg:\(key)"]?.stringValue = Self.hourText(v)
        saveConfigValue(key, value: v)
    }

    @objc private func configBoolChanged(_ sender: NSButton) {
        guard let key = configKey(sender) else { return }
        saveConfigValue(key, value: sender.state == .on)
    }

    @objc private func configPopupChanged(_ sender: NSPopUpButton) {
        guard let key = configKey(sender), let title = sender.titleOfSelectedItem else { return }
        saveConfigValue(key, value: title)
    }

    @objc private func configDateChanged(_ sender: NSDatePicker) {
        guard let key = configKey(sender) else { return }
        saveConfigValue(key, value: Self.dateFormatter.string(from: sender.dateValue))
    }

    @objc private func configTextChanged(_ sender: NSTextField) {
        guard let key = configKey(sender) else { return }
        let text = sender.stringValue
        let type = (try? Data(contentsOf: schemaURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { ($0[key] as? [String: Any])?["type"] as? String }
        switch type {
        case "number":
            saveConfigValue(key, value: Double(text) ?? 0)
        case "list":
            let items = text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            saveConfigValue(key, value: items)
        default:
            saveConfigValue(key, value: text)
        }
    }

    private func configKey(_ control: NSControl) -> String? {
        guard let id = control.identifier?.rawValue, id.hasPrefix("cfg:") else { return nil }
        return String(id.dropFirst("cfg:".count))
    }

    private func saveConfigValue(_ key: String, value: Any) {
        // Missing values file is normal (fresh install, or deleted by hand -
        // everything falls back to schema defaults); UserConfig recreates it.
        UserConfig.set(key, value)
    }

    private func saveTrait(_ name: String, value: Double) {
        guard let data = try? Data(contentsOf: BuddyPaths.traits),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var spec = json[name] as? [String: Any] else { return }
        spec["value"] = (value * 100).rounded() / 100
        json[name] = spec
        write(json, to: BuddyPaths.traits)
    }

    private func saveInvariant(_ name: String, value: Int) {
        guard let data = try? Data(contentsOf: BuddyPaths.invariants),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json[name] = value
        write(json, to: BuddyPaths.invariants)
    }

    private func write(_ json: [String: Any], to url: URL) {
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
        }
    }
}
