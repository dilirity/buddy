import AppKit

// `Buddy --check`: headless brain + sprite validation. The nightly mutator runs
// this after editing the brain and reverts its commit if anything fails to load.
// `Buddy --render [dir]`: render all anim frames + props to PNGs (default
// ~/.buddy/render) so a human - or the mutator's own eyes - can inspect looks.
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    BuddyPaths.bootstrap()
    let dir = CommandLine.arguments.count > idx + 1
        ? URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        : BuddyPaths.home.appendingPathComponent("render")
    exit(SpriteLint.render(to: dir) ? 0 : 1)
}

// `Buddy --perm-check`: report Accessibility (which gates the global key
// monitor) as a FRESH process. The in-process API only repeats its
// launch-time answer, so live status must come from a new process.
if CommandLine.arguments.contains("--perm-check") {
    exit(AXIsProcessTrusted() ? 0 : 1)
}

// `Buddy --hooks-dry <file>`: run the real hook install/remove logic against
// the given settings file (a copy, not the live one) and print each phase.
if let idx = CommandLine.arguments.firstIndex(of: "--hooks-dry"),
   CommandLine.arguments.count > idx + 1 {
    Hooks.settingsURL = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    print("installed: \(Hooks.installed())")
    print("install plan:\n" + Hooks.installPlan().joined(separator: "\n"))
    print("remove plan:\n" + Hooks.removePlan().joined(separator: "\n"))
    print("running remove(): \(Hooks.remove())")
    print("after remove, installed: \(Hooks.installed())")
    print("running install(): \(Hooks.install())")
    print("after install, installed: \(Hooks.installed())")
    exit(0)
}

if CommandLine.arguments.contains("--check") {
    BuddyPaths.bootstrap()
    var ok = true
    if SpriteLoader.load(from: BuddyPaths.sprites) == nil {
        print("FAIL: sprites.json missing or invalid")
        ok = false
    }
    for err in SpriteLint.run(BuddyPaths.sprites) {
        print("FAIL sprite lint: \(err)")
        ok = false
    }
    let brain = Brain()
    brain.reload()
    if brain.loadErrors > 0 {
        print("FAIL: \(brain.loadErrors) JS load error(s), see ~/.buddy/buddy.log")
        ok = false
    }
    print(ok ? "OK" : "CHECK FAILED")
    exit(ok ? 0 : 1)
}

// `Buddy --peer-sim`: headless fake peer for testing the coordination layer
// on localhost. Announces itself as "sim" (rank 2), accepts travel, then
// sends buddy back after 5s. Two-process protocol test, no Android needed.
if CommandLine.arguments.contains("--peer-sim") {
    BuddyPaths.bootstrap()
    try? FileManager.default.removeItem(
        at: BuddyPaths.home.appendingPathComponent("coordination-sim.json"))
    let coord = Coordination(deviceId: "sim", rank: 2, owner: false, listenPort: 47810)
    coord.onArrive = { payload in
        print("SIM: buddy arrived, payload line: \(payload["line"] as? String ?? "-")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            coord.travel(payload: ["line": "im BACK. the sim was small"]) { ok in
                print("SIM: travel back \(ok ? "acked" : "FAILED")")
            }
        }
    }
    coord.onDepart = { print("SIM: buddy departed") }
    print("SIM: up on 47810, waiting")
    RunLoop.main.run()
}

BuddyPaths.bootstrap()

// Single instance: autostart + Raycast/Spotlight launches must not spawn twins.
let instanceLock = open(BuddyPaths.home.appendingPathComponent("app.lock").path,
                        O_CREAT | O_RDWR, 0o644)
if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
