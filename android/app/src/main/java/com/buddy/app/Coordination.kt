package com.buddy.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

// Android side of protocol/coordination.md. v1 scope mirrors the mac:
// mDNS announce/browse (NSD), JSON-lines TCP, epochs, travel both ways.
class Coordination(context: Context, private val onUi: Handler = Handler(Looper.getMainLooper())) {
    companion object {
        const val SECRET = "buddy-doorknob"
        const val SERVICE_TYPE = "_buddy._tcp."
        const val PORT = 47800
        const val HB_PORT = 47801
        const val SILENCE_MS = 15_000L
        const val TAG = "BuddyCoord"

        fun rankOf(deviceId: String): Int = when (deviceId) {
            "mac" -> 1
            "phone" -> 2
            else -> 9
        }
    }

    private val prefs = context.getSharedPreferences("coordination", Context.MODE_PRIVATE)
    var epoch: Int
        get() = prefs.getInt("epoch", 0)
        private set(v) { prefs.edit().putInt("epoch", v).apply() }
    var ownsBuddy: Boolean
        get() = prefs.getBoolean("owner", false)
        private set(v) { prefs.edit().putBoolean("owner", v).apply() }

    var onArrive: ((JSONObject) -> Unit)? = null
    var onDepart: (() -> Unit)? = null
    // Crash election: the mac (the only non-phone peer) owned buddy and went
    // silent past the timeout. Payload = last replicated snapshot.
    var onEmergencyClaim: ((JSONObject) -> Unit)? = null
    // Every replicated state snapshot from the owner (traits sync etc).
    var onSnapshot: ((JSONObject) -> Unit)? = null

    private val appContext = context
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var server: ServerSocket? = null
    @Volatile private var peerHost: String? = null
    @Volatile private var peerPort: Int = 0
    @Volatile private var running = true

    // Liveness (mesh heartbeats per coordination.md)
    @Volatile private var macLastSeen = 0L
    @Volatile private var macOwns = false
    @Volatile private var macEpoch = 0
    private var lastSnapshot: JSONObject
        get() = try { JSONObject(prefs.getString("snapshot", "{}") ?: "{}") } catch (e: Exception) { JSONObject() }
        set(v) { prefs.edit().putString("snapshot", v.toString()).apply() }

