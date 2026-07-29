# Buddy multi-device plan (Android + coordination)

Handoff doc from the initial design discussion (2026-07-29). This captures the idea and every decision made so far. Nothing below is implemented yet - the mac app is untouched, and no Android code exists.

## The idea

Buddy stops being a mac-only pet and becomes one creature that lives across Pete's devices (mac + Nothing Phone 2 for now, more later). The brain fiction already supports this: `brain/80-phone.js` has buddy "traveling" to the phone via a fire-and-forget ntfy push. The Android app makes the trip real: buddy fades out on the mac and actually appears on the phone as an overlay sprite, with its mood, memory, and current intent intact.

Believability is the bar. That means: exactly one buddy, never two; state (mood, grudges, quip freshness, intent journal) travels with it; failed trips revert in-fiction ("trip cancelled"); a dead device never kills or duplicates buddy - it pops up on another device remembering what it was doing.

## Decisions made

### 1. No dedicated server. Roaming coordinator.

The device buddy is currently on IS the coordinator. It holds canonical state and pushes updates to the other devices. When buddy travels, the target device becomes the coordinator. Coordinator = owner = buddy's location; one token, no separate lease.

### 2. Transport: LAN only for v1

All devices on the same wifi. Discovery via mDNS/Bonjour (`_buddy._tcp`): NSNetService on mac, NSD on Android. No peer config files, no IPs, no public server. Android's NSD is historically flaky (missed announcements, stale results), so peers also cache last-known IP:port and try those directly when discovery is silent; ntfy poke is a further fallback to wake a peer that isn't announcing. The network layer is deliberately swappable - Tailscale (or similar mesh) later gives any-network reachability with the same protocol on top. Reachability beyond LAN is explicitly deferred.

ntfy stays in the stack as the Android wake channel: when Android kills the app's service (it will, sometimes), a peer can send an ntfy push to get it restarted and rejoined. Also keeps the existing "buddy texts your phone" feature working before/without the Android app running.

### 3. Liveness: mesh-wide heartbeats

Every device heartbeats to every other device (UDP ping every few seconds - trivial at 2-4 devices). NOT hub-and-spoke through the coordinator: the coordinator's liveness knowledge dies with it, and the survivors are exactly the ones who need fresh info to elect. "Alive" means the buddy app is running on that device.

Core rule: sleep is an announced death, not a failure. Devices know their own sleep in advance (mac: `NSWorkspace.willSleepNotification`; Android: screen-off / doze-entry broadcasts), so an owner about to sleep proactively travels buddy to a live peer using the normal travel handshake ("lid closes, buddy scurries to the phone"). No live peer: persist snapshot, buddy sleeps with the device. This makes elections a backstop for genuine crashes only (power loss, app kill), which means failure timeouts can be lazy (~60s, not seconds) - killing most false-election risk, including Android Doze making an idle phone look dead while buddy is still on its screen.

The case handoff does not cover: the phone leaving wifi with buddy on it. No sleep event fires - it just vanishes from LAN mid-life, and that's normal daily life, not a failure. Policy: when the unreachable owner is the phone, survivors do NOT elect; buddy is out with Pete ("buddy is away" - fiction, not resurrection). On return, normal replication resumes. Election on owner loss applies only to non-phone owners.

### 4. Election: static rank

Elections are the crash backstop, not the normal path - sleep handoff (section 3) handles announced deaths. Devices have a fixed rank order (mac = 1, phone = 2, ...). When the coordinator dies without warning (heartbeats stop past the lazy timeout, and the missing owner is not the phone - see section 3), each survivor checks its local liveness table: "is anyone alive ranked above me?" If no, claim coordinatorship with epoch+1 and announce. If yes, wait briefly for their claim, then next in line. Deterministic, no negotiation round, no presence scoring.

