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

    private let queue = DispatchQueue(label: "buddy.coord")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: NWEndpoint] = [:]
    private var connections: [NWConnection] = []
    private let stateURL: URL

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
            self.peers = found
            buddyLog("coord: peers \(Array(found.keys))")
        }
        b.start(queue: queue)
        browser = b
        buddyLog("coord: up as \(deviceId) rank \(rank) epoch \(epoch) owner \(ownsBuddy)")
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
            // Buddy incoming: adopt the proposed epoch, ack, own it.
            epoch = fEpoch
            ownsBuddy = true
            persist()
            send(["type": "travel-ack", "epoch": epoch], on: conn)
            let payload = frame["payload"] as? [String: Any] ?? [:]
            buddyLog("coord: travel in, epoch \(epoch)")
            DispatchQueue.main.async { self.onArrive?(payload) }

        case "claim":
            // Someone else legitimately owns buddy now.
            if fEpoch > epoch || (fEpoch == epoch && !ownsBuddy) {
                epoch = fEpoch
                if ownsBuddy {
                    ownsBuddy = false
                    persist()
                    DispatchQueue.main.async { self.onDepart?() }
                }
                persist()
            }

        default:
            break
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
            self.send(["type": "travel", "epoch": proposed, "payload": payload], on: conn)
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