    fun start() {
        server = ServerSocket(PORT)
        Thread {
            while (running) {
                try {
                    val sock = server?.accept() ?: break
                    Thread { serve(sock) }.start()
                } catch (e: Exception) {
                    if (running) Log.w(TAG, "accept: $e")
                }
            }
        }.start()

        val info = NsdServiceInfo().apply {
            serviceName = "phone"
            serviceType = SERVICE_TYPE
            port = PORT
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "registered ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, e: Int) { Log.w(TAG, "register failed $e") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, e: Int) {}
        })

        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.DiscoveryListener {
            override fun onServiceFound(s: NsdServiceInfo) {
                if (s.serviceName == "phone") return
                nsd.resolveService(s, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(r: NsdServiceInfo) {
                        peerHost = r.host?.hostAddress
                        peerPort = r.port
                        Log.i(TAG, "peer ${r.serviceName} at $peerHost:$peerPort")
                    }
                    override fun onResolveFailed(i: NsdServiceInfo, e: Int) { Log.w(TAG, "resolve failed $e") }
                })
            }
            override fun onServiceLost(s: NsdServiceInfo) { if (s.serviceName != "phone") peerHost = null }
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, e: Int) { Log.w(TAG, "discovery failed $e") }
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
        })

        startHeartbeats()
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
        try { hbSocket?.close() } catch (_: Exception) {}
    }

    // MARK: - Heartbeats + crash election

    private var hbSocket: java.net.DatagramSocket? = null

    private fun startHeartbeats() {
        // Listener: track the mac's liveness and whether it owns buddy.
        Thread {
            try {
                val sock = java.net.DatagramSocket(HB_PORT)
                hbSocket = sock
                val buf = ByteArray(4096)
                while (running) {
                    val packet = java.net.DatagramPacket(buf, buf.size)
                    sock.receive(packet)
                    val frame = try {
                        JSONObject(String(packet.data, 0, packet.length))
                    } catch (e: Exception) { continue }
                    if (frame.optString("s") != SECRET) continue
                    if (frame.optString("from") == "phone") continue
                    macLastSeen = System.currentTimeMillis()
                    macOwns = frame.optBoolean("owner", false)
                    macEpoch = frame.optInt("epoch", 0)
                }
            } catch (e: Exception) {
                if (running) Log.w(TAG, "hb listen: $e")
            }
        }.start()

        // Sender + election watchdog every 3s.
        Thread {
            while (running) {
                try { Thread.sleep(3000) } catch (e: Exception) { break }
                peerHost?.let { host ->
                    try {
                        val frame = JSONObject()
                            .put("v", 1).put("s", SECRET).put("from", "phone")
                            .put("type", "heartbeat").put("epoch", epoch)
                            .put("owner", ownsBuddy)
                        val bytes = frame.toString().toByteArray()
                        java.net.DatagramSocket().use {
                            it.send(java.net.DatagramPacket(bytes, bytes.size,
                                java.net.InetAddress.getByName(host), HB_PORT))
                        }
                    } catch (e: Exception) { Log.w(TAG, "hb send: $e") }
                }
                checkElection()
            }
        }.start()
    }

    // The phone is rank 2 and the mac is rank 1: an election here happens
    // only when the mac owned buddy and crashed (silence past timeout while
    // on the LAN). The phone going silent never triggers anything anywhere -
    // that is the "buddy is out with Pete" rule, enforced on the mac side by
    // taking no action on silence at all.
    private fun checkElection() {
        if (ownsBuddy) return
        if (!macOwns) return
        if (macLastSeen == 0L) return
        if (System.currentTimeMillis() - macLastSeen < SILENCE_MS) return
        val claimed = maxOf(epoch, macEpoch) + 1
        epoch = claimed
        ownsBuddy = true
        macOwns = false
        Log.i(TAG, "emergency claim, epoch $claimed (mac silent)")
        val snapshot = lastSnapshot
        onUi.post { onEmergencyClaim?.invoke(snapshot) }
    }

    val hasPeer: Boolean get() = peerHost != null

    private fun serve(sock: Socket) {
        try {
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            while (true) {
                val line = reader.readLine() ?: break
                val frame = try { JSONObject(line) } catch (e: Exception) { continue }
                if (frame.optString("s") != SECRET) continue
                val fEpoch = frame.optInt("epoch", -1)
                val type = frame.optString("type")
                if (type != "hello" && fEpoch < epoch) continue

                when (type) {
                    "hello" -> send(sock, JSONObject()
                        .put("type", "state").put("epoch", epoch)
                        .put("seq", 0).put("op", "snapshot").put("owner", ownsBuddy))
                    "travel" -> {
                        epoch = fEpoch
                        ownsBuddy = true
                        send(sock, JSONObject().put("type", "travel-ack").put("epoch", epoch))
                        val payload = frame.optJSONObject("payload") ?: JSONObject()
                        Log.i(TAG, "travel in, epoch $epoch")
                        onUi.post { onArrive?.invoke(payload) }
                    }
                    "claim", "state" -> {
                        if (type == "state") {
                            frame.optJSONObject("payload")?.let {
                                lastSnapshot = it
                                onUi.post { onSnapshot?.invoke(it) }
                            }
                        }
                        val theyOwn = if (type == "claim") true else frame.optBoolean("owner", false)
                        val theirRank = rankOf(frame.optString("from"))
                        val theyWin = fEpoch > epoch || (fEpoch == epoch && theirRank < rankOf("phone"))
                        if (theyOwn && theyWin) {
                            epoch = fEpoch
                            if (ownsBuddy) {
                                ownsBuddy = false
                                Log.i(TAG, "ceding ownership to ${frame.optString("from")} epoch $fEpoch")
                                onUi.post { onDepart?.invoke() }
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "serve: $e")
        } finally {
            try { sock.close() } catch (_: Exception) {}
        }
    }

    private fun send(sock: Socket, frame: JSONObject) {
        frame.put("v", 1).put("s", SECRET).put("from", "phone")
        sock.getOutputStream().write((frame.toString() + "\n").toByteArray())
        sock.getOutputStream().flush()
    }

    // Full-snapshot state event to the peer (spec: replication on every state
    // change). Owner-only, same rule as the mac side.
    fun broadcastState(payload: JSONObject) {
        val host = peerHost ?: return
        val port = peerPort
        if (!ownsBuddy) return
        Thread {
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress(host, port), 5000)
                send(sock, JSONObject().put("type", "state").put("epoch", epoch)
                    .put("seq", 0).put("op", "snapshot").put("owner", true)
                    .put("payload", payload))
                sock.close()
            } catch (e: Exception) {
                Log.w(TAG, "state broadcast: $e")
            }
        }.start()
    }

    // Travel buddy back to the discovered peer. completion on main thread.
    fun travel(payload: JSONObject, completion: (Boolean) -> Unit) {
        val host = peerHost
        val port = peerPort
        if (!ownsBuddy || host == null) {
            onUi.post { completion(false) }
            return
        }
        Thread {
            var ok = false
            val proposed = epoch + 1
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress(host, port), 5000)
                sock.soTimeout = 10000
                send(sock, JSONObject().put("type", "travel").put("epoch", proposed)
                    .put("payload", payload))
                val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
                while (true) {
                    val line = reader.readLine() ?: break
                    val frame = try { JSONObject(line) } catch (e: Exception) { continue }
                    if (frame.optString("s") == SECRET &&
                        frame.optString("type") == "travel-ack" &&
                        frame.optInt("epoch") == proposed) {
                        ok = true
                        break
                    }
                }
                sock.close()
            } catch (e: Exception) {
                Log.w(TAG, "travel out: $e")
            }
            if (ok) {
                epoch = proposed
                ownsBuddy = false
                Log.i(TAG, "travel out acked, epoch $proposed")
                onUi.post { onDepart?.invoke() }
            }
            onUi.post { completion(ok) }
        }.start()
    }
}
