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
