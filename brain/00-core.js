// Buddy brain core. Files load in filename order; this one first.
// Coordinates are Cocoa: origin at bottom-left. buddy.screen() = visible frame {x,y,w,h}.
globalThis.state = { mood: "happy", busy: false };

globalThis.pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
globalThis.chance = (p) => Math.random() < p;

// pick, but avoids the last few lines actually said - buddy repeating itself
// verbatim breaks the illusion of it being alive.
globalThis._recentSays = [];
globalThis.pickFresh = (arr) => {
  for (let i = 0; i < 6; i++) {
    const c = pick(arr);
    if (!_recentSays.includes(c)) {
      _recentSays.push(c);
      if (_recentSays.length > 8) _recentSays.shift();
      return c;
    }
  }
  return pick(arr);
};

// Device capability check - shells report what is real on this device
// (buddy.caps()); missing caps() means an older shell: assume everything.
globalThis.can = (k) => {
  if (!buddy.caps) return true;
  const m = buddy.caps();
  return !m || m[k] !== false;
};

// Listener names are recorded so the self-check can prove every advertised
// test id actually has a handler - buddy.on goes straight into the shell,
// which offers no way to enumerate registrations.
globalThis._listeners = {};
(function () {
  const _on = buddy.on;
  const _once = buddy.once;
  buddy.on = (ev, fn) => { _listeners[ev] = true; _on(ev, fn); };
  buddy.once = (ev, fn) => { _listeners[ev] = true; _once(ev, fn); };
})();

globalThis.setMood = function (mood, anim) {
  state.mood = mood;
  if (anim) buddy.play(anim);
};

// Real-world facts about the human: config-schema.json (here, mutator-owned)
// declares { default, type: hour|date|weekday|number|text|bool, label }; the
// human's chosen values live in ~/.buddy/config.json (via buddy.userConfig()),
// OUTSIDE the brain repo so a failed-evolution revert can never touch them.
// The settings UI renders editors straight from the schema. Read at call time,
// not cached - edits apply on the next evaluation. Behaviors tied to a
// real-world fact should name a schema entry instead of hard-coding it.
globalThis.cfg = (name, fallback) => {
  const vals = (buddy.userConfig && buddy.userConfig()) || {};
  if (vals[name] !== undefined && vals[name] !== null) return vals[name];
  const s = buddy.data("config-schema.json");
  const e = s && s[name];
  return e && e.default !== undefined && e.default !== null ? e.default : fallback;
};

// What buddy calls its human. Declared in config (onboarding/settings);
// memory fallback covers installs that predate the config store. "boss"
// until told otherwise.
globalThis.userName = function () {
  return cfg("name", "") || buddy.memory.get("userName") || "boss";
};

// Dialogue pools live in lines.json so the nightly mutator can add lines
// without touching code.
globalThis.lines = (key) => {
  const l = buddy.data("lines.json");
  const pool = l && l[key];
  if (!pool || !pool.length) return null;
  // {name} in any pool resolves to the configured name - never bake a real
  // name into dialogue data.
  return pickFresh(pool).replace(/\{name\}/g, userName());
};

globalThis.sayLine = (key, secs, prop) => {
  const t = lines(key);
  if (t) buddy.say(t, secs || 4, prop || null);
};

// ---- Act lifecycle ----
// Any behavior that takes the stage runs inside an act context. The context
// owns the shared-state boundary - the busy claim, cleanup, one exit, and
// interrupt delivery - and says nothing about the body: write any imperative
// code, from a three-line skit to a long interactive game.
//   act.after(ms, fn) / act.every(ms, fn)  timers that die with the act
//   act.on(ev, fn) / act.once(ev, fn)      listeners inert after the act ends
//   act.done(outcome)                      the one exit; outcome is free-form
//                                          ("cuddled", "missed", "timeout"...)
//   onInterrupt(act, reason) in the spec   called when something bigger takes
//                                          the stage (reason: drag|evolve|chat)
//                                          BEFORE the context closes - react
//                                          in-fiction (sulk), save arc state.
globalThis._activeAct = null;

