// Buddy travels to Pete's phone (ntfy push). The shell enforces a 10-minute
// minimum gap plus the disruption budget - use sparingly, make it count.

// The trip: say bye, walk to a screen edge, fade out, buzz the phone,
// lie low for a bit, come back like nothing happened.
buddy.on("test:visitPhone", () => {
  const s = buddy.screen();
  runAct([
    { anim: "scheming", line: "phoneBye", secs: 3, ms: 2500 },
    { anim: "walk", moveTo: { x: s.x + s.w - 90, y: s.y + 20, speed: 240 }, until: "arrived" },
    { anim: "hide", opacity: 0.15, ms: 1200 },
  ], () => {
    const sent = buddy.phone(pickFresh([
      "i am in your pocket now. the mac is boring without you",
      "hello from your phone. the cursor misses me already",
      "small screen. cozy. might stay",
    ]));
    buddy.after(sent ? 25000 : 3000, () => {
      buddy.opacity(1);
      buddy.play("excited");
      buddy.say(sent ? pickFresh(["im BACK. phones are small", "did you get my message??"]) : "trip cancelled. phone unreachable or too soon", 5);
      buddy.after(3000, () => buddy.play("idle"));
    });
  });
});

// Pete texting from his phone. Same memory as desktop chat - one relationship,
// two screens.
buddy.on("phoneChat", (e) => {
  const log = buddy.memory.get("chatLog") || [];
  const recent = log.slice(-6).map((x) => "pete: " + x.q + "\nbuddy: " + x.a).join("\n");
  const prompt =
    (recent ? "recent conversation:\n" + recent + "\n\n" : "") +
    "your personality sliders: " + JSON.stringify(buddy.traits.all()) + ". mood: " + state.mood + ".\n" +
    'pete texted you FROM HIS PHONE: "' + e.text + '"\n' +
    "reply as buddy via notification - one or two short lines, in character. you are on the mac, he is away.";
  buddy.play("scheming");
  buddy.say(pickFresh(["texting back...", "replying. one thumb.", "hold on. composing."]), 8, "phone");
  buddy.think(prompt, (t) => {
    const reply = t || "signal lost in the goblin tunnel. say again?";
    buddy.phoneReply(reply);
    buddy.play("excited");
    buddy.say("sent!", 3, "phone");
    log.push({ q: "[phone] " + e.text, a: reply });
    buddy.memory.set("chatLog", log.slice(-20));
    buddy.after(2500, () => buddy.play("idle"));
  });
});

// When Pete leaves for a while, buddy occasionally texts the void.
buddy.on("idle", (e) => {
  if (state.busy || state.evolving) return;
  if (!chance(buddy.traits.get("clinginess") * 0.3)) return;
  buddy.after(600000, () => {
    if (state.mood !== "sleepy") return; // still away
    buddy.phone(pickFresh([
      "you left. i counted your pixels again. all accounted for",
      "the mac is asleep and so am i. except im texting you. paradox",
      "come back. the cursor and i have nothing in common",
    ]));
  });
});