Equal-epoch tiebreak: two paths can mint the same epoch number (e.g. a partitioned survivor electing to N+1 while the departed owner also moved to N+1). On conflict, equal epoch = lower rank wins. Must be pinned in the protocol doc or split-brain merge is undefined.

### 5. Epochs everywhere (the correctness core)

A single monotonic generation counter. Every coordinatorship claim, every travel, every state write carries the epoch. Stale-epoch writes are rejected. This kills the zombie-mac bug (mac wakes from sleep, thinks it still owns buddy, tries to overwrite the phone's newer state) and resolves split-brain: on partition heal, higher epoch wins, the lower-epoch buddy despawns silently and its state is discarded. Rare double-buddy moments are an accepted cost of having no server.

### 6. Replication: event-framed, full-snapshot payload for v1

Every state change is broadcast to all peers as an event `{epoch, seq, op, payload}`. Owner assigns seq, monotonic within an epoch; followers apply in order, atomically. Replication happens on every event, not on a timer.

v1 pragmatism: the payload is the FULL state snapshot (buddy's soul is a few KB - on LAN a delta and a snapshot cost the same packet). This eliminates gap-replay/resync machinery: latest wins. The event framing (epoch, seq, op name) is kept so the payload can switch to deltas later without changing anything above it. New epoch (election or travel) starts at seq 0 with a full snapshot baseline.

Because everything is replicated on every event, any survivor can resume buddy after a crash losing at most the last moments, including the intent journal ("what buddy was doing").

### 7. Travel handshake

1. Owner -> target, direct: "incoming" + full state + epoch+1.
2. Target ACKs, renders walk-in animation, announces "I own, epoch N" to all peers.
3. Origin despawns buddy fully.
4. No ACK within ~10s: origin keeps its epoch, plays the trip-cancelled line (fiction already exists in 80-phone.js).

Lost-ACK edge: target may have claimed epoch+1 while the origin timed out and kept buddy - two buddies until the target's ownership announce reaches the origin, then the epoch rule despawns the stale one. Known and covered, not luck.

Crash arrival (election winner) is the same, minus the handshake: spawn with emergency-arrival fiction, resume the replicated intent journal.

Coordination layer stays dumb plumbing. The BRAIN decides when to travel (peers can send presence hints like "phone screen just came on"; the personality acts on them, the protocol never auto-moves buddy).

### 8. Auth: hard-coded shared secret

Every frame carries a shared secret (a silly hard-coded password); peers reject frames without it. Keeps a random device on the wifi from claiming epoch 999 and killing buddy. Deliberately dumb - upgrade path (proper HMAC, key exchange) only if ever needed.

### 9. Cold start (no devices were running)

Every device persists its last-known snapshot + epoch. First device to start waits a short grace period for peers, then claims with the highest epoch it knows and wakes buddy. Simultaneous starts are covered by the rank rule.

Known blip, accepted: a device that was off while buddy lived elsewhere can win cold start with stale state (mac off since epoch 5, buddy last on phone at epoch 10 - mac boots first, wakes buddy with old memory; when the phone joins, its higher epoch wins and the stale buddy despawns). Self-healing via the epoch rule, no new machinery. To shrink the window: generous grace period, plus an ntfy poke on startup ("anyone holding buddy?") before claiming.

### 10. Same brain, literally

Not a port. The same JS brain files execute on both platforms. Android runs them via QuickJS or androidx.javascriptengine. Both shells implement an identical documented API surface (`buddy.on/say/play/screen/traits/after/phone/...` - extract the real contract from `macos/Sources/Buddy/Brain.swift` + `Think.swift`). Platform-specific brain files follow the existing pattern (80-phone.js): the shell simply never emits events it cannot sense. Same sprites.json, same renderer semantics, same pixel aesthetic.

Runtime brain stays separate from repo brain (already true today: repo `brain/` is the seed, live brain is `~/.buddy/brain` with its own git repo the mutator commits to). The mutator keeps running on the mac only and evolves the one shared brain; replicating the live brain to other devices rides the same replication channel (later work, structure supports it).

### 11. Android app shape

- Kotlin, foreground service + `TYPE_APPLICATION_OVERLAY` floating sprite (chat-heads style). Draggable, pokeable, walks screen edges. Live wallpaper/widget rejected for v1.
- Canvas renderer reading the same sprites.json.
- Brain runtime as above.
- Survival hardening: foreground service, battery-optimization exemption prompt, boot receiver, ntfy wake channel. This is where most pet apps die; treat it as a first-class feature.
- Phone-native behavior, not mac behavior emulated: tighter disruption budget, perch on edges, react to notifications (NotificationListenerService), comment on unlock/charging. Same personality, different body.
- Nothing Phone 2 special: Glyph Developer Kit integration (back LEDs) - buddy blinks when it has something to say, breathes while sleeping, talks via lights when the phone is face-down. Planned for v1.1, not v1.
- Invariants model mirrors the mac: on-device invariants.json, disruption budget (matters MORE on a phone).

### 12. Monorepo

`~/projects/buddy` becomes the monorepo. No separate repos: protocol changes must be atomic across both apps, the brain is shared, and the mutator evolves one brain for all bodies. There is no server component to house. Target layout:

```
buddy/
  protocol/
    coordination.md      # epochs, rank, heartbeats, travel, oplog framing, cold start
    shell-api.md         # the buddy.* contract both shells implement
    schemas/             # JSON schemas: state blob, events, sprites.json format
  brain/                 # seed brain (shared JS + sprites.json + persona.md)
  macos/                 # Package.swift, Sources/, bin/, install.sh move here
  android/               # Gradle project, Kotlin
  mutator/               # stays top-level
```

`~/projects/buddy-android` is an empty leftover folder - delete it.

## State blob (sketch, to be schema'd)

mood, energy, grudge list, quip freshness/recently-used, traits snapshot, intent journal (current act + queued intents), epoch + seq. A few KB total.

## Work order

1. Restructure commit: move mac app into `macos/`, fix install.sh/README paths, verify `swift build`. Mechanical, do first while the repo is small.
2. `protocol/coordination.md` - write the protocol doc pinning down: discovery, heartbeat/failure detection, rank election, epoch rules, event/oplog framing, travel handshake, split-brain merge, cold start, and edge cases (double travel requests, mid-travel death, clock skew irrelevance).
3. `protocol/shell-api.md` - extract the actual brain API from the mac sources.
4. Mac side: implement the coordination layer (mDNS announce/browse, heartbeats, epochs, event broadcast, travel). Testable with two processes on localhost / a curl-driven fake peer BEFORE any Android exists. Also: `buddy.phone()` stays as-is (ntfy) until real travel replaces the fake trip in 80-phone.js.
5. Android v1: overlay + sprite renderer + brain runtime + coordination client + 2-3 senses (charging, screen on/off, notifications). Joins an already-working protocol.
6. v1.1: Glyph, brain live-replication, more senses.

## Open questions (not yet decided)

- Wire format/transport details on LAN: TCP vs WebSocket between peers, JSON framing - decide in the protocol doc.
- Exact state blob schema - write while doing the shell API contract, since the brain defines what state exists.
- How the phone gets brain updates in v1 (bundle seed brain in APK + manual sync vs replicate from day one).
- Grace period lengths, heartbeat intervals, timeout values - pin in the protocol doc, tune later.
- `buddy.phone()` fiction when buddy already lives on the phone (buddy texting itself) - skip, or invert to texting the mac.
- "Buddy is away" while the phone is off-LAN: does the mac show anything (small hint, empty desk), and what happens if the mac user pokes for buddy?
- What counts as "sleep" on the phone: raw screen-off would ping-pong buddy to the mac on every lock. Hand off on doze entry or after N idle minutes - pick threshold in the protocol doc.
