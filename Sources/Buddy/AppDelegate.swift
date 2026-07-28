import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: BuddyController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        BuddyPaths.bootstrap()
        controller = BuddyController()
        controller.start()
    }
}
