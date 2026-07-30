// Deterministic demos for the Test menu (menu entries defined in tests.json,
// each fires a test:<id> event). No chance gates, no cooldowns - always fires.
function demo(anim, lineKey, secs) {
  buddy.play(anim);
  if (lineKey) sayLine(lineKey, secs || 4);
  buddy.after(4000, () => buddy.play("idle"));
}

buddy.on("test:sessionStart", () => demo("excited", "sessionStart", 3));
buddy.on("test:celebrate", () => demo("excited", "celebrate", 4));
buddy.on("test:needsInput", () => demo("excited", "needsInput", 5));
buddy.on("test:promptJudge", () => demo("scheming", "promptJudge", 3));
buddy.on("test:wake", () => { setMood("happy", "idle"); sayLine("wake", 3); });
buddy.on("test:sleep", () => setMood("sleepy", "sleep"));

buddy.on("test:fact", () => {
  buddy.play("scheming");
  sayFact(7);
  buddy.after(4000, () => buddy.play("idle"));
});

buddy.on("test:reference", () => {
  sayRef(5);
});

buddy.on("test:thinkLine", () => {
  buddy.play("scheming");
  buddy.think("Say one short weird non-sequitur a tiny pixel goblin might say.", (t) => {
    buddy.say(t || "brain empty. is the claude cli logged in?", 5);
    buddy.play("idle");
  });
});

buddy.on("test:nudge", () => {
  if (!can("cursor")) { buddy.say("no cursor on this device", 4); return; }
  const c = buddy.cursor.pos();
  if (buddy.cursor.warp(c.x + 60, c.y + 60)) {
    buddy.play("scheming");
    buddy.say("hehe", 2);
    buddy.after(2000, () => buddy.play("idle"));
  } else {
    buddy.say("warp denied - budget spent or no accessibility permission", 5);
  }
});

let testStealing = false;
buddy.on("test:heist", () => {
  if (!can("cursor")) { buddy.say("nothing to steal here. tragic", 4); return; }
  testStealing = true;
  state.busy = true;
  buddy.play("scheming");
  sayLine("chaseStart", 2);
  buddy.after(900, () => {
    if (!testStealing) return;
    buddy.play("walk");
    buddy.chase(350);
  });
  buddy.after(15000, () => {
    if (testStealing) { testStealing = false; state.busy = false; }
  });
});
buddy.on("gaveUp", () => {
  if (!testStealing) return;
  testStealing = false;
  state.busy = false;
  sayLine("gaveUp", 4);
  buddy.play("idle");
});
buddy.on("caught", () => {
  if (!testStealing) return;
  testStealing = false;
  state.busy = false;
  if (!buddy.cursor.grab(4)) {
    buddy.say("grab denied - budget spent or no accessibility permission", 5);
    buddy.play("idle");
    return;
  }
  buddy.play("scheming");
  sayLine("heist", 3);
  const s = buddy.screen();
  buddy.moveTo(s.x + s.w * 0.25, s.y + s.h * 0.35, 300);
  buddy.after(4500, () => buddy.play("idle"));
});

buddy.on("test:clingy", () => {
  if (!can("cursor")) { buddy.say("no cursor to visit here. YOU come here", 4); return; }
  runRegisteredAct("clingy");
});

buddy.on("test:grudge", () => {
  buddy.emit("configChanged", { trait: "mischief", from: 0.6, to: 0.4 });
});

buddy.on("test:walk", () => {
  const s = buddy.screen();
  buddy.play("walk");
  buddy.moveTo(s.x + 40 + Math.random() * (s.w - 160), s.y + 40 + Math.random() * (s.h - 240), 200);
});
