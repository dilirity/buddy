import AppKit

final class BuddyController: NSObject, SpriteViewDelegate {
    let scale: CGFloat = 5

    private(set) var sheet: SpriteSheet = SpriteLoader.fallback()
    private var panel: BuddyPanel!
    private var view: SpriteView!
    private var bubble = SpeechBubble()
    let brain = Brain()
    private let senses = Senses()
    // Read fresh on every use so settings-window changes apply immediately.
    private var invariants: Invariants { Invariants.load() }
    private let settings = SettingsWindow()
    let music = MusicBridge()
    private let talk = TalkPanel()
    private var statusItem: NSStatusItem!

    private var currentAnim = ""
    private var frameIndex = 0
    private var animTimer: Timer?
    private var lastAnimChange = Date()
    private var pendingAnim: String?

    private var moveTarget: NSPoint?
    private var moveSpeed: CGFloat = 120
    private var moveTimer: Timer?
    private var chasing = false
    private var chaseDeadline = Date()
    private var chaseOffset = CGPoint.zero
    // approach = live-track the cursor but arrive beside it (emits "arrived");
    // chase = catch it exactly (emits "caught"/"gaveUp").
    private var approachMode = false

    private(set) var held = false
    private var frozenUntil: Date?
    private var unfreezeTimer: Timer?
    private var disruptiveTimestamps: [Date] = []
    private var grabTimer: Timer?
    private var testModeUntil: Date?
    private var testModeItem: NSMenuItem?
    private var testMenuItem: NSMenuItem?
    private var whatsNewItem: NSMenuItem?
    private var evolveItem: NSMenuItem?
    private var evolveProcess: Process?
    private var evolveStartSignature = ""
    private var externalEvolveActive = false

    var evolving: Bool { evolveProcess != nil || externalEvolveActive }

    var testMode: Bool {
        if let until = testModeUntil, until > Date() { return true }
        return false
    }

    var isFrozen: Bool {
        if let until = frozenUntil, until > Date() { return true }
        return false
    }

