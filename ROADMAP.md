# Buddy Roadmap

Project history, distilled from session chats and git log. Used for demos and catch-ups.

<!-- update-tracking: do not remove.
     To update: read everything AFTER these markers, then append new phases.
     last-updated: 2026-07-29 15:40
     last-commit: 06b4057
     Sources: `git log 1e9d4cd..HEAD` for new commits, and session transcripts in
     ~/.claude/projects/-Users-ppetrov-projects-buddy/*.jsonl with mtime newer than
     last-updated (extract user messages via jq for narrative context).
     After updating, bump both markers. -->

## Phase 1: Idea (Jul 28, afternoon)
- Pitch: Clippy-like desktop pet for Claude Code. Pixel art, lives above all windows, watches your chats, plays with cursor, annoys you, has moods.
- Key twist from day one: background agent that evolves buddy daily so its behavior stays surprising even to its owner.
- Decisions locked early: native macOS (fast, light), pixel art sprite, everything local, disruptive-but-controllable via trait settings.

## Phase 2: Mac v1 (Jul 28, ~17:40-22:45)
- `buddy v1: native shell, JS brain, evolution mechanism` - core architecture: thin native shell, JavaScript brain, mutator that rewrites brain via Claude.
- Personality features: cursor heist with real-time chase, clingy mode with hearts, TV-show references with props (glasses for facts, cowboy hats, martinis), staged animations (prepare / loop / end), pick-up-and-drop animation.
- Evolution hardening: lockfile, "surgery lockdown" (buddy refuses movement while evolving), buddy's own Claude sessions tagged so hooks ignore them, evolutions committed to git.
- QoL: app bundle for Raycast/Spotlight, login autostart, single instance, menus don't freeze buddy, chat with thinking indicator, music verbs.

## Phase 3: Buddy learns to take feedback (Jul 29, morning)
- Chat intent triage: talk to buddy, it files feedback notes and edits its own traits (`traits.set`).
- Trait law: "no flat chances" - randomness stays alive.
- Backlog seeded: the android companion expedition.

## Phase 4: Multi-device (Jul 29, ~11:45-13:15)
- Wrote MULTI-DEVICE spec together: buddy is singular, "travels" between devices on same LAN. Device sleeps with buddy on it = buddy sleeps. Leaves wifi = stays. No cloud, no VPS - LAN only, mDNS/NSD discovery.
- Protocol doc: epochs, liveness, heartbeats, travel handshake, leader election with rank tiebreak.
- Android app: overlay sprite, QuickJS brain runtime with full shell API, senses, boot receiver.
- Real coordination: travel both ways, ntfy as wake channel (mac pokes phone on failed travel, `buddy://` link revives service), mac actuators gated while buddy is away.
- Parity push: settings on android (trait sliders, disruption leash), phone menu parity, event-driven trait replication both directions, follower edits route to owner and echo back.

## Phase 5: Two bodies, one buddy - polish and honesty (Jul 29, ~13:20-15:20)
- Device-aware brain: no-crash contract and `caps()` across shells - the brain asks its body what it can do, so phone buddy never tries to steal a cursor (that used to crash the app).
- Continuity breaks done right: framework-level cap enforcement in `runAct`, shell-owned presentation reset on travel, act-owned motion stops cleanly when buddy leaves a device.
- Chat UX unification: single ntfy topic, phone chat and double-click mac chat share the same logic, device roster in the mac menu, "call buddy here" flow, mac controls gated like android's when buddy is away.
- Nothing Phone glyph lights: arrival flash when buddy lands on the phone, plus a `buddy.glyph` verb the brain (and future evolutions) can use.
- Speed: prewarmed think sessions recycled after every chat, dedicated interactive think lane so ambient thoughts don't block replies, streaming phone inbox, chat latency telemetry to prove it.
- Behavioral telemetry: `activity.jsonl` plus a report tool - can now show what buddy actually did all day.
- Act scheduler replaced racing ambient timers; carry mode reworked so the sprite layer moves while the window never drags (defeats window tilers).
- Buddy now git-commits its own feedback notes; evolution mutator is aware of travel and the second body.
- Side quest: phone screen mirroring on the mac with a start/stop CLI command, for demoing the android buddy.

## Demo talking points
- One buddy, two bodies: same JS brain runs on mac (native shell) and android (QuickJS). Brain travels; devices are just vessels.
- Self-modifying: evolution mechanism rewrites its own brain via Claude, git-committed, with safety locks so you can't corrupt it mid-surgery.
- Feedback loop: chat with it, it files its own backlog and tweaks its own traits.
- Honest engineering bits: crash election, staleness catch-up for missed evolutions, ntfy fallback when android kills the service.
- Hardware flourish: Nothing Phone glyph lights flash when buddy arrives.
- Numbers: ~67 commits in under 24 hours, zero to cross-device pet with telemetry.

War stories: buddy got stuck mid-evolution when we edited it during evolve (hence the lockfile), it once walked off screen while talking, and one session where the phone build almost became a web page against spec.
