import Foundation

// Buddy's standing consciousness: ONE persistent `claude -p` streaming session
// instead of a cold CLI boot per thought - replies at model speed (~1-2s).
// Turns serialize through the session; the process is recycled after enough
// turns (context growth) and on brain reload (persona may have evolved).
final class Think {
    private let queue = DispatchQueue(label: "buddy.think")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var waiting: [(String?) -> Void] = []
    private var turns = 0
    private var timeout: DispatchSourceTimer?
    private let maxTurns: Int

    init(maxTurns: Int = 40) {
        self.maxTurns = maxTurns
    }

    func ask(_ prompt: String, completion: @escaping (String?) -> Void) {
        queue.async {
            self.ensureProcess()
            guard let stdin = self.stdinHandle else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let msg: [String: Any] = [
                "type": "user",
                "message": ["role": "user",
                            "content": [["type": "text", "text": prompt]]],
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: msg) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            data.append(0x0a)
            self.waiting.append(completion)
            stdin.write(data)
            self.armTimeout()
        }
    }

    // Persona lives in the session's system prompt - a reload may have evolved
    // it, so the consciousness restarts fresh - and immediately re-warms in
    // the background so the next thought never pays the boot.
    func reset() {
        queue.async {
            self.teardown()
            self.ensureProcess()
        }
    }

    private func ensureProcess() {
        if let p = process, p.isRunning { return }
        teardown()

        let persona = (try? String(contentsOf: BuddyPaths.persona, encoding: .utf8)) ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["claude", "-p", "--model", "haiku",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose"]
        if !persona.isEmpty {
            args += ["--append-system-prompt", persona]
        }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + extra
        // Buddy must not react to the echo of its own thoughts.
        env["BUDDY_SELF"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.queue.async { self.consume(d) }
        }
        p.terminationHandler = { [weak self] dead in
            guard let self else { return }
            self.queue.async {
                guard self.process === dead else { return }
                buddyLog("think: session ended (exit \(dead.terminationStatus))")
                self.teardown()
            }
        }
        do {
            try p.run()
        } catch {
            buddyLog("think: cannot launch claude: \(error)")
            return
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        turns = 0
        buddyLog("think: warm session started")
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  json["type"] as? String == "result" else { continue }
            let text = (json["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            deliver((text?.isEmpty ?? true) ? nil : text)
        }
    }

    private func deliver(_ text: String?) {
        guard !waiting.isEmpty else { return }
        let completion = waiting.removeFirst()
        DispatchQueue.main.async { completion(text) }
        turns += 1
        if waiting.isEmpty {
            disarmTimeout()
            if turns >= maxTurns {
                // Recycle between thoughts so context never balloons - and
                // re-warm so the next thought doesn't pay for it.
                teardown()
                ensureProcess()
            }
        } else {
            armTimeout()
        }
    }

    private func armTimeout() {
        disarmTimeout()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 90)
        t.setEventHandler { [weak self] in
            buddyLog("think: turn timed out, recycling session")
            self?.teardown()
        }
        t.resume()
        timeout = t
    }

    private func disarmTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func teardown() {
        disarmTimeout()
        if let p = process {
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
        }
        if let out = (process?.standardOutput as? Pipe) {
            out.fileHandleForReading.readabilityHandler = nil
        }
        try? stdinHandle?.close()
        process = nil
        stdinHandle = nil
        buffer.removeAll()
        let stranded = waiting
        waiting.removeAll()
        for completion in stranded {
            DispatchQueue.main.async { completion(nil) }
        }
    }
}
