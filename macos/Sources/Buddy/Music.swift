import AppKit

// Music control via hand-carved AppleScript verbs only - never a general
// scripting surface. Controls Spotify when it's running, Apple Music otherwise.
// All ops run off the main thread (first use triggers the Automation
// permission prompt, which blocks).
final class MusicBridge {
    private let queue = DispatchQueue(label: "buddy.music")

    private func osa(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runningPlayer() -> String? {
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        if names.contains("Spotify") { return "Spotify" }
        if names.contains("Music") { return "Music" }
        return nil
    }

    func status(_ completion: @escaping ([String: Any]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var result: [String: Any] = ["app": "none", "state": "stopped"]
            if let player = self.runningPlayer() {
                result["app"] = player
                let state = self.osa("tell application \"\(player)\" to player state as string") ?? "stopped"
                result["state"] = state
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Deliberately trigger the one-time Automation prompt (setup front-loads
    // every permission prompt instead of letting one surface mid-behavior
    // weeks later). Pokes the running player with a harmless query; launches
    // Music if none is running and quits it again afterwards.
    func requestAccess() {
        queue.async { [weak self] in
            guard let self else { return }
            let already = self.runningPlayer()
            let player = already ?? "Music"
            _ = self.osa("tell application \"\(player)\" to player state as string")
            if already == nil {
                _ = self.osa("tell application \"Music\" to quit")
            }
        }
    }

    func play(playlist: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let player = self.runningPlayer() ?? "Music"
            if let playlist, player == "Music" {
                let safe = playlist.replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "\\", with: "")
                _ = self.osa("tell application \"Music\" to play playlist \"\(safe)\"")
            } else {
                _ = self.osa("tell application \"\(player)\" to play")
            }
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, let player = self.runningPlayer() else { return }
            _ = self.osa("tell application \"\(player)\" to pause")
        }
    }

    func next() {
        queue.async { [weak self] in
            guard let self, let player = self.runningPlayer() else { return }
            _ = self.osa("tell application \"\(player)\" to next track")
        }
    }
}
