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
registerAct("mischief", {
  minGap: 300000,
  caps: ["cursor"],
  weight: () => buddy.traits.get("mischief") * 0.7,
  run: (act) => {
    if (chance(0.5)) {
      const c = buddy.cursor.pos();
      const ok = buddy.cursor.warp(c.x + (Math.random() * 120 - 60), c.y + (Math.random() * 120 - 60));
      if (!ok) return act.done("budget-denied");
      buddy.play("scheming");
      if (chance(0.5)) buddy.say("hehe", 2);
      act.after(2000, () => { buddy.play("idle"); act.done("nudged"); });
      return;
    }
    // The heist: prepare (scheme, announce), then lunge at the live cursor.
    buddy.play("scheming");
    if (chance(0.6)) sayLine("chaseStart", 2);
    act.after(900, () => {
      buddy.play("walk");
      buddy.chase(280);
    });
    act.once("gaveUp", () => {
      sayLine("gaveUp", 4);
      buddy.play("idle");
      act.done("gave-up");
    });
    act.once("caught", () => {
      if (!buddy.cursor.grab(4)) return act.done("grab-denied");
      buddy.play("scheming");
      sayLine("heist", 3);
      const s = buddy.screen();
      buddy.moveTo(s.x + 40 + Math.random() * (s.w - 160), s.y + 40 + Math.random() * (s.h - 240), 300);
      act.after(4200, () => {
        buddy.play("excited");
        buddy.say("hehehe", 2);
        act.after(2000, () => { buddy.play("idle"); act.done("heisted"); });
      });
    });
    // Chase resolves within 10s natively; belt to its braces.
    act.after(15000, () => act.done("timeout"));
  },
  onInterrupt: () => buddy.stop(),
});

// Idle chatter.
registerAct("chatter", {
  minGap: 150000,
  weight: () => buddy.traits.get("chattiness") * 0.6,
  run: (act) => {
    if (can("think") && chance(buddy.traits.get("weirdness") * 0.5)) {
      buddy.think("Say one short weird non-sequitur a tiny pixel goblin might say.", (t) => {
        if (!act.live) return;
        if (t) buddy.say(t, 4);
        act.done(t ? "mused" : "blanked");
      });
      // think can be slow or silent; never hold the stage waiting forever.
      act.after(20000, () => act.done("think-timeout"));
    } else {
      sayLine("chatter", 4);
      act.after(1200, () => act.done("said"));
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
