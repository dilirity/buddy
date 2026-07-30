// DJ buddy: mood-driven music. Etiquette is law: never stomp music that is
// already playing - check status first, always. Takes an optional act
// context (scheduler path); the test path runs without one.
function tryDJ(announce, act) {
  const finish = (outcome) => { if (act) act.done(outcome); };
  if (!can("music")) {
    if (announce) buddy.say("no music powers on this device", 4);
    return finish("no-music");
  }
  buddy.music.status((s) => {
    if (act && !act.live) return;
    if (s.state === "playing") {
      if (announce) sayLine("djAlready", 3);
      return finish("already-playing");
    }
    if (!buddy.music.play(null)) {
      if (announce) buddy.say("wanted to dj but my chaos budget is spent", 4);
      return finish("budget-denied");
    }
    buddy.play("excited");
    sayLine("djStart", 4);
    (act || buddy).after(3000, () => {
      buddy.play("idle");
      finish("djing");
    });
  });
  if (act) act.after(10000, () => act.done("status-timeout"));
}

// Bored + silence = jazz hands.
registerAct("dj", {
  minGap: 900000,
  caps: ["music"],
  weight: () => buddy.traits.get("energy") * 0.4,
  run: (act) => tryDJ(false, act),
});

buddy.on("test:dj", () => tryDJ(true));

buddy.on("test:djStop", () => {
  buddy.music.pause();
  buddy.play("scheming");
  buddy.say(pickFresh(["fine. silence it is.", "killing the vibe as requested", "music off. you monster."]), 4);
  buddy.after(2500, () => buddy.play("idle"));
});
