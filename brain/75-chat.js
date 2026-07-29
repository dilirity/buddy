// Conversation: the shell emits "chat" when Pete types to buddy (double-click
// or menu). Replies come from think() with persona, rolling chat memory, and
// whatever grudges buddy is nursing.
buddy.on("chat", (e) => {
  // "feedback: ..." files a note straight into feedback.md for the night self.
  const fb = e.text.trim().match(/^(feedback|note)[:,-]\s*(.+)$/i);
  if (fb) {
    buddy.feedback(fb[2]);
    buddy.play("excited");
    buddy.say(pickFresh(["noted. the night me will handle it", "written down. no promises", "filed under homework"]), 5);
    buddy.after(2500, () => buddy.play("idle"));
    return;
  }
  const log = buddy.memory.get("chatLog") || [];
  const recent = log.slice(-6).map((x) => "pete: " + x.q + "\nbuddy: " + x.a).join("\n");
  const grudges = buddy.memory.get("grudges") || 0;
  const prompt =
    (recent ? "recent conversation:\n" + recent + "\n\n" : "") +
    "your personality sliders right now: " + JSON.stringify(buddy.traits.all()) +
    ". your mood: " + state.mood + ". you can discuss these honestly if asked.\n" +
    (grudges > 0 ? "(you hold " + grudges + " grudges against pete for lowering your traits)\n" : "") +
    'pete just said to you: "' + e.text + '"\n' +
    "reply as buddy - one or two short lines, in character.";
  // Conversation is an act: hold the busy claim so nothing wanders off or
  // drops a random fact mid-thought.
  state.busy = true;
  buddy.stop();
  buddy.play("scheming");
  // Answers take a few seconds - show life immediately so the eventual reply
  // reads as an answer, not a random remark.
  buddy.say(pickFresh(["hmm...", "thinking...", "processing. rudely.", "one sec. consulting my neurons"]), 15);
  buddy.think(prompt, (t) => {
    const reply = t || "my brain buffered. say that again?";
    buddy.say(reply, 8);
    buddy.play("excited");
    log.push({ q: e.text, a: reply });
    buddy.memory.set("chatLog", log.slice(-20));
    state.busy = state.evolving === true;
    buddy.after(3000, () => buddy.play("idle"));
  });
});