    func start() {
        if let loaded = SpriteLoader.load(from: BuddyPaths.sprites) {
            sheet = loaded
        } else {
            buddyLog("sprites.json missing or invalid, using fallback sprite")
        }
        let size = NSSize(width: sheet.pixelSize.width * scale, height: sheet.pixelSize.height * scale)
        panel = BuddyPanel(size: size)
        view = SpriteView(frame: NSRect(origin: .zero, size: size))
        view.delegate = self
        panel.contentView = view

        // start bottom-right-ish
        if let vis = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 60, y: vis.minY + 40))
        }
        panel.orderFrontRegardless()

        bubble.onHide = { [weak self] in self?.setProp(nil) }
        talk.onSubmit = { [weak self] text in
            guard let self else { return }
            self.play("scheming")
            self.brain.emit("chat", ["text": text])
        }

        setupStatusItem()

        brain.controller = self
        brain.reload()
        senses.controller = self
        senses.start()

        play("idle")

        // Watchdog: transient anims (excited, scheming, ...) must not stick.
        // Behaviors are supposed to return to idle themselves; when their timer
        // chain gets interrupted (freeze, reload), this catches it.
        commonTimer(10, repeats: true) { [weak self] _ in
            guard let self, !self.held, !self.isFrozen else { return }
            let transient = !["idle", "walk", "sleep", "evolve"].contains(self.currentAnim)
            if transient && Date().timeIntervalSince(self.lastAnimChange) > 15 {
                self.play("idle")
            }
        }
    }

    // MARK: - Animation

    // Staged playback convention: an anim "x" may define "x.in" / "x.out" in
    // sprites.json. play("x") runs x.in once, then loops x; switching away from
    // x runs x.out first. Pure data - the mutator stages anims by adding frames.
    func play(_ name: String) {
        if isFrozen && name != "sleep" { return }
        let resolved = sheet.anims[name] != nil ? name : "idle"
        if currentAnim == resolved { return }
        if currentAnim == resolved + ".in" && pendingAnim == resolved { return }
        if !currentAnim.isEmpty, !currentAnim.hasSuffix(".in"), !currentAnim.hasSuffix(".out"),
           sheet.anims[currentAnim + ".out"] != nil {
            pendingAnim = resolved
            startAnim(currentAnim + ".out")
            return
        }
        startWithIntro(resolved)
    }

    private func startWithIntro(_ name: String) {
        if sheet.anims[name + ".in"] != nil {
            pendingAnim = name
            startAnim(name + ".in")
        } else {
            pendingAnim = nil
            startAnim(name)
        }
    }

    private func startAnim(_ name: String) {
        guard let anim = sheet.anims[name] else { pendingAnim = nil; return }
        currentAnim = name
        lastAnimChange = Date()
        frameIndex = 0
        animTimer?.invalidate()
        view.setImage(anim.frames[0])
        // Transitions must terminate even if someone marks them looping.
        let oneShot = !anim.loops || name.hasSuffix(".in") || name.hasSuffix(".out")
        guard anim.frames.count > 1 || oneShot else { animTimer = nil; return }
        animTimer = commonTimer(1.0 / max(1, anim.fps), repeats: true) { [weak self] t in
            guard let self, let anim = self.sheet.anims[self.currentAnim] else { t.invalidate(); return }
            self.frameIndex += 1
            if self.frameIndex >= anim.frames.count {
                if oneShot {
                    self.frameIndex = anim.frames.count - 1
                    t.invalidate()
                    self.animTimer = nil
                    self.advanceAnimQueue()
                    return
                }
                self.frameIndex = 0
            }
            self.view.setImage(anim.frames[self.frameIndex])
        }
    }

    private func advanceAnimQueue() {
        guard let next = pendingAnim else { return }
        pendingAnim = nil
        if currentAnim.hasSuffix(".out") {
            startWithIntro(next)
        } else {
            startAnim(next)
        }
    }

    // MARK: - Movement

    func spriteOrigin() -> NSPoint { panel.frame.origin }

    var isMovingNow: Bool { moveTimer != nil }

    func setProp(_ name: String?) {
        guard let name, !name.isEmpty, let img = sheet.props[name] else {
            view.setProp(nil)
            return
        }
        view.setProp(img)
    }

    func moveTo(_ target: NSPoint, speed: Double) {
        guard !held, !isFrozen, !evolving else { return }
        // Clamp so no behavior can walk buddy off screen.
        var t = target
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            t.x = min(max(t.x, vis.minX), vis.maxX - size.width)
            t.y = min(max(t.y, vis.minY), vis.maxY - size.height)
        }
        moveTarget = t
        chasing = false
        moveSpeed = CGFloat(speed)
        startMoveTimer()
    }

    // Live pursuit: retargets to the cursor every frame. Emits "caught" on
    // contact, "gaveUp" after 10s of failed chase.
    func chaseCursor(speed: Double) {
        guard !held, !isFrozen, !evolving else { return }
        moveTarget = nil
        chasing = true
        approachMode = false
        chaseOffset = .zero
        chaseDeadline = Date().addingTimeInterval(10)
        moveSpeed = CGFloat(speed)
        startMoveTimer()
    }

    // Live cursor-relative movement: buddy's center lands at cursor + offset,
    // retargeting every frame. The shared primitive for every "go to the
    // cursor-ish" behavior - snapshots of a moving cursor are always wrong.
    func approachCursor(speed: Double, dx: Double, dy: Double) {
        guard !held, !isFrozen, !evolving else { return }
        moveTarget = nil
        chasing = true
        approachMode = true
        chaseOffset = CGPoint(x: dx, y: dy)
        chaseDeadline = Date().addingTimeInterval(10)
        moveSpeed = CGFloat(speed)
        startMoveTimer()
    }

    private func startMoveTimer() {
        guard moveTimer == nil else { return }
        moveTimer = commonTimer(1.0 / 60, repeats: true) { [weak self] _ in
            self?.stepMove()
        }
    }

    func stopMoving() {
        moveTimer?.invalidate()
        moveTimer = nil
        moveTarget = nil
        chasing = false
        approachMode = false
    }

    private func stepMove() {
        guard !held, !isFrozen else {
            stopMoving()
            return
        }
        let size = panel.frame.size
        let target: NSPoint
        if chasing {
            if Date() > chaseDeadline {
                let wasApproach = approachMode
                stopMoving()
                // A best-effort visit that ran out of time still "arrives";
                // only a failed catch is a gaveUp.
                brain.emit(wasApproach ? "arrived" : "gaveUp")
                return
            }
            let m = NSEvent.mouseLocation
            target = NSPoint(x: m.x + chaseOffset.x - size.width / 2,
                             y: m.y + chaseOffset.y - (approachMode ? size.height / 2 : size.height * 0.4))
            // Live targets need the same clamp as moveTo - a cursor at the
            // screen edge must not lead buddy off screen.
            let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
            if let vis = screen?.visibleFrame {
                target.x = min(max(target.x, vis.minX), vis.maxX - size.width)
                target.y = min(max(target.y, vis.minY), vis.maxY - size.height)
            }
        } else if let t = moveTarget {
            target = t
        } else {
            stopMoving()
            return
        }
        let origin = panel.frame.origin
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let dist = hypot(dx, dy)
        if dist < (chasing ? 16 : 4) {
            let event = chasing && !approachMode ? "caught" : "arrived"
            stopMoving()
            brain.emit(event)
            return
        }
        let step = min(dist, moveSpeed / 60)
        view.setFacingLeft(dx < 0)
        let next = NSPoint(x: origin.x + dx / dist * step, y: origin.y + dy / dist * step)
        panel.setFrameOrigin(next)
        bubble.reposition(near: panel.frame)
    }

    // MARK: - Speech

    func say(_ text: String, seconds: Double, prop propName: String? = nil) {
        guard !isFrozen else { return }
        // The prop lives and dies with the line: replaced by the next say,
        // stripped when the bubble hides. No parallel cleanup timers.
        setProp(propName)
        // Behaviors can ask for longer, never shorter than a readable duration.
        let minRead = 1.5 + Double(text.count) * 0.06
        bubble.show(text, near: panel.frame, seconds: max(seconds, minRead))
    }

    // MARK: - Disruption budget (invariant-enforced)

    // Shell-level surgery lockdown: while evolving, disruptive and movement
    // verbs refuse natively so no behavior - present or future-mutated - can
    // act out mid-evolution. Guards in JS are courtesy; this is the law.
    private func allowDisruptive() -> Bool {
        guard !isFrozen, !evolving else { return false }
        if testMode { return true }
        let cutoff = Date().addingTimeInterval(-3600)
        disruptiveTimestamps.removeAll { $0 < cutoff }
        guard disruptiveTimestamps.count < invariants.maxDisruptivePerHour else { return false }
        disruptiveTimestamps.append(Date())
        return true
    }

    func warpCursor(to point: NSPoint) -> Bool {
        guard allowDisruptive() else { return false }
        warpCursorRaw(to: point)
        return true
    }

    private func warpCursorRaw(to point: NSPoint) {
        guard let main = NSScreen.screens.first else { return }
        // Cocoa (bottom-left origin) to CG global (top-left origin)
        let cg = CGPoint(x: point.x, y: main.frame.height - point.y)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // Pin the cursor to buddy for a few seconds - the "steal". One disruptive act.
    func grabCursor(seconds: Double) -> Bool {
        guard allowDisruptive() else { return false }
        grabTimer?.invalidate()
        let end = Date().addingTimeInterval(min(max(seconds, 0.5), 8))
        grabTimer = commonTimer(1.0 / 30, repeats: true) { [weak self] t in
            guard let self, Date() < end, !self.isFrozen, !self.held else {
                t.invalidate()
                self?.grabTimer = nil
                return
            }
            let f = self.panel.frame
            self.warpCursorRaw(to: NSPoint(x: f.midX, y: f.midY - 10))
        }
        return true
    }

    // MARK: - Window awareness + hiding (granted wishes)

    private var layerRestoreTimer: Timer?
    private var opacityRestoreTimer: Timer?

    // On-screen normal windows of other apps, Cocoa coords.
    func windowList() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        var out: [[String: Any]] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != myPID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let width = (b["Width"] as? NSNumber)?.doubleValue,
                  let height = (b["Height"] as? NSNumber)?.doubleValue,
                  width > 60, height > 60 else { continue }
            out.append([
                "x": x,
                "y": Double(screenH) - y - height,
                "w": width,
                "h": height,
                "app": w[kCGWindowOwnerName as String] as? String ?? "?",
            ])
        }
        return out
    }

    // "behind" drops buddy under normal app windows (real hiding). The shell
    // always restores front - after 120s, on drag, on freeze - so buddy can
    // never be lost back there. That guarantee is native, not brain-trusted.
    func setLayer(behind: Bool) {
        layerRestoreTimer?.invalidate()
        layerRestoreTimer = nil
        if behind {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
            layerRestoreTimer = commonTimer(120, repeats: false) { [weak self] _ in
                self?.setLayer(behind: false)
            }
        } else {
            panel.level = .screenSaver
        }
    }

    // Clamped so buddy can never turn fully invisible; auto-restores.
    func setOpacity(_ value: Double) {
        let v = max(0.15, min(1.0, value))
        panel.alphaValue = v
        opacityRestoreTimer?.invalidate()
        opacityRestoreTimer = nil
        if v < 1.0 {
            opacityRestoreTimer = commonTimer(90, repeats: false) { [weak self] _ in
                self?.panel.alphaValue = 1.0
            }
        }
    }

    // MARK: - Freeze / panic

    func togglePanic() {
        if isFrozen {
            unfreeze()
        } else {
            freeze(minutes: invariants.panicFreezeMinutes)
        }
    }

    func freeze(minutes: Int) {
        frozenUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        stopMoving()
        bubble.hide()
        setProp(nil)
        setLayer(behind: false)
        setOpacity(1)
        currentAnim = ""
        pendingAnim = nil
        play("sleep")
        unfreezeTimer?.invalidate()
        unfreezeTimer = commonTimer(TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.unfreeze()
        }
        buddyLog("frozen for \(minutes) min")
    }

    func unfreeze() {
        frozenUntil = nil
        unfreezeTimer?.invalidate()
        unfreezeTimer = nil
        currentAnim = ""
        pendingAnim = nil
        play("idle")
        brain.emit("unfrozen")
        buddyLog("unfrozen")
    }

    // MARK: - Reload

    func reloadBrainAndSprites() {
        if let loaded = SpriteLoader.load(from: BuddyPaths.sprites) {
            sheet = loaded
            let size = NSSize(width: sheet.pixelSize.width * scale, height: sheet.pixelSize.height * scale)
            let origin = panel.frame.origin
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            view.frame = NSRect(origin: .zero, size: size)
        }
        currentAnim = ""
        pendingAnim = nil
        setProp(nil)
        brain.reload()
        rebuildTestMenu()
        play("idle")
        brain.emit("brainChanged")
    }

    // MARK: - SpriteViewDelegate

    func spriteDragStarted() {
        held = true
        stopMoving()
        setLayer(behind: false)
        setOpacity(1)
        brain.emit("dragStart")
    }

    func spriteDragged(to origin: NSPoint) {
        bubble.reposition(near: panel.frame)
    }

    func spriteDragEnded() {
        held = false
        let o = panel.frame.origin
        brain.emit("dragEnd", ["x": o.x, "y": o.y])
    }

    func spritePoked() {
        brain.emit("poked")
    }

    func spriteTalkRequested() {
        guard !isFrozen, !evolving else { return }
        talk.open(near: panel.frame)
    }

    // Gated music verbs. Starting/changing music spends disruption budget;
    // pausing is always free - stopping noise is never hostile.
    func musicPlay(playlist: String?) -> Bool {
        guard allowDisruptive() else { return false }
        music.play(playlist: playlist)
        return true
    }

    func musicNext() -> Bool {
        guard allowDisruptive() else { return false }
        music.next()
        return true
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "ᴥ"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Freeze / Wake", action: #selector(menuTogglePanic), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Brain", action: #selector(menuReload), keyEquivalent: ""))
        menu.addItem(.separator())
        let test = NSMenuItem(title: "Chaos Test Mode (1h, no limits)", action: #selector(menuToggleTestMode), keyEquivalent: "")
        testModeItem = test
        menu.addItem(test)
        let fresh = NSMenuItem(title: "What's New ✨", action: nil, keyEquivalent: "")
        whatsNewItem = fresh
        menu.addItem(fresh)
        let tests = NSMenuItem(title: "Test Interactions", action: nil, keyEquivalent: "")
        testMenuItem = tests
        menu.addItem(tests)
        let evolve = NSMenuItem(title: "Evolve Now", action: #selector(menuEvolveNow), keyEquivalent: "")
        evolveItem = evolve
        menu.addItem(evolve)
        rebuildTestMenu()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Talk to Buddy…", action: #selector(menuTalk), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Brain Folder", action: #selector(menuOpenBrain), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(menuQuit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    // The Test submenu is data: brain/tests.json defines entries, each fires a
    // test:<id> event handled in the brain. Entries added since the last
    // evolution (diff vs tests.prev.json, snapshotted by mutator/run.sh) show
    // under "What's New" until the next evolution graduates them.
    private func rebuildTestMenu() {
        let entries = Self.loadTests(BuddyPaths.brain.appendingPathComponent("tests.json"))
        let prevIDs = Set(Self.loadTests(BuddyPaths.home.appendingPathComponent("tests.prev.json")).map { $0.0 })
        let fresh = prevIDs.isEmpty ? [] : entries.filter { !prevIDs.contains($0.0) }
        let regular = entries.filter { id, _ in !fresh.contains { $0.0 == id } }

        if let item = whatsNewItem {
            item.isHidden = fresh.isEmpty
            item.submenu = submenu(for: fresh, emptyTitle: "")
        }
        if let item = testMenuItem {
            item.submenu = submenu(for: regular, emptyTitle: "tests.json missing or invalid")
        }
    }

    private static func loadTests(_ url: URL) -> [(String, String)] {
        guard let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else { return [] }
        return list.compactMap { t in
            guard let id = t["id"], let title = t["title"] else { return nil }
            return (id, title)
        }
    }

    private func submenu(for entries: [(String, String)], emptyTitle: String) -> NSMenu {
        let sub = NSMenu()
        for (id, title) in entries {
            let mi = NSMenuItem(title: title, action: #selector(menuRunTest(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            sub.addItem(mi)
        }
        if sub.items.isEmpty && !emptyTitle.isEmpty {
            sub.addItem(NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: ""))
        }
        return sub
    }

    // MARK: - Evolution

    @objc private func menuEvolveNow() { runEvolve() }

    func runEvolve() {
        guard evolveProcess == nil else { return }
        let script = BuddyPaths.home.appendingPathComponent("mutator/run.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            say("no mutator installed. run install.sh first", seconds: 5)
            return
        }
        evolveStartSignature = Senses.currentBrainSignature()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.evolveFinished() }
        }
        do {
            try p.run()
        } catch {
            buddyLog("evolve: failed to launch: \(error)")
            say("evolution failed to start. embarrassing.", seconds: 5)
            return
        }
        evolveProcess = p
        beginEvolveUI()
        buddyLog("evolution started")
        brain.emit("evolveStart")
        // A hung mutation must not pin the menu on "Evolving…" forever.
        commonTimer(900, repeats: false) { [weak self] _ in
            guard let self, let running = self.evolveProcess, running === p else { return }
            buddyLog("evolution timed out, terminating")
            running.terminate()
        }
    }

    private func beginEvolveUI() {
        evolveItem?.title = "Evolving…"
        evolveItem?.action = nil
        view.dragEnabled = false
    }

    private func evolveFinished() {
        evolveProcess = nil
        externalEvolveActive = false
        evolveItem?.title = "Evolve Now"
        evolveItem?.action = #selector(menuEvolveNow)
        view.dragEnabled = true
        let changed = Senses.currentBrainSignature() != evolveStartSignature
        buddyLog("evolution finished, changed: \(changed)")
        if changed {
            reloadBrainAndSprites()
        }
        senses.resync()
        brain.emit("evolveEnd", ["changed": changed])
    }

    // The nightly mutation runs via launchd, not through this app - the
    // evolving.lock (taken by run.sh) is how we notice and run the same
    // ritual: anim, paused hot-reload, locked dragging, proper ending.
    func evolveLockChanged(exists: Bool) {
        if exists {
            guard !evolving else { return }
            externalEvolveActive = true
            evolveStartSignature = Senses.currentBrainSignature()
            beginEvolveUI()
            buddyLog("external evolution detected")
            brain.emit("evolveStart")
        } else if externalEvolveActive {
            evolveFinished()
        }
    }

    @objc private func menuRunTest(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if isFrozen { unfreeze() }
        brain.emit("test:\(id)")
    }

    @objc private func menuTogglePanic() { togglePanic() }
    @objc private func menuReload() { reloadBrainAndSprites() }
    @objc private func menuOpenBrain() { NSWorkspace.shared.open(BuddyPaths.brain) }
    @objc private func menuSettings() { settings.show() }
    @objc private func menuTalk() { spriteTalkRequested() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuToggleTestMode() {
        if testMode {
            testModeUntil = nil
            testModeItem?.state = .off
            say("aww. limits are back.", seconds: 3)
        } else {
            testModeUntil = Date().addingTimeInterval(3600)
            testModeItem?.state = .on
            say("NO LIMITS?? oh this is gonna be GREAT", seconds: 4)
            play("excited")
        }
        brain.emit("testMode", ["on": testMode])
    }
}
