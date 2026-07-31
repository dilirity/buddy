import AppKit
import ApplicationServices

// System pane: everything buddy relies on - permissions, Claude, hooks, the
// evolution service, device pairing - as live-status rows with a fix path.
// Hosted as the System tab of the Settings window, so a revoked permission or
// a vanished claude install shows up next to everything else tunable.
final class SetupWindow: NSObject {
    // Wired by the controller; the peer list lives with coordination.
    var peersProvider: (() -> [String])?

    private var refreshTimer: Timer?
    private var rows: [Row] = []
    // claude lookup shells out; cached per pane-build so refresh stays cheap.
    private var claudeVersion: String?
    private var claudeChecked = false
    // Live Privacy-list state lives with the controller (event-driven via
    // com.apple.accessibility.api); the panel just reads it.
    var keyAccessProvider: (() -> Bool)?
    // Fired after spend.json changes so warm think sessions restart or shut down.
    var onSpendChanged: (() -> Void)?
    // Switches the hosting window to the Your World tab (facts live there).
    var onOpenYourWorld: (() -> Void)?

    private final class Row {
        let dot = NSTextField(labelWithString: "●")
        let title: NSTextField
        let tag: NSTextField
        let detail = NSTextField(labelWithString: "")
        let button = NSButton(title: "", target: nil, action: nil)
        // Up to two dropdowns per row (e.g. evolution: schedule + model).
        let popups = [NSPopUpButton(), NSPopUpButton()]
        var popupHandlers: [Int: (String) -> Void] = [:]
        var action: (() -> Void)?
        let refresh: (Row) -> Void

        init(title: String, tag: String, refresh: @escaping (Row) -> Void) {
            self.title = NSTextField(labelWithString: title)
            self.tag = NSTextField(labelWithString: tag)
            self.refresh = refresh
        }

        // state: true = good, false = needs attention, nil = informational
        func set(_ state: Bool?, _ text: String, button buttonTitle: String? = nil, action: (() -> Void)? = nil) {
            dot.textColor = state == nil ? .tertiaryLabelColor : state! ? .systemGreen : .systemOrange
            detail.stringValue = text
            self.action = action
            if let t = buttonTitle {
                button.title = t
                button.isHidden = false
            } else {
                button.isHidden = true
            }
        }

        // options: (id stored in config, label shown). Rebuilds only when the
        // option set changes; keeps the user's open menu stable across refresh.
        func setPopup(_ index: Int, options: [(String, String)], selected: String,
                      handler: @escaping (String) -> Void) {
            let popup = popups[index]
            popup.isHidden = false
            popupHandlers[index] = handler
            if popup.numberOfItems != options.count {
                popup.removeAllItems()
                for (id, label) in options {
                    popup.addItem(withTitle: label)
                    popup.lastItem?.representedObject = id
                }
            }
            if let idx = options.firstIndex(where: { $0.0 == selected }),
               popup.indexOfSelectedItem != idx {
                popup.selectItem(at: idx)
            }
        }
    }

    // Builds the pane and starts the 2s live-status refresh; `visible` gates
    // the timer so it dies with the hosting window.
    func makePaneView(visible: @escaping () -> Bool) -> NSView {
        rows.removeAll()
        claudeChecked = false
        let stack = build()
        refreshAll()
        refreshTimer?.invalidate()
        refreshTimer = commonTimer(2.0, repeats: true) { [weak self] _ in
            guard let self, visible() else {
                self?.refreshTimer?.invalidate()
                return
            }
            self.refreshAll()
        }
        return stack
    }

    private func refreshAll() {
        for r in rows { r.refresh(r) }
    }

    // MARK: - Rows

    private func build() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        add(to: stack, Row(title: "Accessibility", tag: "recommended") { [weak self] row in
            let live = self?.keyAccessProvider?() ?? AXIsProcessTrusted()
            if live {
                row.set(true, "granted - typing sense and the double-Esc panic gesture work")
            } else {
                row.set(false, "not granted - buddy cannot see the keyboard: no typing awareness, no "
                        + "double-Esc panic (menu Freeze/Wake still works). Fix adds Buddy to the list; "
                        + "flip its switch on",
                        button: "Fix...") {
                    // The prompt call is the only API that (re)registers this
                    // unsigned binary in the Accessibility list, so it must
                    // run every time - even with System Settings already open,
                    // where its dialog looks redundant. Its "Open System
                    // Settings" button just activates the existing instance.
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(opts)
                }
            }
        })

