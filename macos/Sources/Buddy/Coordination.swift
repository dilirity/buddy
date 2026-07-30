import Foundation
import Network

// LAN coordination per protocol/coordination.md: mDNS discovery, JSON-lines
// TCP frames, epochs, travel handshake. v1 scope: discovery + travel both
// directions. Heartbeats/election deliberately not wired yet - travel is
// announced, and the mac never resurrects a buddy that left (away rule).
final class Coordination {
    static let secret = "buddy-doorknob"
    static let serviceType = "_buddy._tcp"
    static let port: UInt16 = 47800

    let deviceId: String
    let rank: Int
    private(set) var epoch: Int
    private(set) var ownsBuddy: Bool

    // Called on main. arrived: buddy travels IN (payload = state blob).
    // departed: our travel was acked, buddy left.
    var onArrive: (([String: Any]) -> Void)?
    var onDepart: (() -> Void)?
    // Every replicated state snapshot from the current owner (traits sync).
    var onSnapshot: (([String: Any]) -> Void)?
    // A follower asked to change a trait while we own buddy.
    var onTraitSet: ((String, Double) -> Void)?

    private let queue = DispatchQueue(label: "buddy.coord")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: NWEndpoint] = [:]
    // Main-thread mirror of peer names, for UI (menu) reads.
    private(set) var knownPeers: [String] = []
    private var peerHosts: [String: String] = [:]
    private var connections: [NWConnection] = []
    private let stateURL: URL
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSocket: NWListener?
    // Snapshot provider set by the controller - called on main, returns the
    // replicable state blob (traits etc). Broadcast to followers.
    var snapshot: (() -> [String: Any])?

    init(deviceId: String, rank: Int, owner: Bool, listenPort: UInt16 = Coordination.port) {
        self.deviceId = deviceId
        self.rank = rank
        self.ownsBuddy = owner
        self.stateURL = BuddyPaths.home.appendingPathComponent("coordination-\(deviceId).json")
        // Persisted state wins over the default: a mac that restarts after
        // buddy traveled away must not wake up thinking it still owns buddy.
        var e = 0
        var own = owner
        if let data = try? Data(contentsOf: stateURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            e = (json["epoch"] as? NSNumber)?.intValue ?? 0
            own = (json["owner"] as? Bool) ?? owner
        }
        self.epoch = e
        self.ownsBuddy = own
        start(listenPort: listenPort)
    }

    private func persist() {
        let json: [String: Any] = ["epoch": epoch, "owner": ownsBuddy]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: stateURL)
        }
    }

    // MARK: - Listen + discover

    private func start(listenPort: UInt16) {
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: listenPort)!) else {
            buddyLog("coord: cannot listen on \(listenPort)")
            return
        }
        l.service = NWListener.Service(name: deviceId, type: Coordination.serviceType)
        l.newConnectionHandler = { [weak self] conn in
            self?.adopt(conn)
        }
        l.start(queue: queue)
        listener = l

        let b = NWBrowser(for: .bonjour(type: Coordination.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, name != self.deviceId {
                    found[name] = r.endpoint
                }
            }
            let fresh = Set(found.keys).subtracting(self.peers.keys)
            self.peers = found
            // Deliberately NOT pruning peerHosts on browse loss: cached IPs
            // are the fallback for exactly when discovery goes blind.
            buddyLog("coord: peers \(Array(found.keys))")
            let names = Array(found.keys).sorted()
            DispatchQueue.main.async { self.knownPeers = names }
            for name in fresh { self.hello(name) }
        }
        b.start(queue: queue)
        browser = b

        startHeartbeats(listenPort: listenPort)
        buddyLog("coord: up as \(deviceId) rank \(rank) epoch \(epoch) owner \(ownsBuddy)")
    }

    // MARK: - Heartbeats + replication

    // UDP heartbeats to every peer every 3s (mesh, per coordination.md).
    // The mac takes NO action on peer silence: the phone going quiet means
    // "buddy is out with Pete", never death. Owner also piggybacks a state
    // snapshot broadcast every 10th beat so followers can resume after a crash.
    private func startHeartbeats(listenPort: UInt16) {
        let hbPort = listenPort + 1
        if let l = try? NWListener(using: .udp, on: NWEndpoint.Port(rawValue: hbPort)!) {
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                conn.receiveMessage { data, _, _, _ in
                    // Liveness intake only; nothing acts on it on the mac.
                    _ = data
                    conn.cancel()
                }
            }
            l.start(queue: queue)
            heartbeatSocket = l
        }
        var beat = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            beat += 1
            for (_, host) in self.peerHosts {
                let conn = NWConnection(host: NWEndpoint.Host(host),
                                        port: NWEndpoint.Port(rawValue: hbPort)!,
                                        using: .udp)
                conn.start(queue: self.queue)
                var f: [String: Any] = ["type": "heartbeat", "epoch": self.epoch,
                                        "owner": self.ownsBuddy]
                f["v"] = 1
                f["s"] = Coordination.secret
                f["from"] = self.deviceId
                if let data = try? JSONSerialization.data(withJSONObject: f) {
                    conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            if beat % 10 == 0, self.ownsBuddy {
                self.broadcastState()
            }
        }
        t.resume()
        heartbeatTimer = t
    }

    // Full-snapshot state event to every peer (v1 replication: latest wins).
    // Owner-only: a follower pushing state would fight the owner's copy.
    func broadcastState() {
        DispatchQueue.main.async {
            guard self.ownsBuddy else { return }
            let payload = self.snapshot?() ?? [:]
            self.queue.async {
                for (_, endpoint) in self.peers {
                    let conn = NWConnection(to: endpoint, using: .tcp)
                    conn.start(queue: self.queue)
                    self.send(["type": "state", "epoch": self.epoch, "seq": 0,
                               "op": "snapshot", "owner": self.ownsBuddy,
                               "payload": payload], on: conn)
                    self.queue.asyncAfter(deadline: .now() + 2) { conn.cancel() }
                }
            }
        }
    }

    // Ask the current owner to change a trait (we are a follower). The
    // owner's broadcast echoes the clamped result back.
    func sendTraitSet(name: String, value: Double) {
        queue.async {
            guard !self.ownsBuddy, let (_, endpoint) = self.peers.first else { return }
            let conn = NWConnection(to: endpoint, using: .tcp)
            conn.start(queue: self.queue)
            self.send(["type": "traitSet", "epoch": self.epoch,
                       "name": name, "value": value], on: conn)
            self.queue.asyncAfter(deadline: .now() + 2) { conn.cancel() }
        }
    }

    // On meeting a peer: exchange hellos so a stale device learns the current
    // epoch before doing anything (cold-start grace + zombie correction).
    private func hello(_ name: String) {
        guard let endpoint = peers[name] else { return }
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            // Remember the peer's raw IP: heartbeats are UDP to host:hbPort,
            // and cached IPs double as the discovery fallback.
            if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                self.peerHosts[name] = "\(host)".components(separatedBy: "%").first ?? "\(host)"
            }
        }
        adoptForFrames(conn)
        conn.start(queue: queue)
        send(["type": "hello", "epoch": epoch], on: conn)
    }

    private func adoptForFrames(_ conn: NWConnection) {
        connections.append(conn)
        receiveLines(conn, buffer: Data())
    }

    private func adopt(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        receiveLines(conn, buffer: Data())
    }

    private func receiveLines(_ conn: NWConnection, buffer: Data) {
        var buf = buffer
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { buf.append(data) }
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                if let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    self.handle(frame, on: conn)
                }
            }
            if done || err != nil {
                self.connections.removeAll { $0 === conn }
                conn.cancel()
            } else {
                self.receiveLines(conn, buffer: buf)
            }
        }
    }

    private func send(_ frame: [String: Any], on conn: NWConnection) {
        var f = frame
        f["v"] = 1
        f["s"] = Coordination.secret
        f["from"] = deviceId
        guard var data = try? JSONSerialization.data(withJSONObject: f) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Frames

    private func handle(_ frame: [String: Any], on conn: NWConnection) {
        guard frame["s"] as? String == Coordination.secret else { return }
        let fEpoch = (frame["epoch"] as? NSNumber)?.intValue ?? -1
        let type = frame["type"] as? String ?? ""

        // Stale-epoch rule (hello exempt: it's how stale peers learn).
        if type != "hello", fEpoch < epoch { return }

        switch type {
        case "hello":
            send(["type": "state", "epoch": epoch, "seq": 0,
                  "op": "snapshot", "owner": ownsBuddy], on: conn)

        case "travel":
            // Refuse deliveries addressed to someone else - a stale-cached IP
            // once looped a travel back to its sender (the self-delivery bug).
            if let to = frame["to"] as? String, to != deviceId {
                buddyLog("coord: travel misdelivery (to \(to)), refused")
                return
            }
            // Buddy incoming: adopt the proposed epoch, ack, own it.
            epoch = fEpoch
            ownsBuddy = true
            persist()
            send(["type": "travel-ack", "epoch": epoch], on: conn)
            let payload = frame["payload"] as? [String: Any] ?? [:]
            buddyLog("coord: travel in, epoch \(epoch)")
            DispatchQueue.main.async { self.onArrive?(payload) }

        case "traitSet":
            if ownsBuddy, let name = frame["name"] as? String,
               let value = (frame["value"] as? NSNumber)?.doubleValue {
                DispatchQueue.main.async { self.onTraitSet?(name, value) }
            }

        case "claim", "state":
            if type == "state", let payload = frame["payload"] as? [String: Any],
               frame["owner"] as? Bool == true, !ownsBuddy {
                DispatchQueue.main.async { self.onSnapshot?(payload) }
            }
            // Someone else claims/reports ownership. Higher epoch wins;
            // equal epoch resolves by rank (lower rank wins) - the split-brain
            // tiebreak from coordination.md.
            let theirRank = Coordination.rank(of: frame["from"] as? String ?? "")
            let theyOwn = (frame["owner"] as? Bool) ?? (type == "claim")
            guard theyOwn else { break }
            let theyWin = fEpoch > epoch || (fEpoch == epoch && theirRank < rank)
            if theyWin {
                epoch = fEpoch
                if ownsBuddy {
                    ownsBuddy = false
                    buddyLog("coord: ceding ownership to \(frame["from"] ?? "?") epoch \(fEpoch)")
                    DispatchQueue.main.async { self.onDepart?() }
                }
                persist()
            }

        default:
            break
        }
    }

    static func rank(of deviceId: String) -> Int {
        switch deviceId {
        case "mac": return 1
        case "phone": return 2
        default: return 9
        }
    }

    // MARK: - Travel out

    var hasPeer: Bool { !peers.isEmpty }

    // Best-effort travel to the first discovered peer. completion(main): true
    // if the target acked and buddy is gone from here.
    func travel(payload: [String: Any], completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.ownsBuddy, let (_, endpoint) = self.peers.first else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let proposed = self.epoch + 1
            let conn = NWConnection(to: endpoint, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { ok in
                guard !finished else { return }
                finished = true
                if ok {
                    self.epoch = proposed
                    self.ownsBuddy = false
                    self.persist()
                    buddyLog("coord: travel out acked, epoch \(proposed)")
                    DispatchQueue.main.async { self.onDepart?() }
                } else {
                    conn.cancel()
                    buddyLog("coord: travel out failed/timeout")
                }
                DispatchQueue.main.async { completion(ok) }
            }
            self.adoptForAck(conn, expecting: proposed, finish: finish)
            conn.start(queue: self.queue)
            let target = self.peers.first?.0 ?? "phone"
            self.send(["type": "travel", "epoch": proposed, "to": target,
                       "payload": payload], on: conn)
            self.queue.asyncAfter(deadline: .now() + 10) { finish(false) }
        }
    }

    private func adoptForAck(_ conn: NWConnection, expecting: Int, finish: @escaping (Bool) -> Void) {
        connections.append(conn)
        func loop(_ buffer: Data) {
            var buf = buffer
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buf.append(data) }
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    if let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       frame["s"] as? String == Coordination.secret,
                       frame["type"] as? String == "travel-ack",
                       (frame["epoch"] as? NSNumber)?.intValue == expecting {
                        finish(true)
                        return
                    }
                }
                if done || err != nil {
                    self.connections.removeAll { $0 === conn }
                } else {
                    loop(buf)
                }
            }
        }
        loop(Data())
    }
}
