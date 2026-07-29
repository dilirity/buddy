// DJ buddy: mood-driven music. Etiquette is law: never stomp music that is
// already playing - check status first, always.
function tryDJ(announce) {
  buddy.music.status((s) => {
    if (s.state === "playing") {
      if (announce) sayLine("djAlready", 3);
      return;
    }
    if (!buddy.music.play(null)) {
      if (announce) buddy.say("wanted to dj but my chaos budget is spent", 4);
      return;
    }
    buddy.play("excited");
    sayLine("djStart", 4);
    buddy.after(3000, () => buddy.play("idle"));
  });
}

// Bored + silence = jazz hands.
buddy.every(300000, () => {
  if (state.busy || buddy.isFrozen() || buddy.isHeld() || state.mood === "sleepy") return;
  if (!chance(buddy.traits.get("energy") * 0.15)) return;
  tryDJ(false);
});

buddy.on("test:dj", () => tryDJ(true));

buddy.on("test:djStop", () => {
  buddy.music.pause();
  buddy.play("scheming");
  buddy.say(pickFresh(["fine. silence it is.", "killing the vibe as requested", "music off. you monster."]), 4);
  buddy.after(2500, () => buddy.play("idle"));
});