        add(to: stack, Row(title: "Claude Code", tag: "optional") { [weak self] row in
            guard let self else { return }
            self.checkClaudeOnce()
            if let v = self.claudeVersion {
                row.set(true, "found: \(v)")
            } else if self.claudeChecked {
                row.set(false, "not found - buddy runs in small-brain mode: no chat, no thoughts, no evolution",
                        button: "Install Guide") {
                    NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                }
            } else {
                row.set(nil, "checking...")
            }
        })

        add(to: stack, Row(title: "Claude hooks", tag: "recommended") { [weak self] row in
            if Hooks.installed() {
                row.set(true, "installed - buddy reacts to your Claude Code sessions",
                        button: "Remove...") { self?.changeHooks(install: false) }
            } else {
                row.set(false, "not installed - buddy is blind to your Claude sessions",
                        button: "Install...") { self?.changeHooks(install: true) }
            }
        })

        add(to: stack, Row(title: "Claude account", tag: "info") { row in
            guard let acct = SetupWindow.claudeAccount() else {
                row.set(nil, "no account info (is Claude Code logged in?)")
                return
            }
            var text = acct.email
            if let org = acct.orgType { text += " - \(org)" }
            text += ". Chat and evolution spend THIS account's usage - nothing runs without your consent below."
            row.set(nil, text)
        })

        add(to: stack, Row(title: "Chat & thoughts", tag: "spends usage") { [weak self] row in
            let sp = Spend.load()
            if sp.chatEnabled {
                row.set(true, "on - chatting and buddy's idle thoughts use small Claude calls",
                        button: "Disable") {
                    var s = Spend.load()
                    s.chatEnabled = false
                    s.save()
                    self?.onSpendChanged?()
                    self?.refreshAll()
                }
            } else {
                row.set(nil, "off - buddy speaks in canned lines only; chat gets a small-brain reply",
                        button: "Enable...") {
                    guard self?.consentToSpend(what: "Chatting with buddy and its occasional idle thoughts "
                        + "run small Claude calls") == true else { return }
                    var s = Spend.load()
                    s.chatEnabled = true
                    s.save()
                    self?.onSpendChanged?()
                    self?.refreshAll()
                }
            }
            row.setPopup(0, options: [("haiku", "haiku"), ("sonnet", "sonnet"), ("opus", "opus")],
                         selected: sp.chatModel) { [weak self] model in
                var s = Spend.load()
                s.chatModel = model
                s.save()
                self?.onSpendChanged?()
            }
        })

        add(to: stack, Row(title: "Evolution", tag: "spends usage") { [weak self] row in
            let sp = Spend.load()
            let loaded = SetupWindow.launchdLoaded("com.buddy.mutator")
            switch sp.evolutionSchedule {
            case "nightly", "weekly":
                let when = sp.evolutionSchedule == "nightly" ? "every night at 03:33" : "Sunday nights at 03:33"
                var text = "buddy rewrites part of its brain \(when)"
                if let age = SetupWindow.lastEvolutionAge() { text += " (last: \(age))" }
                if !loaded { text = "scheduled but the service is not loaded - pick the schedule again to repair" }
                row.set(loaded, text)
            case "manual":
                row.set(nil, "only when you use Evolve Now in the menu")
            default:
                row.set(nil, "off - buddy never changes")
            }
            row.setPopup(0, options: [("off", "off"), ("manual", "manual only"),
                                      ("weekly", "weekly"), ("nightly", "nightly")],
                         selected: sp.evolutionSchedule) { [weak self] sched in
                self?.setEvolution(schedule: sched)
            }
            row.setPopup(1, options: [("", "default model"), ("haiku", "haiku"),
                                      ("sonnet", "sonnet"), ("opus", "opus")],
                         selected: sp.evolutionModel) { model in
                var s = Spend.load()
                s.evolutionModel = model
                s.save()
            }
        })

        add(to: stack, Row(title: "About you", tag: "info") { [weak self] row in
            let name = OnboardingWindow.userNameForDisplay()
            row.set(nil, (name == nil ? "buddy doesn't know your name yet"
                                      : "buddy calls you \(name!)")
                        + " - name, pronouns and loves live in Your World",
                    button: "Open") { self?.onOpenYourWorld?() }
        })

