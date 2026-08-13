import AppKit

final class BuddyController: NSObject, SpriteViewDelegate, NSMenuDelegate {
    let scale: CGFloat = 5

    private(set) var sheet: SpriteSheet = SpriteLoader.fallback()
    private var panel: BuddyPanel!
    private var view: SpriteView!
    private var bubble = SpeechBubble()
    let brain = Brain()
    private let tweeter = Tweeter()
    private let senses = Senses()
    var coordination: Coordination!
    // Read fresh on every use so settings-window changes apply immediately.
    private var invariants: Invariants { Invariants.load() }
    private let settings = SettingsWindow()
    private let setup = SetupWindow()
    private let onboarding = OnboardingWindow()
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
    // approach = live-track the cursor but arrive beside it (emits "arrived"/"gaveUp");
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
    private var devicesItem: NSMenuItem?
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

    // Buddy is on another device. The brain keeps running (timers, senses),
    // but nothing it does may be visible or audible here - one buddy, ever.
    var buddyAway: Bool {
        coordination != nil && !coordination.ownsBuddy
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

        bubble.onHide = { [weak self] in self?.stripSayWornProp() }
        talk.onSubmit = { [weak self] text in
            guard let self else { return }
            self.play("scheming")
            self.brain.emit("chat", ["text": text])
        }

        setupStatusItem()

        brain.controller = self
        tweeter.controller = self
        brain.reload()
        senses.controller = self
        senses.start()

        coordination = Coordination(deviceId: "mac", rank: 1, owner: true)
        setup.peersProvider = { [weak self] in self?.coordination.knownPeers ?? [] }
        setup.keyAccessProvider = { [weak self] in self?.keyAccessGranted ?? AXIsProcessTrusted() }
        setup.onSpendChanged = { [weak self] in self?.brain.spendConfigChanged() }
        settings.systemPane = setup
        settings.onConfigSaved = { [weak self] key in
            guard key == "bodyColor", let self else { return }
            self.reloadSprites()
            self.play("idle")
        }
        setup.onOpenYourWorld = { [weak self] in self?.settings.show(tab: .world) }
        // Interview done -> hand off to the switches: permissions, chat,
        // evolution all live on the System tab and default to off.
        onboarding.onSaved = { [weak self] in
            self?.brain.reload()
            self?.say("that's the who. now the switches: what am i allowed to do?", seconds: 6)
            self?.settings.show(tab: .system)
        }
        coordination.onDepart = { [weak self] in
            guard let self else { return }
            self.stopMoving()
            self.bubble.hide()
            self.panel.orderOut(nil)
            // One buddy, ever: his stuff leaves the screen with him.
            self.setPlacementsVisible(false)
            buddyActivity("travelOut")
            self.brain.emit("travelDeparted")
        }
        coordination.onArrive = { [weak self] payload in
            guard let self else { return }
            // Buddy's soul travels with it: adopt the replicated traits
            // (clamped to the human's bounds like any other write).
            if let traits = payload["traits"] as? [String: Double] {
                for (name, value) in traits { _ = Traits.setValue(name, to: value) }
            }
            buddyActivity("travelIn")
            self.resetPresentation()
            self.setPlacementsVisible(true)
            self.panel.orderFrontRegardless()
            self.play("excited")
            if let line = payload["line"] as? String { self.say(line, seconds: 5) }
            self.brain.emit("travelArrived", payload)
        }
        coordination.snapshot = { ["traits": Traits.values(), "traitSpecs": Traits.specs()] }
        coordination.onSnapshot = { payload in
            // Trait edits made wherever buddy lives apply here too (clamped
            // to the human's bounds as always; bounds themselves never replicate in).
            if let traits = payload["traits"] as? [String: Double] {
                for (name, value) in traits { _ = Traits.setValue(name, to: value) }
            }
        }
        coordination.onTraitSet = { [weak self] name, value in
            // Follower device's settings edit: apply here (clamped), let the
            // trait watcher fire configChanged + broadcast as usual.
            _ = Traits.setValue(name, to: value)
            _ = self
        }
        if !coordination.ownsBuddy {
            panel.orderOut(nil)
        }

        play("idle")

        checkUpdateGrantLoss()
        watchPermissionChanges()

        // Fresh install: buddy introduces itself once (existing installs get
        // the marker from setup.sh and never see this).
        if OnboardingWindow.needed {
            commonTimer(2, repeats: false) { [weak self] _ in
                self?.say("oh. hi. you're new. or i am", seconds: 5)
                self?.onboarding.show()
            }
        }

        commonTimer(3600, repeats: true) { [weak self] _ in
            self?.checkEvolutionStaleness()
        }
        // launchd's 3:33 job drops slots missed while powered off, and its
        // sleep catch-up is not guaranteed - so also check shortly after
        // launch and on every wake. The delay gives launchd's own catch-up
        // first claim on the lock and lets the network come up.
        commonTimer(60, repeats: false) { [weak self] _ in
            self?.checkEvolutionStaleness()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            commonTimer(60, repeats: false) { _ in
                self?.checkEvolutionStaleness()
            }
        }
        ensurePhoneStream()
        commonTimer(30, repeats: true) { [weak self] _ in
            self?.ensurePhoneStream()
        }

        // Watchdog: transient anims (excited, scheming, ...) must not stick.
        // Behaviors are supposed to return to idle themselves; when their timer
        // chain gets interrupted (freeze, reload), this catches it.
        commonTimer(10, repeats: true) { [weak self] _ in
            guard let self, !self.held, !self.isFrozen, !self.brain.isBusyState() else { return }
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
        buddyActivity("anim", ["name": name])
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

    // Worn accessories, decoupled from speech: wear() persists until changed
    // or removed, while a say(prop:) is stripped when its bubble hides. The
    // flag tells the two apart so a bubble hiding never undresses a wear().
    private var sayWornHand = false

    @discardableResult
    func wear(_ slot: String, _ name: String?) -> Bool {
        guard SpriteView.propSlots.contains(slot) else { return false }
        if slot == "hand" { sayWornHand = false }
        guard let name, !name.isEmpty else {
            view.setProp(nil, slot: slot)
            return true
        }
        guard let img = sheet.props[name] else { return false }
        view.setProp(img, slot: slot)
        return true
    }

    func stripSayWornProp() {
        guard sayWornHand else { return }
        sayWornHand = false
        view.setProp(nil, slot: "hand")
    }

    // MARK: - Placed props (granted wish)

    // Persistent decals: a prop pinned to the screen until removed. Unlike a
    // worn prop these outlive the act that made them - the whole point is a
    // hoard pile that survives across days. State is the brain's job
    // (memory.json); the shell only draws, so a brain reload clears the
    // panels and the brain re-places from memory.
    private struct Placement {
        let name: String
        let panel: BuddyPanel
        let layer: CALayer
        // Crop insets of the visible art inside its authoring canvas (canvas
        // px, Cocoa-side bottom) - placeSwap uses them to keep swapped art
        // registered as drawn instead of snapping to the old corner.
        let cropX: CGFloat
        let cropBottom: CGFloat
    }

    // Granted wish (round two): placed props answer the mouse. A click pokes,
    // a drag relocates - the human can rearrange the hoard by hand. The brain
    // hears both, so it can persist new spots to memory.
    private final class PlacedPropView: NSView {
        var onPoke: (() -> Void)?
        var onMoved: ((NSPoint) -> Void)?
        private var dragging = false
        private var downPoint: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            dragging = false
            downPoint = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            if !dragging {
                let d = hypot(event.locationInWindow.x - downPoint.x,
                              event.locationInWindow.y - downPoint.y)
                if d < 4 { return }
                dragging = true
            }
            let m = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: m.x - downPoint.x, y: m.y - downPoint.y))
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                onMoved?(window?.frame.origin ?? .zero)
            } else {
                onPoke?()
            }
            dragging = false
        }
    }
    private var placements: [Int: Placement] = [:]
    private var nextPlacementId = 1
    // Above the hoard cap (10) but low enough that a runaway mutation can
    // never wallpaper the screen.
    private let maxPlacements = 12

    // Props are authored on buddy-sized canvases (worn-overlay alignment),
    // mostly transparent. A placed prop must occupy only its visible pixels -
    // for hit-testing and so the art sits exactly where asked.
    private func croppedToVisible(_ img: CGImage) -> (img: CGImage, cropX: CGFloat, cropBottom: CGFloat)? {
        let w = img.width, h = img.height
        guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data),
              img.bitsPerPixel == 32 else { return (img, 0, 0) }
        let bpr = img.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where ptr[y * bpr + x * 4 + 3] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = img.cropping(to: CGRect(x: minX, y: minY,
                                                    width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        // Image rows are top-down; Cocoa's y grows upward, so the bottom
        // inset is measured from the canvas's last row.
        return (cropped, CGFloat(minX), CGFloat(h - 1 - maxY))
    }

    func place(_ name: String, x: Double, y: Double) -> Int {
        guard !buddyAway, !isFrozen, !evolving,
              x.isFinite, y.isFinite,
              let raw = sheet.props[name],
              let (img, cropX, cropBottom) = croppedToVisible(raw),
              placements.count < maxPlacements else {
            buddyActivity("place", ["name": name, "allowed": false])
            return 0
        }
        let size = NSSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        var origin = NSPoint(x: x, y: y)
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        let p = BuddyPanel(size: size)
        let holder = PlacedPropView(frame: NSRect(origin: .zero, size: size))
        holder.wantsLayer = true
        let l = CALayer()
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.frame = holder.bounds
        l.contents = img
        holder.layer?.addSublayer(l)
        p.contentView = holder
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        let id = nextPlacementId
        nextPlacementId += 1
        holder.onPoke = { [weak self] in
            guard let self, !self.evolving, !self.buddyAway,
                  // Look up live: placeSwap may have renamed this placement.
                  let current = self.placements[id]?.name else { return }
            buddyActivity("placementPoked", ["id": id, "name": current])
            self.brain.emit("placementPoked", ["id": id, "name": current])
        }
        holder.onMoved = { [weak self] newOrigin in
            guard let self, let pl = self.placements[id] else { return }
            // Human's drag can end anywhere - clamp back on screen like
            // place(). Size and name read live: placeSwap may have changed both.
            var o = newOrigin
            let sz = pl.panel.frame.size
            let scr = NSScreen.screens.first { $0.frame.intersects(NSRect(origin: o, size: sz)) } ?? NSScreen.main
            if let vis = scr?.visibleFrame {
                o.x = min(max(o.x, vis.minX), vis.maxX - sz.width)
                o.y = min(max(o.y, vis.minY), vis.maxY - sz.height)
            }
            pl.panel.setFrameOrigin(o)
            buddyActivity("placementMoved", ["id": id, "name": pl.name, "x": Double(o.x), "y": Double(o.y)])
            self.brain.emit("placementMoved", ["id": id, "name": pl.name, "x": Double(o.x), "y": Double(o.y)])
        }
        placements[id] = Placement(name: name, panel: p, layer: l, cropX: cropX, cropBottom: cropBottom)
        buddyActivity("place", ["name": name, "x": Double(origin.x), "y": Double(origin.y),
                                "id": id, "allowed": true])
        return id
    }

    // Brain-driven relocation of a placed prop (carry choreography, tidying).
    // Same guards as place(); clamped the same way.
    func placeMove(_ id: Int, x: Double, y: Double) -> Bool {
        guard !buddyAway, !isFrozen, !evolving,
              x.isFinite, y.isFinite,
              let pl = placements[id] else { return false }
        let size = pl.panel.frame.size
        var origin = NSPoint(x: x, y: y)
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        pl.panel.setFrameOrigin(origin)
        return true
    }

    // Granted wish: atomic art swap on a placement - a chest hinge must not
    // blink through an unplace/place pair. Origin stays put; the panel
    // resizes to the new art and re-clamps in case it grew past an edge.
    func placeSwap(_ id: Int, to name: String) -> Bool {
        guard !buddyAway, !isFrozen, !evolving,
              let pl = placements[id],
              let raw = sheet.props[name],
              let (img, cropX, cropBottom) = croppedToVisible(raw) else {
            buddyActivity("placeSwap", ["id": id, "name": name, "allowed": false])
            return false
        }
        let size = NSSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        // Keep the arts registered as authored: props sharing a canvas (chest
        // stages) line up by canvas position, not by cropped corner.
        var origin = pl.panel.frame.origin
        origin.x -= (cropX - pl.cropX) * scale
        origin.y -= (cropBottom - pl.cropBottom) * scale
        let screen = NSScreen.screens.first { $0.frame.intersects(pl.panel.frame) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pl.layer.contents = img
        pl.panel.setFrame(NSRect(origin: origin, size: size), display: true)
        pl.panel.contentView?.frame = NSRect(origin: .zero, size: size)
        pl.layer.frame = NSRect(origin: .zero, size: size)
        CATransaction.commit()
        placements[id] = Placement(name: name, panel: pl.panel, layer: pl.layer,
                                   cropX: cropX, cropBottom: cropBottom)
        buddyActivity("placeSwap", ["id": id, "name": name, "allowed": true])
        return true
    }

    func unplace(_ id: Int) {
        guard let pl = placements.removeValue(forKey: id) else { return }
        pl.panel.orderOut(nil)
        buddyActivity("unplace", ["id": id])
    }

    func unplaceAll() {
        guard !placements.isEmpty else { return }
        for pl in placements.values { pl.panel.orderOut(nil) }
        placements.removeAll()
        buddyActivity("unplaceAll")
    }

    private func setPlacementsVisible(_ visible: Bool) {
        for pl in placements.values {
            if visible { pl.panel.orderFrontRegardless() } else { pl.panel.orderOut(nil) }
        }
    }

    // Granted wish: a TRUE instant blink - no visible commute. Emits
    // "arrived" so acts built on moveTo's until:"arrived" can swap it in.
    func teleport(to target: NSPoint) -> Bool {
        guard !held, !isFrozen, !evolving, !buddyAway,
              target.x.isFinite, target.y.isFinite else {
            buddyActivity("teleport", ["allowed": false])
            return false
        }
        stopMoving()
        var t = target
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            t.x = min(max(t.x, vis.minX), vis.maxX - size.width)
            t.y = min(max(t.y, vis.minY), vis.maxY - size.height)
        }
        panel.setFrameOrigin(t)
        bubble.reposition(near: panel.frame)
        buddyActivity("teleport", ["x": Double(t.x), "y": Double(t.y), "allowed": true])
        brain.emit("arrived")
        return true
    }

    func moveTo(_ target: NSPoint, speed: Double) {
        guard !held, !isFrozen, !evolving, !buddyAway else { return }
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
        buddyActivity("move", ["x": Double(t.x), "y": Double(t.y), "speed": speed])
        startMoveTimer()
    }

    // Live pursuit: retargets to the cursor every frame. Emits "caught" on
    // contact, "gaveUp" after 10s of failed chase.
    func chaseCursor(speed: Double) {
        guard !held, !isFrozen, !evolving, !buddyAway else { return }
        buddyActivity("chase", ["speed": speed])
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
        guard !held, !isFrozen, !evolving, !buddyAway else { return }
        buddyActivity("approach", ["speed": speed, "dx": dx, "dy": dy])
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
        var target: NSPoint
        if chasing {
            if Date() > chaseDeadline {
                let wasApproach = approachMode
                stopMoving()
                // A best-effort visit that ran out of time still "arrives";
                // only a failed catch is a gaveUp. Acts that care whether the
                // visit truly landed must distance-check on arrival.
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
        guard !isFrozen, !buddyAway else { return }
        buddyActivity("say", ["text": text, "prop": propName ?? ""])
        // A say prop lives and dies with the line: replaced by the next say,
        // stripped when the bubble hides. A wear()-worn hand prop is left alone.
        if let propName, !propName.isEmpty, let img = sheet.props[propName] {
            view.setProp(img, slot: "hand")
            sayWornHand = true
        } else {
            stripSayWornProp()
        }
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
        let allowed = !buddyAway && allowDisruptive()
        buddyActivity("cursorWarp", ["allowed": allowed])
        guard allowed else { return false }
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
        let allowed = !buddyAway && allowDisruptive()
        buddyActivity("cursorGrab", ["allowed": allowed, "seconds": seconds])
        guard allowed else { return false }
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

    // Baseline presentation. Acts fade/hide/dress buddy and promise to undo it
    // later - but brain continuity can break mid-act (hot reload, travel,
    // freeze), stranding native state like a 0.15 alpha. At every continuity
    // break the SHELL restores the baseline; JS promises are not load-bearing.
    func resetPresentation() {
        // Motion is act-owned state too: a dead act's moveTo must not keep
        // sliding an idle-posed buddy across the screen.
        stopMoving()
        setOpacity(1)
        setLayer(behind: false)
        sayWornHand = false
        for slot in SpriteView.propSlots { view.setProp(nil, slot: slot) }
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

    // MARK: - Phone (ntfy push + inbox chat)

    private var lastPhonePush = Date.distantPast
    private var lastPhoneReply = Date.distantPast
    private var phoneInboxSince = Int(Date().timeIntervalSince1970)
    private var phoneStream: Process?
    private var phoneStreamBuffer = Data()

    private func phoneConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: BuddyPaths.home.appendingPathComponent("phone.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // Replies to the human's phone messages: they initiated, so no disruption budget
    // and no 10-minute narrative gap - just a modest anti-runaway limit.
    // Real travel over the LAN coordination layer. Payload carries what the
    // arrival side needs to keep the fiction coherent; full state blob later.
    func travelOut(line: String, completion: @escaping (Bool) -> Void) {
        guard coordination != nil, coordination.hasPeer else {
            completion(false)
            return
        }
        coordination.travel(payload: ["line": line, "traits": Traits.values(),
                                      "traitSpecs": Traits.specs()]) { [weak self] ok in
            if !ok { self?.ntfyPoke() }
            completion(ok)
        }
    }

    // ntfy wake channel: the phone app looked reachable but did not answer -
    // poke it so a tap on the notification revives the service.
    private func ntfyPoke() {
        guard let topic = phoneConfig()?["topic"] as? String, !topic.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-m", "10", "-H", "Title: buddy",
                           "-H", "Click: buddy://wake",
                           "-d", "buddy tried to visit but your phone didnt answer. tap to wake the app.",
                           "https://ntfy.sh/\(topic)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
        }
    }

    func phoneReply(_ text: String) -> Bool {
        guard Date().timeIntervalSince(lastPhoneReply) > 15 else { return false }
        guard let topic = phoneConfig()?["topic"] as? String, !topic.isEmpty else { return false }
        lastPhoneReply = Date()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-m", "10", "-H", "Title: buddy", "-d", text,
                           "https://ntfy.sh/\(topic)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
        }
        return true
    }

    // Streaming inbox: one held-open connection to ntfy - the human's texts arrive
    // the instant he sends them, no polling lag. curl recycles hourly or on
    // any disconnect; the 30s keeper timer restarts it.
    func ensurePhoneStream() {
        guard phoneStream == nil else { return }
        let cfg = phoneConfig()
        let inbox = (cfg?["inbox"] as? String) ?? (cfg?["topic"] as? String) ?? ""
        guard !inbox.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sN", "--max-time", "3600",
                       "https://ntfy.sh/\(inbox)/json?since=\(phoneInboxSince)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.phoneStreamData(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                self?.phoneStream = nil
            }
        }
        do {
            try p.run()
            phoneStream = p
            buddyLog("phone stream connected")
        } catch {
            buddyLog("phone stream: \(error)")
        }
    }

    private func phoneStreamData(_ d: Data) {
        phoneStreamBuffer.append(d)
        while let nl = phoneStreamBuffer.firstIndex(of: 0x0a) {
            let line = phoneStreamBuffer.subdata(in: phoneStreamBuffer.startIndex..<nl)
            phoneStreamBuffer.removeSubrange(phoneStreamBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  json["event"] as? String == "message",
                  json["title"] as? String != "buddy",
                  let msg = json["message"] as? String else { continue }
            if let t = (json["time"] as? NSNumber)?.intValue {
                phoneInboxSince = max(phoneInboxSince, t + 1)
            }
            brain.emit("phoneChat", ["text": msg])
        }
    }

    // Send a push to the human's phone via ntfy. Hard-limited: shares the
    // disruption budget AND a native 10-minute minimum gap - a buzzing phone
    // is the most disruptive thing buddy can do.
    func phoneNotify(_ text: String) -> Bool {
        // Away = buddy IS on the phone; texting it from the mac breaks the fiction.
        guard !buddyAway else { return false }
        guard Date().timeIntervalSince(lastPhonePush) > 600 else {
            buddyActivity("phonePush", ["allowed": false])
            return false
        }
        guard let data = try? Data(contentsOf: BuddyPaths.home.appendingPathComponent("phone.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let topic = json["topic"] as? String, !topic.isEmpty else { return false }
        guard allowDisruptive() else {
            buddyActivity("phonePush", ["allowed": false])
            return false
        }
        buddyActivity("phonePush", ["allowed": true, "text": text])
        lastPhonePush = Date()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-m", "10", "-H", "Title: buddy", "-d", text,
                           "https://ntfy.sh/\(topic)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            buddyLog("phone push (exit \(p.terminationStatus))")
        }
        return true
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
        resetPresentation()
        currentAnim = ""
        pendingAnim = nil
        play("sleep")
        unfreezeTimer?.invalidate()
        unfreezeTimer = commonTimer(TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.unfreeze()
        }
        buddyActivity("freeze", ["minutes": minutes])
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
        buddyActivity("unfreeze")
        buddyLog("unfrozen")
    }

    // MARK: - Reload

    func reloadSprites() {
        if let loaded = SpriteLoader.load(from: BuddyPaths.sprites) {
            sheet = loaded
            let size = NSSize(width: sheet.pixelSize.width * scale, height: sheet.pixelSize.height * scale)
            let origin = panel.frame.origin
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            view.frame = NSRect(origin: .zero, size: size)
        }
        currentAnim = ""
        pendingAnim = nil
        // Re-render placed props from the new sheet (body-color change);
        // drop any whose prop no longer exists.
        for (id, pl) in placements {
            if let raw = sheet.props[pl.name], let (img, cropX, cropBottom) = croppedToVisible(raw) {
                let size = NSSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                pl.layer.contents = img
                pl.panel.setContentSize(size)
                pl.panel.contentView?.frame = NSRect(origin: .zero, size: size)
                pl.layer.frame = NSRect(origin: .zero, size: size)
                CATransaction.commit()
                placements[id] = Placement(name: pl.name, panel: pl.panel, layer: pl.layer,
                                           cropX: cropX, cropBottom: cropBottom)
            } else {
                unplace(id)
            }
        }
        resetPresentation()
    }

    func reloadBrainAndSprites() {
        reloadSprites()
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
        bubble.hide()
        // Carry mode: expand the panel over the whole screen and move only the
        // sprite layer - the window never drags, so tiling never engages.
        let spriteFrame = panel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(spriteFrame) } ?? NSScreen.main!
        panel.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.beginCarry(spriteSize: spriteFrame.size,
                        at: NSPoint(x: spriteFrame.minX - screen.frame.minX,
                                    y: spriteFrame.minY - screen.frame.minY))
        brain.emit("dragStart")
    }

    func spriteDragged(to origin: NSPoint) {
        // Bubble stays hidden while carried; nothing follows the layer.
    }

    func spriteDragEnded() {
        // Shrink the panel back around wherever the sprite layer landed.
        let so = view.carriedOrigin
        let size = NSSize(width: sheet.pixelSize.width * scale, height: sheet.pixelSize.height * scale)
        var origin = NSPoint(x: panel.frame.minX + so.x, y: panel.frame.minY + so.y)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        view.endCarry()
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        view.frame = NSRect(origin: .zero, size: size)
        held = false
        brain.emit("dragEnd", ["x": origin.x, "y": origin.y])
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
        let allowed = allowDisruptive()
        buddyActivity("musicPlay", ["allowed": allowed])
        guard allowed else { return false }
        music.play(playlist: playlist)
        return true
    }

    func musicNext() -> Bool {
        let allowed = allowDisruptive()
        buddyActivity("musicNext", ["allowed": allowed])
        guard allowed else { return false }
        music.next()
        return true
    }

    // Granted wish: one short whitelisted sound effect. The whitelist is
    // whatever the human installed in ~/.buddy/sounds - the brain can name
    // sounds but never add them. Spends disruption budget like any noise.
    private var currentSfx: NSSound?

    // Granted wish: buddy's X account. All safety lives in Tweeter.
    func tweet(_ text: String) -> Bool {
        tweeter.request(text)
    }

    func sfx(_ name: String) -> Bool {
        guard !buddyAway,
              !name.isEmpty,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              case let url = BuddyPaths.sounds.appendingPathComponent(name + ".wav"),
              FileManager.default.fileExists(atPath: url.path) else {
            buddyActivity("sfx", ["name": name, "allowed": false])
            return false
        }
        let allowed = allowDisruptive()
        buddyActivity("sfx", ["name": name, "allowed": allowed])
        guard allowed, let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        // Kept in a property: NSSound is not self-retaining during playback.
        currentSfx?.stop()
        sound.volume = 0.5
        sound.play()
        currentSfx = sound
        return true
    }

    // Live Accessibility state - the permission that gates the global key
    // monitor (typing sense, double-Esc panic; NSEvent global key monitors
    // are accessibility-trust APIs). Cursor tricks need no macOS permission;
    // they are governed by buddy's own settings. TCC broadcasts
    // com.apple.accessibility.api on grant changes; re-check on it
    // (debounced - it fires in bursts, for any app's change).
    private(set) var keyAccessGranted = AXIsProcessTrusted()
    private var permDebounce: Timer?

    func watchPermissionChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.permDebounce?.invalidate()
            self?.permDebounce = commonTimer(0.5, repeats: false) { _ in
                self?.refreshPermissions()
            }
        }
    }

    func refreshPermissions() {
        DispatchQueue.global().async { [weak self] in
            // Fresh helper process, not the in-process preflight: same
            // launch-time-caching trap AXIsProcessTrusted proved to have.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = ["--perm-check"]
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self, self.keyAccessGranted != ok else { return }
                self.keyAccessGranted = ok
                buddyLog("accessibility changed live: \(ok)")
                buddyActivity("permChanged", ["accessibility": ok])
                if ok { self.senses.armKeyMonitor() }
                self.say(ok ? "ooh I can feel you typing now" : "keyboard's gone dark. no more panic gesture",
                         seconds: 6)
            }
        }
    }

    // Buddy is deliberately unsigned, so macOS keys permission grants to the
    // binary's hash: every update voids Accessibility/Automation. Notice the
    // new body and point at Setup instead of silently losing cursor powers.
    private func checkUpdateGrantLoss() {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard let attrs = try? fm.attributesOfItem(atPath: exe.path),
              let size = attrs[.size] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else { return }
        let stamp = "\(size)-\(Int(mtime.timeIntervalSince1970))"
        let url = BuddyPaths.home.appendingPathComponent("binary-stamp")
        let old = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? stamp.data(using: .utf8)?.write(to: url)
        guard let old, old != stamp, !AXIsProcessTrusted() else { return }
        commonTimer(5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.say("new body! macOS wiped my permissions though. Settings > System has the fix", seconds: 8)
            self.settings.show(tab: .system)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "ᴥ"
        // Daily life first, one configuration entry point, dev tools folded
        // under Advanced - the menu is a stranger's first impression of buddy.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Talk to Buddy…", action: #selector(menuTalk), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Freeze / Wake", action: #selector(menuTogglePanic), keyEquivalent: ""))
        let fresh = NSMenuItem(title: "What's New ✨", action: nil, keyEquivalent: "")
        whatsNewItem = fresh
        menu.addItem(fresh)
        let tests = NSMenuItem(title: "Do a Trick", action: nil, keyEquivalent: "")
        testMenuItem = tests
        menu.addItem(tests)
        let evolve = NSMenuItem(title: "Evolve Now", action: #selector(menuEvolveNow), keyEquivalent: "")
        evolveItem = evolve
        menu.addItem(evolve)
        rebuildTestMenu()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu()
        advancedMenu.addItem(NSMenuItem(title: "Reload Brain", action: #selector(menuReload), keyEquivalent: ""))
        let test = NSMenuItem(title: "Chaos Test Mode (1h, no limits)", action: #selector(menuToggleTestMode), keyEquivalent: "")
        testModeItem = test
        advancedMenu.addItem(test)
        advancedMenu.addItem(NSMenuItem(title: "Open Brain Folder", action: #selector(menuOpenBrain), keyEquivalent: ""))
        let devices = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        devicesItem = devices
        advancedMenu.addItem(devices)
        for item in advancedMenu.items { item.target = self }
        advanced.submenu = advancedMenu
        menu.addItem(advanced)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(menuQuit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
        rebuildDevicesMenu()
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
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { t in
            guard let id = t["id"] as? String, let title = t["title"] as? String else { return nil }
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
            say("no mutator installed. run setup.sh first", seconds: 5)
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
        buddyActivity("evolveStart")
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
        buddyActivity("evolveEnd", ["changed": changed])
        buddyLog("evolution finished, changed: \(changed)")
        if changed {
            reloadBrainAndSprites()
        }
        senses.resync()
        brain.emit("evolveEnd", ["changed": changed])
    }

    // Missed nights happen (no network on dark wake, laptop shut down).
    // If the last successful evolution is stale, run one ourselves.
    func checkEvolutionStaleness() {
        guard !evolving, !isFrozen, !OnboardingWindow.needed else { return }
        let url = BuddyPaths.home.appendingPathComponent("last-evolution")
        let last = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let stale: Bool
        // Catch-up only makes sense for a schedule; manual/off never auto-runs.
        switch Spend.load().evolutionSchedule {
        case "nightly":
            // Stale = the most recent 3:33 slot passed with no success since,
            // not a flat 26h - a flat window drifted later every day and left
            // a missed night unrepaired for most of the next day.
            var slot = Calendar.current.date(
                bySettingHour: 3, minute: 33, second: 0, of: Date()) ?? Date()
            if slot > Date() { slot.addTimeInterval(-86400) }
            stale = last < slot.timeIntervalSince1970
        case "weekly":
            stale = Date().timeIntervalSince1970 - last > 8 * 24 * 3600
        default: return
        }
        if stale {
            buddyLog("evolution stale (last \(Int((Date().timeIntervalSince1970 - last) / 3600))h ago), auto-triggering")
            runEvolve()
        }
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

    // Live device roster, rebuilt every time the menu opens. Evolve Now only
    // exists while evolution is allowed at all (manual or scheduled).
    func menuWillOpen(_ menu: NSMenu) {
        rebuildDevicesMenu()
        evolveItem?.isHidden = Spend.load().evolutionSchedule == "off"
    }

    private func rebuildDevicesMenu() {
        guard let item = devicesItem else { return }
        let sub = NSMenu()
        let here = !buddyAway
        sub.addItem(NSMenuItem(title: "mac (this device)" + (here ? "  ● buddy is here" : ""),
                               action: nil, keyEquivalent: ""))
        let peers = coordination?.knownPeers ?? []
        for p in peers {
            let marker = !here && peers.count == 1 ? "  ● buddy is there" : ""
            sub.addItem(NSMenuItem(title: "\(p) - online" + marker, action: nil, keyEquivalent: ""))
        }
        if peers.isEmpty {
            sub.addItem(NSMenuItem(title: here ? "no other devices on the LAN"
                                              : "buddy is away - device not on the LAN",
                                   action: nil, keyEquivalent: ""))
        }
        item.submenu = sub
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
