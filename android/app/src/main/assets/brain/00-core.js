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

globalThis.setMood = function (mood, anim) {
  state.mood = mood;
  if (anim) buddy.play(anim);
};

// Dialogue pools live in lines.json so the nightly mutator can add lines
// without touching code.
globalThis.lines = (key) => {
  const l = buddy.data("lines.json");
  const pool = l && l[key];
  return pool && pool.length ? pickFresh(pool) : null;
};

globalThis.sayLine = (key, secs, prop) => {
  const t = lines(key);
  if (t) buddy.say(t, secs || 4, prop || null);
};

// Stage sequencer: every multi-step act should run through this instead of
// hand-rolled timer chains. Steps run in order; each step may have:
//   anim: "name"                      play an animation
//   line: "poolKey" / say: "text"     speak (secs, prop ride along)
//   prop: "name"                      worn via the spoken line, or bare
//   moveTo: {x, y, speed}             walk somewhere (fixed point)
//   approach: {speed, dx, dy}         walk to the LIVE cursor + offset
//   chase: speed                      pursue and catch the live cursor
//   ms: 800                           how long the step lasts (default 800)
//   until: "event" | ["e1","e2"]      instead of ms, wait for an event
//   until: {event: [steps...]}        branch: run that path, then finish
// state.busy is held for the whole act so ambient behaviors yield.
globalThis.runAct = function (steps, done) {
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
    // An act finishing must not release the busy claim the evolve ritual holds.
    state.busy = state.evolving === true;
    if (done) done();
  }
  function next() {
    clearBareProp();
    i++;
    if (i >= steps.length) return finish();
    const s = steps[i];
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
      events.forEach((ev) => buddy.once(ev, () => {
        if (fired) return;
        fired = true;
        if (branch) runAct(s.until[ev], done);
        else next();
      }));
      // Stuck-safety: events can get swallowed (drag, freeze, reload).
      buddy.after(s.timeout || 12000, () => {
        if (fired) return;
        fired = true;
        finish();
      });
    } else {
      buddy.after(s.ms || 800, next);
    }
  }
  state.busy = true;
  next();
};

buddy.on("brainDamaged", (e) => {
  buddy.say("ow. part of my brain did not load. check buddy.log", 6);
});

buddy.on("unfrozen", () => {
  sayLine("unfrozen", 4);
});