globalThis.beginAct = function (name, spec) {
  const ctx = {
    name: name,
    live: true,
    _timers: [],
    _spec: spec || {},
    after(ms, fn) {
      const id = buddy.after(ms, () => { if (ctx.live) fn(); });
      ctx._timers.push(id);
      return id;
    },
    every(ms, fn) {
      const id = buddy.every(ms, () => { if (ctx.live) fn(); });
      ctx._timers.push(id);
      return id;
    },
    // The shell has no off(); guards keep dead acts' handlers inert, and the
    // nightly reload sweeps them. Prefer once() for completion events.
    on(ev, fn) { buddy.on(ev, (e) => { if (ctx.live) fn(e); }); },
    once(ev, fn) { buddy.once(ev, (e) => { if (ctx.live) fn(e); }); },
    done(outcome) { endAct(ctx, outcome || "done"); },
  };
  _activeAct = ctx;
  state.busy = true;
  return ctx;
};

function endAct(ctx, outcome) {
  if (!ctx.live) return;
  ctx.live = false;
  ctx._timers.forEach((id) => buddy.cancel(id));
  if (_activeAct === ctx) _activeAct = null;
  // An act finishing must not release the busy claim the evolve ritual holds.
  state.busy = state.evolving === true;
  buddy.log("act " + ctx.name + ": " + outcome);
}

// Something bigger took the stage. The act hears about it (onInterrupt) and
// then its context closes - timers die, so no blind half-act keeps ticking.
globalThis.interruptAct = function (reason) {
  const ctx = _activeAct;
  if (!ctx || !ctx.live) return;
  const oi = ctx._spec.onInterrupt;
  if (oi) {
    try { oi(ctx, reason); } catch (e) { buddy.log("onInterrupt error: " + e); }
  }
  endAct(ctx, "interrupted:" + reason);
};

buddy.on("dragStart", () => interruptAct("drag"));
buddy.on("evolveStart", () => interruptAct("evolve"));

// Stage sequencer, built ON the act context: the convenient shape for staged
// skits. Steps run in order; each step may have:
//   anim: "name"                      play an animation
//   line: "poolKey" / say: "text"     speak (secs, prop ride along)
//   prop: "name"                      worn via the spoken line, or bare
//   moveTo: {x, y, speed}             walk somewhere
//   approach: {speed, dx, dy}         walk to the LIVE cursor + offset
//   chase: speed                      pursue and catch the live cursor
//   layer: "behind" | "front"         drop under / restore over app windows
//   opacity: 0.15..1                  ghost mode (shell auto-restores to 1)
//   ms: 800                           how long the step lasts (default 800)
//   until: "event" | ["e1","e2"]      instead of ms, wait for an event
//   until: {event: [steps...]}        branch: run that path, then finish
// Runs inside the current act context when one is live (an act body calling
// runAct), else opens its own - busy is held either way, and an interrupt
// kills the chain instead of letting it tick blind.
globalThis.runAct = function (steps, done) {
  const ctx = _activeAct && _activeAct.live ? _activeAct : beginAct("seq");
  let i = -1;
  let bareProp = false;
  function clearBareProp() {
    if (bareProp) {
      buddy.prop(null);
      bareProp = false;
    }
  }
  function finish() {
    clearBareProp();
    ctx.done();
    if (done) done();
  }
  function next() {
    if (!ctx.live) return clearBareProp();
    clearBareProp();
    i++;
    if (i >= steps.length) return finish();
    const s = steps[i];
    if (s.layer) buddy.layer(s.layer);
    if (s.opacity != null) buddy.opacity(s.opacity);
    if (s.anim) buddy.play(s.anim);
    if (s.line) sayLine(s.line, s.secs, s.prop);
    else if (s.say) buddy.say(s.say, s.secs || 4, s.prop || null);
    else if (s.prop) {
      // Prop without a line: worn for this step only.
      buddy.prop(s.prop);
      bareProp = true;
    }
    // A step needing a capability this device lacks aborts the act cleanly -
    // CAPS LAW enforced at the framework level, no miming verbs that cannot run.
    if ((s.chase || s.approach) && !can("cursor")) {
      buddy.log("act aborted: step needs cursor");
      buddy.play("idle");
      return finish();
    }
    if (s.chase) buddy.chase(s.chase);
    if (s.approach) buddy.approach(s.approach.speed || 200, s.approach.dx || 0, s.approach.dy || 0);
    if (s.moveTo) buddy.moveTo(s.moveTo.x, s.moveTo.y, s.moveTo.speed || 160);
    if (s.until) {
      let fired = false;
      const branch = !Array.isArray(s.until) && typeof s.until === "object";
      const events = branch ? Object.keys(s.until) : [].concat(s.until);
      events.forEach((ev) => ctx.once(ev, () => {
        if (fired) return;
        fired = true;
        if (branch) runAct(s.until[ev], done);
        else next();
      }));
      // Stuck-safety: events can get swallowed (freeze, reload).
      ctx.after(s.timeout || 12000, () => {
        if (fired) return;
        fired = true;
        finish();
      });
    } else {
      ctx.after(s.ms || 800, next);
    }
  }
  next();
};

