import AppKit
import ApplicationServices

// Setup / health panel: everything buddy relies on - permissions, Claude,
// hooks, the evolution service, device pairing - as live-status rows with a
// fix path. Reachable from the status menu any time, not just first run, so
// a revoked permission or a vanished claude install shows up here.
final class SetupWindow: NSObject {
    // Wired by the controller; the peer list lives with coordination.
    var peersProvider: (() -> [String])?
    // Wired by the controller; pokes the music player to fire the Automation prompt.
    var musicRequest: (() -> Void)?


    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var rows: [Row] = []
    // claude lookup shells out; cached per window-open so refresh stays cheap.
    private var claudeVersion: String?
    private var claudeChecked = false
    // Live Privacy-list state lives with the controller (event-driven via
    // com.apple.accessibility.api); the panel just reads it.
    var inputMonitoringProvider: (() -> Bool)?

    private final class Row {
        let dot = NSTextField(labelWithString: "●")
        let title: NSTextField
        let tag: NSTextField
        let detail = NSTextField(labelWithString: "")
        let button = NSButton(title: "", target: nil, action: nil)
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
    }

    func show() {
        window?.close()
        rows.removeAll()
        claudeChecked = false
        build()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        refreshAll()
        refreshTimer?.invalidate()
        refreshTimer = commonTimer(2.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else {
                self?.refreshTimer?.invalidate()
                return
            }
            self.refreshAll()
        }
    }

    private func refreshAll() {
        for r in rows { r.refresh(r) }
    }

    // MARK: - Rows

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        add(to: stack, Row(title: "Input monitoring", tag: "recommended") { [weak self] row in
            let live = self?.inputMonitoringProvider?() ?? CGPreflightListenEventAccess()
            if live {
                row.set(true, "granted - typing sense and the double-Esc panic gesture work")
            } else {
                row.set(false, "not granted - buddy cannot see the keyboard: no typing awareness, no "
                        + "double-Esc panic (menu Freeze/Wake still works). Fix opens System Settings; "
                        + "macOS may ask to relaunch buddy",
                        button: "Fix...") {
                    // Registers THIS binary in the Input Monitoring list (a
                    // stale entry from a previous build toggles the wrong
                    // fingerprint), then opens the pane for the switch.
                    CGRequestListenEventAccess()
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            }
        })

        add(to: stack, Row(title: "Cursor mischief", tag: "info") { row in
            row.set(nil, "heists and warps need NO macOS permission - they are governed by buddy's own "
                    + "leash: the mischief slider, the disruptive-acts budget, and freeze/panic.")
        })

        add(to: stack, Row(title: "Music control", tag: "optional") { [weak self] row in
            // No reliable read of the Automation grant without prompting;
            // explain the prompt instead of pretending to know.
            row.set(nil, "buddy can control Music/Spotify - macOS will ask you to approve that the first"
                    + " time. Request it now instead of meeting the prompt mid-song next week.",
                    button: "Request access") {
                self?.musicRequest?()
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

        add(to: stack, Row(title: "Claude hooks", tag: "recommended") { row in
            let settings = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
            let content = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
            if content.contains("buddy-hook") {
                row.set(true, "installed - buddy reacts to your Claude Code sessions")
            } else {
                row.set(false, "not installed - buddy is blind to your Claude sessions. "
                        + "For now: python3 macos/bin/install-hooks.py (in-app flow coming)")
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

        add(to: stack, Row(title: "Nightly evolution", tag: "spends usage") { [weak self] row in
            let loaded = SetupWindow.launchdLoaded("com.buddy.mutator")
            var text: String
            if loaded {
                text = "on - buddy rewrites part of its brain at 03:33 every night"
                if let age = SetupWindow.lastEvolutionAge() { text += " (last: \(age))" }
                row.set(true, text, button: "Disable") { self?.setEvolution(false) }
            } else {
                text = "off - buddy never changes (Evolve Now in the menu still works)"
                row.set(false, text, button: "Enable...") { self?.setEvolution(true) }
            }
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

        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Buddy Setup"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        window = win
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

    private func setEvolution(_ on: Bool) {
        // The service is a per-user shared resource; a sandbox test instance
        // must not flip the real one.
        if BuddyPaths.isSandbox {
            let a = NSAlert()
            a.messageText = "Sandbox instance"
            a.informativeText = "This buddy runs against a BUDDY_HOME sandbox; the evolution service belongs to the real install."
            a.runModal()
            return
        }
        if on {
            let a = NSAlert()
            a.messageText = "Enable nightly evolution?"
            var spend = "your Claude account"
            if let acct = SetupWindow.claudeAccount() {
                spend = acct.email
                if let t = acct.orgType { spend += " (\(t))" }
            }
            a.informativeText = "Every night at 03:33 buddy runs one Claude session that rewrites part of its brain."
                + " That session spends usage on: \(spend)."
                + " If this is a company or org account, make sure that's okay before enabling."
                + " Disable it here any time."
            a.addButton(withTitle: "Enable")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let runsh = BuddyPaths.home.appendingPathComponent("mutator/run.sh").path
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
                    <key>Hour</key><integer>3</integer>
                    <key>Minute</key><integer>33</integer>
                </dict>
                <key>StandardOutPath</key><string>/tmp/buddy-mutator.out</string>
                <key>StandardErrorPath</key><string>/tmp/buddy-mutator.err</string>
            </dict>
            </plist>
            """
            try? plist.data(using: .utf8)?.write(to: mutatorPlist)
            _ = SetupWindow.run("/bin/launchctl", ["load", mutatorPlist.path])
            buddyLog("setup: evolution service enabled")
        } else {
            _ = SetupWindow.run("/bin/launchctl", ["unload", mutatorPlist.path])
            try? FileManager.default.removeItem(at: mutatorPlist)
            buddyLog("setup: evolution service disabled")
        }
        refreshAll()
    }
}
