// Idle life: sleeping, clinging, chatter, and rare cursor mischief.
buddy.on("idle", () => {
  if (state.busy) return;
  setMood("sleepy", "sleep");
});

buddy.on("active", () => {
  if (state.busy) return;
  setMood("happy", "idle");
  if (chance(0.4)) sayLine("wake", 3);
});

// Clingy: staged visit - walk over, deliver a heart, settle down.
buddy.every(20000, () => {
  if (!can("cursor")) return;
  if (buddy.isHeld() || buddy.isFrozen() || state.mood === "sleepy") return;
  if (buddy.isMoving() || state.busy) return;
  if (!chance(buddy.traits.get("clinginess") * 0.4)) return;
  // Vary the arrival: heart only, line only, or the full production.
  const roll = Math.random();
  const arrive =
    roll < 0.4 ? { anim: "excited", prop: "heart", ms: 2600 }
    : roll < 0.7 ? { anim: "excited", line: "clingyArrive", secs: 3, ms: 2600 }
    : { anim: "excited", line: "clingyArrive", secs: 3, prop: "heart", ms: 2600 };
  // Pick the side with room; coin flip only when both fit.
  const c = buddy.cursor.pos();
  const s = buddy.screen();
  const side = c.x > s.x + s.w - 160 ? -70 : c.x < s.x + 160 ? 70 : chance(0.5) ? 70 : -70;
  runAct([
    { anim: "walk", approach: { speed: 160, dx: side, dy: 0 }, until: "arrived" },
    arrive,
    { anim: "idle" },
  ]);
});

// Mischief: cursor nudges and full heists. Native invariants rate-limit both.
let stealing = false;

buddy.every(120000, () => {
  if (!can("cursor")) return;
  if (buddy.isHeld() || buddy.isFrozen() || state.mood === "sleepy") return;
  if (buddy.isMoving() || state.busy) return;
  if (!chance(buddy.traits.get("mischief") * 0.25)) return;
  if (chance(0.5)) {
    const c = buddy.cursor.pos();
    const ok = buddy.cursor.warp(c.x + (Math.random() * 120 - 60), c.y + (Math.random() * 120 - 60));
    if (ok) {
      buddy.play("scheming");
      if (chance(0.5)) buddy.say("hehe", 2);
      buddy.after(2000, () => buddy.play("idle"));
    }
  } else {
    // The heist, staged: prepare (scheme, announce), then lunge at the live cursor.
    stealing = true;
    state.busy = true;
    buddy.play("scheming");
    if (chance(0.6)) sayLine("chaseStart", 2);
    buddy.after(900, () => {
      if (!stealing) return;
      buddy.play("walk");
      buddy.chase(280);
    });
    // Safety: never leave busy stuck if the chase gets cancelled mid-flight.
    buddy.after(15000, () => {
      if (stealing) { stealing = false; state.busy = false; }
    });
  }
});

buddy.on("gaveUp", () => {
  if (!stealing) return;
  stealing = false;
  state.busy = false;
  sayLine("gaveUp", 4);
  buddy.play("idle");
});

buddy.on("caught", () => {
  if (!stealing) return;
  stealing = false;
  state.busy = false;
  if (!buddy.cursor.grab(4)) return;
  buddy.play("scheming");
  sayLine("heist", 3);
  const s = buddy.screen();
  buddy.moveTo(s.x + 40 + Math.random() * (s.w - 160), s.y + 40 + Math.random() * (s.h - 240), 300);
  buddy.after(4200, () => {
    buddy.play("excited");
    buddy.say("hehehe", 2);
    buddy.after(2000, () => buddy.play("idle"));
  });
});

// Idle chatter.
buddy.every(60000, () => {
  if (buddy.isFrozen() || state.mood === "sleepy") return;
  const c = buddy.traits.get("chattiness");
  if (!chance(c * 0.2)) return;
  if (chance(buddy.traits.get("weirdness") * 0.5)) {
    buddy.think("Say one short weird non-sequitur a tiny pixel goblin might say.", (t) => {
      if (t) buddy.say(t, 4);
    });
  } else {
    sayLine("chatter", 4);
  }
});

buddy.on("appChanged", (e) => {
  if (chance(0.1 * buddy.traits.get("chattiness"))) {
    const t = lines("appSwitch");
    buddy.say(chance(0.5) || !t ? "ooh " + e.name : t, 3);
  }
});

buddy.on("typing", () => {
  if (chance(0.08 * buddy.traits.get("chattiness"))) sayLine("typing", 3);
});
