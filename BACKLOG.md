# buddy backlog (engineering - needs shell/native work)

## Act outcomes / state machine
- Movement steps need explicit success/failure: approach timeout currently emits plain `arrived`, so acts celebrate beside nothing (clingy heart with no cursor nearby). Add outcome payload (`{timedOut: true}`) or a distinct `approachFail` event; runAct branches on it; behaviors get sad-path reactions ("i walked all this way and you LEFT").
- Anti-repetition: the same behavior can fire repeatedly in a row when its trait is high. The act scheduler should own recency - a behavior that just ran gets deprioritized regardless of dice. (Also noted to the mutator in feedback.md as a brain-side interim.)
- Behaviors still occasionally overlap. Current discipline is voluntary (`state.busy` + guards). Consider a real act scheduler in core: one act at a time, priority levels (chat > acts > ambient), queued or dropped - native-enforced like the evolve lockdown.

## Hide and seek
- Hiding drops below ALL windows (window level semantics). Real per-window hiding: order the panel below a specific window via `NSWindow.order(.below, relativeTo: windowNumber)` with a CGWindowID from `buddy.windows()`. Verb: `buddy.layer("behind", windowId?)`.

## Settings
- Settings window has no explanations - add a short description per trait (what it gates, examples), plus show derived stats (grudges, chat count) read-only so personality state is visible.
- Mutator-added traits appear automatically (window is dynamic) - verify bounds validation when mutator starts adding them.

## Toys
- Play behavior: a toy entity (ball?) - second small panel with simple physics buddy can chase, carry, drop near the cursor. New native object + verbs (`buddy.toy.drop(x, y)`, events `toyCaught`). Design so the mutator can invent games with it.

## Misc
- Eye tracking: if data-driven directional look frames (mutator's job) feel too coarse, add a native pupil overlay layer that offsets toward the cursor continuously.
- Chat: dedicated "think" animation slot (brain-side once sprites.json has one - shell needs nothing).
- Repetition: pickFresh covers lines; behaviors themselves repeat - mutator mandate covers, watch if it needs mechanical help (per-behavior cooldowns in core).

## Brain sync (mac -> phone, live)
- Mutator edits only reach the phone at APK rebuild (assets snapshot). Ship brain files over the coordination link instead: on travel or on brain change, owner pushes changed .js/.json to peers; phone hot-reloads like the mac does. Then evolution reaches both bodies the same night.

## Android companion (the expedition)
- Real buddy-on-phone: Android overlay app ("draw over other apps"), renders the same sprites.json pixel maps, subscribes to the ntfy topic for arrive/return commands and publishes phone-side events (pokes) back. Presence handoff: buddy exists on ONE device at a time - Mac hides it while abroad, phone walks it in. Mini-brain on the phone (idle/wander/poke/lines); personality, evolution, memory stay on the Mac; trip reports on return. Separate repo, Kotlin, days of work - the current ghost-at-the-edge travel act is the placeholder fiction until then.

## Distribution (if buddy ever ships to other folks)
- Connectivity: LAN-first with automatic relay fallback (outbound WebSocket, ntfy-style - already proven by phone chat working on isolated hotel wifi). E2E-encrypt payloads with the per-install secret; relay carries ciphertext. No user setup, no Tailscale ask.
- The bigger blocker: buddy's brain runs on the owner's claude CLI auth. Rollout = bring-your-own-Claude (developers only) or a paid inference backend (consumer). Economics decision, not engineering.
- Also implied: signed/notarized app bundles (no more TCC re-grant dance), real Nothing API key for glyphs, onboarding that hides every file we currently hand-edit.
