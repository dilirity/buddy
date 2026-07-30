// Idle life: sleeping, visits, mischief, chatter - all as registered acts so
// the scheduler keeps them fair. No behavior owns a timer; the scheduler owns
// the tempo.
buddy.on("idle", () => {
  if (state.busy) return;
  setMood("sleepy", "sleep");
});

buddy.on("active", () => {
  if (state.busy) return;
  setMood("happy", "idle");
  if (chance(0.4)) sayLine("wake", 3);
});

// Clingy: visit the cursor, celebrate the cuddle or sulk the miss. New-style
// act: run(act) with a real outcome, and an in-fiction interrupt reaction.
registerAct("clingy", {
  minGap: 120000,
  caps: ["cursor"],
  weight: () => buddy.traits.get("clinginess") * 0.8,
  run: (act) => {
    const c = buddy.cursor.pos();
    const s = buddy.screen();
    const side = c.x > s.x + s.w - 160 ? -70 : c.x < s.x + 160 ? 70 : chance(0.5) ? 70 : -70;
    buddy.play("walk");
    buddy.approach(160, side, 0);
    act.once("arrived", () => {
      // "arrived" also fires when the walk deadline lapsed - only celebrate
      // the cuddle if buddy actually made it next to the cursor.
      const p = buddy.pos();
      const m = buddy.cursor.pos();
      if (Math.hypot(p.x - m.x, p.y - m.y) < 180) {
        buddy.play("excited");
        sayLine("clingyArrive", 3, chance(0.6) ? "heart" : null);
        act.after(2600, () => { buddy.play("idle"); act.done("cuddled"); });
      } else {
        buddy.play("idle");
        sayLine("clingyMiss", 3);
        act.after(2600, () => act.done("missed"));
      }
    });
    // The shell resolves approach within 10s; this is the belt to its braces.
    act.after(15000, () => { buddy.play("idle"); act.done("timeout"); });
  },
  onInterrupt: (act, reason) => {
    // Scooped up mid-visit: close enough to a cuddle, honestly.
    if (reason === "drag") sayLine("clingyArrive", 3, "heart");
  },
});

// Mischief: cursor nudges and full heists. Native invariants rate-limit both.
let stealing = false;

registerAct("mischief", {
  minGap: 300000,
  caps: ["cursor"],
  weight: () => buddy.traits.get("mischief") * 0.7,
  run: () => {
    if (chance(0.5)) {
      const c = buddy.cursor.pos();
      const ok = buddy.cursor.warp(c.x + (Math.random() * 120 - 60), c.y + (Math.random() * 120 - 60));
      if (ok) {
        buddy.play("scheming");
        if (chance(0.5)) buddy.say("hehe", 2);
        buddy.after(2000, () => buddy.play("idle"));
      }
      return;
    }
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
      if (stealing) { stealing = false; state.busy = state.evolving === true; }
    });
  },
});

buddy.on("gaveUp", () => {
  if (!stealing) return;
  stealing = false;
  state.busy = state.evolving === true;
  sayLine("gaveUp", 4);
  buddy.play("idle");
});

buddy.on("caught", () => {
  if (!stealing) return;
  stealing = false;
  state.busy = state.evolving === true;
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
registerAct("chatter", {
  minGap: 150000,
  weight: () => buddy.traits.get("chattiness") * 0.6,
  run: () => {
    if (can("think") && chance(buddy.traits.get("weirdness") * 0.5)) {
      buddy.think("Say one short weird non-sequitur a tiny pixel goblin might say.", (t) => {
        if (t) buddy.say(t, 4);
      });
    } else {
      sayLine("chatter", 4);
    }
  },
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
