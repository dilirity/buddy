# Buddy shell API contract

The `buddy.*` surface every shell (mac today, Android next) exposes to the
brain JS. Extracted from `macos/Sources/Buddy/Brain.swift` (the authority -
if this doc and the code disagree, the code wins and this doc gets fixed).

Rules of the contract:

- The brain is plain JS files loaded in filename order; a shell runs them in a
  sandboxed JS context (JavaScriptCore on mac; QuickJS or
  androidx.javascriptengine on Android).
- A shell implements EVERY verb below. Verbs whose underlying sense/actuator
  the platform lacks (e.g. `cursor.warp` on Android) exist but no-op and
  return their failure value; events the platform cannot sense are simply
  never emitted. Brain files must keep working unchanged either way.
- Bad JS logs and skips; it must never crash the shell.

## Events

`buddy.on(name, fn)`, `buddy.once(name, fn)`, `buddy.emit(name, payload = {})`.
Handlers receive one payload object. `once` handlers are dropped before the
call, so re-registering inside the handler works.

### Emitted by the mac shell

| event | payload | source |
|---|---|---|
| `brainLoaded` | `{}` | after every (re)load |
| `brainDamaged` | `{errors}` | load finished with JS errors |
| `brainChanged` | `{}` | brain dir edited outside an evolution |
| `chat` | `{text}` | The human typed in the talk box |
| `phoneChat` | `{text}` | The human texted from the phone (ntfy inbox) |
| `arrived` | `{}` | moveTo/approach reached its target |
| `caught` | `{}` | chase reached the cursor |
| `poked` | `{}` | click on buddy |
| `dragStart` | `{}` | The human picked buddy up |
| `dragEnd` | `{x, y}` | The human dropped buddy |
| `unfrozen` | `{}` | freeze ended |
| `idle` | `{seconds}` | The human went idle |
| `active` | `{}` | The human came back |
| `typing` | `{keys}` | keystroke burst (needs input-monitoring permission) |
| `appChanged` | `{name}` | frontmost app switched |
| `configChanged` | `{trait, from, to}` | The human edited traits.json by hand |
| `claude:<name>` | hook event JSON | Claude Code hook events via `~/.buddy/events.jsonl` (`_event` field becomes `<name>`) |
| `evolveStart` / `evolveEnd` | `{}` / `{changed}` | mutator run began/finished |
| `testMode` | `{on}` | menu toggle, lifts rate limits for 1h |
| `test:<id>` | `{}` | menu-triggered test (ids from `tests.json`) |

## Verbs

### Speech and looks

- `buddy.say(text, secs, prop?)` - speech bubble. `secs <= 0` defaults to 4.
  Optional prop name is worn for the line.
- `buddy.play(anim)` - switch animation (names from sprites.json).
- `buddy.prop(name | null)` - don/remove an accessory from sprites.json props.
- `buddy.opacity(v)` - 0..1.
- `buddy.layer(mode)` - `"behind"` drops below windows; anything else restores.

### Movement and position

- `buddy.moveTo(x, y, speed)` - walk to a point; `speed <= 0` defaults 120.
  Emits `arrived`.
- `buddy.stop()` - halt movement.
- `buddy.chase(speed)` - chase the cursor (default 250). Emits `caught`.
- `buddy.approach(speed, dx, dy)` - live cursor-relative move (default 200).
  Emits `arrived`. Use instead of `moveTo(cursor snapshot)`.
- `buddy.isMoving()` -> bool
- `buddy.pos()` -> `{x, y}` sprite origin.
- `buddy.screen()` -> `{x, y, w, h}` usable screen frame.
- `buddy.isHeld()` -> bool (mid-drag).
- `buddy.isFrozen()` -> bool (panic/freeze active).

### Cursor (mac-flavored; no-op elsewhere)

- `buddy.cursor.pos()` -> `{x, y}`
- `buddy.cursor.warp(x, y)` -> bool
- `buddy.cursor.grab(secs)` -> bool (default 3; rate-limited natively)

### Windows

- `buddy.windows()` -> array of `{app, title?, x, y, w, h}`-shaped dicts for
  normal on-screen windows (own window excluded, tiny windows filtered).

### Phone (ntfy)

- `buddy.phone(text)` -> bool. Push to the human's phone. Natively rate-limited:
  10-minute minimum gap AND the disruption budget. False = not sent.
- `buddy.phoneReply(text)` -> bool. Reply channel for `phoneChat` events only;
  light 15s rate limit.

### Music (whitelisted verbs, Spotify or Apple Music)

- `buddy.music.play(playlist?)` -> bool
- `buddy.music.pause()`
- `buddy.music.next()` -> bool
- `buddy.music.status(cb)` - async, cb receives a status object.

### Personality and memory

- `buddy.traits.get(name)` -> number (0.5 if unknown)
- `buddy.traits.all()` -> `{name: value}`
- `buddy.traits.set(name, value)` -> bool - clamped to the trait's min/max
  bounds; for acting on the human's chat requests. Bounds stay human-only.
- `buddy.memory.get(key)` / `buddy.memory.set(key, value)` - persisted JSON
  key-value (`~/.buddy/memory.json`). `set(key, null)` deletes.
- `buddy.data(name)` - read-only JSON loader, restricted to `*.json` directly
  inside the brain dir. Returns null on any violation.
- `buddy.feedback(text)` - append-only line into brain `feedback.md`,
  committed to the brain repo immediately. Deliberately not a general write.

### Thinking

- `buddy.think(prompt, cb)` - runs `claude -p --model haiku` with persona.md
  prepended, 60s timeout, one at a time. cb gets the reply string or null.
  In-flight callbacks are dropped on brain reload.

### Timers and misc

- `buddy.after(ms, fn)` -> id (min 50ms)
- `buddy.every(ms, fn)` -> id
- `buddy.cancel(id)`
- `buddy.log(msg)` - to the shell log.

## Platform notes

- Android v1 no-ops: `cursor.*` (false/zero), `windows()` (empty array),
  `music.*` (false), `chase`/`approach` (no cursor - no-op, never emit).
- Android-only senses arrive as new events following the same pattern
  (charging, screenOn, notification) - mac simply never emits them.
- Coordination (travel, epochs, replication) is NOT part of this surface yet;
  the shell decides how state moves. The brain gets a travel verb when the
  coordination layer lands, documented here when real.

## buddy.caps()

Returns `{capability: Bool}` describing what is REAL on this device (vs stubbed): `cursor`, `windows`, `layer`, `music`, `think`, `phonePush`, `feedback`, `claudeEvents`. Shells must implement the full verb surface regardless - unsupported verbs are graceful no-ops returning their failure value, never throwing. The brain gates behaviors with `can(cap)` from 00-core (older shells without caps() are treated as all-capable).
