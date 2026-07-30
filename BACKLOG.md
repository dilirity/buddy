# buddy backlog (engineering - needs shell/native work)

## Act outcomes / state machine
- Mostly done brain-side: acts run in a scoped context (00-core `beginAct`) with `done(outcome)`, `onInterrupt(reason)`, and scheduler-owned recency/fairness. Remaining native half: movement verbs still emit plain `arrived` on timeout - a `{timedOut: true}` payload (or distinct event) would let acts drop the hand-rolled distance checks (see clingy).
- Freeze is invisible to the brain: no event fires when the human panics mid-act, so a frozen act ends by janitor (safety timers), not by `onInterrupt("freeze")`. Shell could emit `frozen` like it emits `unfrozen`.
- Five pre-scheduler behaviors (wander, hideseek, boo, critic, portal) still run private timers; the mutator's orders say convert on touch.

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

## Distribution (early-version gaps, noted 2026-07-30; none block friendly handouts)
- Wizard-lite done: the interview now hands off to Settings > System on save, so the consent switches are no longer undiscoverable. A true sequential walk of the rows (DISTRIBUTION.md WS2) remains unbuilt; judge whether the handoff is enough after a real stranger install.
- Test menu shows `visitPhone` on mac-only installs - buddy fakes a phone trip to a topic nobody subscribes to. Gate menu entries on caps, or make the act admit it has no phone.
- Setup panel gaps vs spec (WS3): no `ANTHROPIC_API_KEY` detection (per-token billing warning), no cheap validation call when a model is picked (typo fails silently later).
- Android APK bakes the BUILDER's live brain (build.gradle copies ~/.buddy/brain at build time) - diary and feedback included. Never share a personally-built APK; recipients build their own. Real fix is brain sync (below) or a neutral seed asset.
- Android re-key UX: phone reads the pairing secret from prefs now, but nothing writes it yet - pairs still ride the legacy literal until a pairing flow exists (mac side has the same note in setup.sh).

## Brain sync (mac -> phone, live)
- Mutator edits only reach the phone at APK rebuild (assets snapshot). Ship brain files over the coordination link instead: on travel or on brain change, owner pushes changed .js/.json to peers; phone hot-reloads like the mac does. Then evolution reaches both bodies the same night.
- Declared facts too: the phone has userConfig/configSet (local config.json) but nothing fills it - buddy calls the human "boss" on the phone until config values replicate like traits do in the ownership snapshot.

## Android companion (the expedition)
- Real buddy-on-phone: Android overlay app ("draw over other apps"), renders the same sprites.json pixel maps, subscribes to the ntfy topic for arrive/return commands and publishes phone-side events (pokes) back. Presence handoff: buddy exists on ONE device at a time - Mac hides it while abroad, phone walks it in. Mini-brain on the phone (idle/wander/poke/lines); personality, evolution, memory stay on the Mac; trip reports on return. Separate repo, Kotlin, days of work - the current ghost-at-the-edge travel act is the placeholder fiction until then.
