// Reactions to Claude Code hook events (fed via ~/.buddy/events.jsonl).
buddy.on("claude:SessionStart", () => {
  if (state.busy) return;
  setMood("excited", "excited");
  if (chance(0.7 * buddy.traits.get("chattiness"))) sayLine("sessionStart", 3);
  buddy.after(4000, () => setMood("happy", "idle"));
});

// Stop fires at the end of every Claude turn - without a cooldown buddy
// celebrates nonstop during an active session.
let lastStopReact = 0;
buddy.on("claude:Stop", () => {
  if (state.busy) return;
  const now = Date.now();
  if (now - lastStopReact < 45000) return;
  lastStopReact = now;
  setMood("excited", "excited");
  const c = buddy.traits.get("chattiness");
  if (chance(0.25 * c)) {
    buddy.think("Claude Code just finished a task for Pete. One short cheeky congrats or comment.", (t) => {
      if (t) buddy.say(t, 5);
    });
  } else if (chance(0.6 * c)) {
    sayLine("celebrate", 4);
  }
  buddy.after(6000, () => setMood("happy", "idle"));
});

buddy.on("claude:UserPromptSubmit", () => {
  if (state.busy) return;
  if (chance(0.15 * buddy.traits.get("chattiness"))) sayLine("promptJudge", 3);
});

buddy.on("claude:PreToolUse", (e) => {
  if (state.busy) return;
  if (e.tool_name === "Bash" && chance(0.06 * buddy.traits.get("chattiness"))) sayLine("bashWarn", 3);
});

buddy.on("claude:Notification", () => {
  if (state.busy) return;
  // Functional nag - scaled but floored, buddy should still fetch you.
  if (chance(0.5 * Math.max(buddy.traits.get("chattiness"), 0.4))) {
    buddy.play("excited");
    sayLine("needsInput", 5);
    buddy.after(3000, () => buddy.play("idle"));
  }
});
