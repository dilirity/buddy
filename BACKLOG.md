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
