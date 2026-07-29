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
        const val TAG = "BuddyCoord"
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

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var server: ServerSocket? = null
    @Volatile private var peerHost: String? = null
    @Volatile private var peerPort: Int = 0
    @Volatile private var running = true

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
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
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
                    "claim" -> {
                        if (fEpoch > epoch) {
                            epoch = fEpoch
                            if (ownsBuddy) {
                                ownsBuddy = false
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