        add(to: stack, Row(title: "Device pairing", tag: "optional") { [weak self] row in
            let secret = BuddyPaths.home.appendingPathComponent("secret")
            guard FileManager.default.fileExists(atPath: secret.path) else {
                row.set(false, "no pairing secret - run setup.sh to generate one")
                return
            }
            let peers = self?.peersProvider?() ?? []
            if peers.isEmpty {
                row.set(nil, "secret ok, no other devices on the LAN right now")
            } else {
                row.set(true, "paired, online: \(peers.joined(separator: ", "))")
            }
        })

        return stack
    }

    private func add(to stack: NSStackView, _ row: Row) {
        rows.append(row)

        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 6
        row.dot.font = NSFont.systemFont(ofSize: 12)
        row.title.font = NSFont.boldSystemFont(ofSize: 12)
        row.tag.font = NSFont.systemFont(ofSize: 10)
        row.tag.textColor = .secondaryLabelColor
        row.button.bezelStyle = .rounded
        row.button.controlSize = .small
        row.button.font = NSFont.systemFont(ofSize: 11)
        row.button.target = self
        row.button.action = #selector(rowButton(_:))
        row.button.identifier = NSUserInterfaceItemIdentifier("\(rows.count - 1)")
        top.addArrangedSubview(row.dot)
        top.addArrangedSubview(row.title)
        top.addArrangedSubview(row.tag)
        top.addArrangedSubview(row.button)
        for (i, popup) in row.popups.enumerated() {
            popup.isHidden = true
            popup.controlSize = .small
            popup.font = NSFont.systemFont(ofSize: 11)
            popup.target = self
            popup.action = #selector(rowPopup(_:))
            popup.identifier = NSUserInterfaceItemIdentifier("\(rows.count - 1):\(i)")
            top.addArrangedSubview(popup)
        }

        row.detail.font = NSFont.systemFont(ofSize: 11)
        row.detail.textColor = .secondaryLabelColor
        row.detail.lineBreakMode = .byWordWrapping
        row.detail.maximumNumberOfLines = 3
        row.detail.preferredMaxLayoutWidth = 430
        row.detail.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        box.addArrangedSubview(top)
        box.addArrangedSubview(row.detail)
        stack.addArrangedSubview(box)
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard let idx = sender.identifier.flatMap({ Int($0.rawValue) }), rows.indices.contains(idx) else { return }
        rows[idx].action?()
    }

    @objc private func rowPopup(_ sender: NSPopUpButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ":")
        guard parts.count == 2, let rowIdx = Int(parts[0]), let popIdx = Int(parts[1]),
              rows.indices.contains(rowIdx),
              let id = sender.selectedItem?.representedObject as? String else { return }
        rows[rowIdx].popupHandlers[popIdx]?(id)
    }

    // MARK: - Checks

    private func checkClaudeOnce() {
        guard !claudeChecked else { return }
        claudeChecked = true
        DispatchQueue.global().async { [weak self] in
            // GUI apps get a bare PATH; extend it the same way Think does or
            // claude installs in ~/.local/bin and homebrew are invisible here.
            let out = SetupWindow.run("/bin/bash", ["-c", "claude --version 2>/dev/null"],
                                      pathExtra: ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin")
            DispatchQueue.main.async {
                self?.claudeVersion = out.isEmpty ? nil : out
                self?.refreshAll()
            }
        }
    }

    struct Account { let email: String; let orgName: String?; let orgType: String? }

    static func claudeAccount() -> Account? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let acct = json["oauthAccount"] as? [String: Any],
              let email = acct["emailAddress"] as? String else { return nil }
        return Account(email: email,
                       orgName: acct["organizationName"] as? String,
                       orgType: acct["organizationType"] as? String)
    }

    static func launchdLoaded(_ label: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list", label]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func lastEvolutionAge() -> String? {
        let url = BuddyPaths.home.appendingPathComponent("last-evolution")
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let ts = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let hours = Int((Date().timeIntervalSince1970 - ts) / 3600)
        return hours < 1 ? "under an hour ago" : hours < 48 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    private static func run(_ path: String, _ args: [String], pathExtra: String = "") -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !pathExtra.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + pathExtra
            p.environment = env
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Evolution service toggle

    private var mutatorPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.buddy.mutator.plist")
    }

    // MARK: - Hooks consent

    private func changeHooks(install: Bool) {
        // Hooks point at $BUDDY_HOME/bin/buddy-hook; a sandbox instance would
        // wire the real ~/.claude to a throwaway directory.
        if BuddyPaths.isSandbox {
            let a = NSAlert()
            a.messageText = "Sandbox instance"
            a.informativeText = "This buddy runs against a BUDDY_HOME sandbox; Claude hooks belong to the real install."
            a.runModal()
            return
        }
        let plan = install ? Hooks.installPlan() : Hooks.removePlan()
        guard !plan.isEmpty else { refreshAll(); return }
        let a = NSAlert()
        a.messageText = install ? "Add buddy's hooks to Claude Code?" : "Remove buddy's hooks from Claude Code?"
        a.informativeText = "Exact changes to ~/.claude/settings.json"
            + " (a backup is saved to ~/.buddy/backups/ first):\n\n"
            + plan.joined(separator: "\n")
            + (install ? "\n\nThese only record events for buddy to react to - they never change what Claude does." : "")
        a.addButton(withTitle: install ? "Add" : "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let ok = install ? Hooks.install() : Hooks.remove()
        if !ok {
            let e = NSAlert()
            e.messageText = "Could not write settings.json"
            e.informativeText = "Nothing was changed. See ~/.buddy/buddy.log."
            e.runModal()
        }
        buddyLog("setup: hooks \(install ? "installed" : "removed")")
        refreshAll()
    }

    // Shared consent gate for anything that starts spending Claude usage.
    // Returns true when the user approved.
    private func consentToSpend(what: String) -> Bool {
        var spend = "your Claude account"
        if let acct = SetupWindow.claudeAccount() {
            spend = acct.email
            if let t = acct.orgType { spend += " (\(t))" }
        }
        let a = NSAlert()
        a.messageText = "Spend Claude usage?"
        a.informativeText = "\(what), on: \(spend)."
            + " If this is a company or org account, make sure that's okay first."
            + " Turn it off here any time."
        a.addButton(withTitle: "Enable")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func setEvolution(schedule: String) {
        // The service is a per-user shared resource; a sandbox test instance
        // must not flip the real one.
        if BuddyPaths.isSandbox {
            let a = NSAlert()
            a.messageText = "Sandbox instance"
            a.informativeText = "This buddy runs against a BUDDY_HOME sandbox; the evolution service belongs to the real install."
            a.runModal()
            refreshAll()
            return
        }
        var sp = Spend.load()
        let wasSpending = ["weekly", "nightly"].contains(sp.evolutionSchedule)
        let willSpend = ["weekly", "nightly"].contains(schedule)
        if willSpend && !wasSpending {
            let when = schedule == "nightly" ? "One Claude session every night at 03:33"
                                             : "One Claude session every Sunday at 03:33"
            guard consentToSpend(what: "\(when) rewrites part of buddy's brain") else {
                refreshAll() // snap the popup back
                return
            }
        }
        sp.evolutionSchedule = schedule
        sp.save()
        if willSpend {
            let runsh = BuddyPaths.home.appendingPathComponent("mutator/run.sh").path
            let weekday = schedule == "weekly" ? "<key>Weekday</key><integer>0</integer>" : ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.buddy.mutator</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/bin/bash</string>
                    <string>\(runsh)</string>
                </array>
                <key>StartCalendarInterval</key>
                <dict>
                    \(weekday)<key>Hour</key><integer>3</integer>
                    <key>Minute</key><integer>33</integer>
                </dict>
                <key>StandardOutPath</key><string>/tmp/buddy-mutator.out</string>
                <key>StandardErrorPath</key><string>/tmp/buddy-mutator.err</string>
            </dict>
            </plist>
            """
            _ = SetupWindow.run("/bin/launchctl", ["unload", mutatorPlist.path])
            // A fresh account has no LaunchAgents dir; a silent write failure
            // here leaves the panel claiming a schedule launchd never got.
            try? FileManager.default.createDirectory(at: mutatorPlist.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? plist.data(using: .utf8)?.write(to: mutatorPlist)
            _ = SetupWindow.run("/bin/launchctl", ["load", mutatorPlist.path])
            buddyLog("setup: evolution schedule = \(schedule)")
        } else {
            _ = SetupWindow.run("/bin/launchctl", ["unload", mutatorPlist.path])
            try? FileManager.default.removeItem(at: mutatorPlist)
            buddyLog("setup: evolution schedule = \(schedule), service removed")
        }
        refreshAll()
    }
}