buddy.on("brainDamaged", (e) => {
  buddy.say("ow. part of my brain did not load. check buddy.log", 6);
});

buddy.on("unfrozen", () => {
  sayLine("unfrozen", 4);
});


// ---- The act scheduler ----
// Ambient behaviors REGISTER here instead of racing independent timers for
// state.busy - the loudest timer used to starve everyone else (clingy at 20s
// drowned out chatter and mischief). One ticker picks fairly: trait-weighted,
// per-act cooldowns, and never the same act twice in a row.
globalThis._acts = {};
// Spec may set ambient: true for behaviors that only make sense self-initiated
// (never on command); everything else must also appear in tests.json, so the
// human - and chat - can invoke it. `Buddy --check` enforces the pairing.
globalThis.registerAct = function (name, spec) {
  _acts[name] = Object.assign({ lastRun: 0 }, spec);
};

// What buddy can DO on command, for chat: tests.json minus the entries this
// device cannot perform (an entry's caps array lists required device caps).
globalThis.chatAbilities = function () {
  const tests = buddy.data("tests.json") || [];
  return tests.filter((t) => !t.caps || t.caps.every(can));
};

// Registry sync audit, run by `Buddy --check`: every advertised ability must
// have a handler, every scheduled act must be advertised (or opt out with
// ambient: true). Keeps chat's picture of buddy's abilities from drifting.
globalThis.brainSelfCheck = function () {
  const errs = [];
  const tests = buddy.data("tests.json") || [];
  const ids = {};
  tests.forEach((t) => {
    ids[t.id] = true;
    if (!_listeners["test:" + t.id]) errs.push("tests.json id '" + t.id + "' has no test:" + t.id + " handler");
  });
  for (const name in _acts) {
    if (!_acts[name].ambient && !ids[name]) errs.push("act '" + name + "' missing from tests.json (add an entry or mark it ambient: true)");
  }
  return errs;
};

// The one way an act actually starts (scheduler and test menu both come
// through here). New-style bodies declare run(act) and get a live context;
// legacy zero-arg bodies manage busy themselves (usually via runAct).
globalThis.runRegisteredAct = function (name) {
  const a = _acts[name];
  if (!a) return;
  if (a.run.length >= 1) {
    const ctx = beginAct(name, a);
    try {
      a.run(ctx);
    } catch (e) {
      buddy.log("act " + name + " error: " + e);
      ctx.done("error");
    }
  } else {
    a.run();
  }
};

buddy.every(15000, () => {
  if (state.busy || state.evolving || buddy.isFrozen() || buddy.isHeld()) return;
  if (buddy.isMoving() || state.mood === "sleepy") return;
  const now = Date.now();
  const last = buddy.memory.get("lastAct") || "";
  const eligible = [];
  for (const name in _acts) {
    const a = _acts[name];
    if (a.caps && !a.caps.every(can)) continue;
    if (now - a.lastRun < (a.minGap || 120000)) continue;
    if (name === last && Object.keys(_acts).length > 1) continue;
    const w = a.weight ? a.weight() : 0.5;
    if (w > 0) eligible.push([name, w]);
  }
  if (!eligible.length) return;
  const total = eligible.reduce((s, e) => s + e[1], 0);
  // Global pacing: even with everything maxed, roughly one act a minute.
  if (!chance(Math.min(0.4, total * 0.1))) return;
  let r = Math.random() * total;
  for (const [name, w] of eligible) {
    r -= w;
    if (r <= 0) {
      _acts[name].lastRun = now;
      buddy.memory.set("lastAct", name);
      runRegisteredAct(name);
      return;
    }
  }
});
