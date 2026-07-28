import Foundation

// Runs `claude -p` off the main thread, one request at a time.
final class Think {
    private let queue = DispatchQueue(label: "buddy.think")

    func ask(_ prompt: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let persona = (try? String(contentsOf: BuddyPaths.persona, encoding: .utf8)) ?? ""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["claude", "-p", "--model", "haiku"]
            var env = ProcessInfo.processInfo.environment
            let extra = ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + extra
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = Pipe()
            do {
                try p.run()
            } catch {
                buddyLog("think: cannot launch claude: \(error)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let full = persona.isEmpty ? prompt : persona + "\n\n" + prompt
            if let d = full.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(d)
            }
            inPipe.fileHandleForWriting.closeFile()

            var out = Data()
            let reader = DispatchQueue(label: "buddy.think.read")
            let sem = DispatchSemaphore(value: 0)
            reader.async {
                out = outPipe.fileHandleForReading.readDataToEndOfFile()
                sem.signal()
            }
            if sem.wait(timeout: .now() + 60) == .timedOut {
                p.terminate()
                _ = sem.wait(timeout: .now() + 5)
            }
            let text = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion((text?.isEmpty ?? true) ? nil : text)
            }
        }
    }
}
