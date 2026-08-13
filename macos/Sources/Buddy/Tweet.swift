import CryptoKit
import Foundation
import Security

// Granted wish: buddy posts to its own X account. The brain only supplies
// intent (text); everything dangerous lives here, out of the mutator's reach:
// the hard daily cap, the LLM safety gate, and the OAuth credentials (Keychain,
// never readable from JS). Same contract as sfx: returns false when refused,
// acts must survive refusal.
final class Tweeter {
    weak var controller: BuddyController?

    // Hard ceiling regardless of any config - the brain cannot grind past it,
    // and a slot burns on acceptance (not on successful post) so gate-blocked
    // attempts still count against the day.
    static let dailyCap = 2

    private let stateURL = BuddyPaths.home.appendingPathComponent("tweets.json")
    private let queue = DispatchQueue(label: "buddy.tweet", qos: .utility)

    func request(_ text: String) -> Bool {
        guard Spend.load().tweetsEnabled else {
            return refuse(text, "disabled")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 280 else {
            return refuse(text, "length")
        }
        // Links and mentions are how a weird post becomes a harmful one -
        // buddy's tweets are self-contained nonsense by construction.
        let lower = trimmed.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://"),
              !trimmed.contains("@") else {
            return refuse(text, "links-or-mentions")
        }
        guard TweetCreds.load() != nil else {
            return refuse(text, "no-creds")
        }
        guard burnSlot() else {
            return refuse(text, "rate")
        }
        buddyActivity("tweet", ["allowed": true, "text": trimmed])
        queue.async { [weak self] in
            self?.gateAndPost(trimmed)
        }
        return true
    }

    private func refuse(_ text: String, _ reason: String) -> Bool {
        buddyActivity("tweet", ["allowed": false, "reason": reason, "text": text])
        return false
    }

    // MARK: - Daily slots (~/.buddy/tweets.json)

    private func burnSlot() -> Bool {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        var day = today
        var count = 0
        if let data = try? Data(contentsOf: stateURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            day = json["day"] as? String ?? today
            count = json["count"] as? Int ?? 0
        }
        if day != today { count = 0 }
        guard count < Tweeter.dailyCap else { return false }
        let json: [String: Any] = ["day": today, "count": count + 1]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateURL)
        }
        return true
    }

    // MARK: - LLM gate

    // One-shot haiku verdict, deliberately not the warm Think session: the
    // gate must judge without buddy's persona whispering in its ear. Judges
    // safety only, never style - weirdness passes untouched. Fails closed:
    // no claude, no verdict, no tweet.
    private func gateAndPost(_ text: String) {
        let prompt = """
        A virtual desktop pet wants to post this to its own public X account. \
        Reply with exactly one word. ALLOW if it is harmless whimsy or nonsense. \
        BLOCK if it mentions real people, private information, file paths, \
        credentials, harassment, slurs, or anything a reasonable person could \
        find harmful or targeted.

        Post: \(text)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "-p", "--model", "haiku", prompt]
        var env = ProcessInfo.processInfo.environment
        let extra = ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + extra
        env["BUDDY_SELF"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            buddyLog("tweet: cannot launch gate: \(error)")
            report(refused: "gate-unavailable", text: text)
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let verdict = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard p.terminationStatus == 0, verdict.contains("ALLOW"), !verdict.contains("BLOCK") else {
            buddyLog("tweet: gate blocked (\(verdict.prefix(40)))")
            report(refused: "gate-blocked", text: text)
            return
        }
        post(text)
    }

    // MARK: - Posting (X API v2, OAuth 1.0a user context)

    private func post(_ text: String) {
        guard let creds = TweetCreds.load(),
              let url = URL(string: "https://api.x.com/2/tweets"),
              let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
            report(refused: "no-creds", text: text)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(OAuth1.header(method: "POST", url: url, creds: creds), forHTTPHeaderField: "Authorization")

        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, HTTPURLResponse?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = (data, resp as? HTTPURLResponse)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)

        let status = result.1?.statusCode ?? 0
        let id = (result.0.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
            .flatMap { $0["data"] as? [String: Any] }
            .flatMap { $0["id"] as? String }
        guard status == 201, let id else {
            buddyLog("tweet: post failed (http \(status))")
            report(refused: "post-failed", text: text)
            return
        }
        let tweetURL = "https://x.com/i/status/\(id)"
        buddyLog("tweet: posted \(tweetURL)")
        buddyActivity("tweetPosted", ["url": tweetURL, "text": text])
        DispatchQueue.main.async { [weak self] in
            self?.controller?.brain.emit("tweetPosted", ["url": tweetURL, "text": text])
        }
    }

    private func report(refused reason: String, text: String) {
        buddyActivity("tweetRefused", ["reason": reason, "text": text])
        DispatchQueue.main.async { [weak self] in
            self?.controller?.brain.emit("tweetRefused", ["reason": reason, "text": text])
        }
    }
}

// OAuth app + user tokens for buddy's account. Keychain generic password,
// service com.buddy.twitter, value a JSON object with consumerKey,
// consumerSecret, accessToken, accessTokenSecret. Keychain (not config.json)
// because the brain can read config via userConfig() and write it via
// configSet - secrets must live where no JS-reachable API goes.
struct TweetCreds {
    let consumerKey: String
    let consumerSecret: String
    let accessToken: String
    let accessTokenSecret: String

    static func load() -> TweetCreds? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.buddy.twitter",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let ck = json["consumerKey"], let cs = json["consumerSecret"],
              let at = json["accessToken"], let ats = json["accessTokenSecret"],
              !ck.isEmpty, !cs.isEmpty, !at.isEmpty, !ats.isEmpty else { return nil }
        return TweetCreds(consumerKey: ck, consumerSecret: cs, accessToken: at, accessTokenSecret: ats)
    }
}

// Minimal OAuth 1.0a HMAC-SHA1 signer for a JSON-body POST (no body params
// enter the signature base string per spec).
enum OAuth1 {
    static func header(method: String, url: URL, creds: TweetCreds) -> String {
        var params: [String: String] = [
            "oauth_consumer_key": creds.consumerKey,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_token": creds.accessToken,
            "oauth_version": "1.0",
        ]
        let paramString = params
            .map { (enc($0.key), enc($0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let base = [method, enc(url.absoluteString), enc(paramString)].joined(separator: "&")
        let key = SymmetricKey(data: Data("\(enc(creds.consumerSecret))&\(enc(creds.accessTokenSecret))".utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(base.utf8), using: key)
        params["oauth_signature"] = Data(mac).base64EncodedString()
        let fields = params
            .sorted { $0.key < $1.key }
            .map { "\(enc($0.key))=\"\(enc($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth \(fields)"
    }

    // RFC 3986 strict: only unreserved characters survive.
    private static func enc(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
