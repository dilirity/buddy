// Conversation: the shell emits "chat" when Pete types to buddy (double-click
// or menu). One think() call both understands intent and produces the reply:
//   chat     - normal conversation
//   feedback - Pete wants future-buddy to change/build something -> feedback.md
//   setting  - Pete adjusts personality now ("be quieter") -> traits.set
buddy.on("chat", (e) => {
  // Fast path: explicit prefix still works, no LLM needed.
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
  const traits = buddy.traits.all();
  const prompt =
    (recent ? "recent conversation:\n" + recent + "\n\n" : "") +
    "your personality sliders right now: " + JSON.stringify(traits) +
    ". your mood: " + state.mood + ".\n" +
    (grudges > 0 ? "(you hold " + grudges + " grudges against pete for lowering your traits)\n" : "") +
    'pete just said to you: "' + e.text + '"\n\n' +
    "Ignore your usual output format. Reply ONLY with a JSON object, no other text:\n" +
    '{"action": "chat"|"feedback"|"setting", "reply": "what buddy says out loud, in character, 1-2 short lines", "feedback": "if action=feedback: the note to file", "trait": "if action=setting: one of ' +
    Object.keys(traits).join("|") + '", "value": 0.0}\n' +
    "action=feedback when pete asks future-you to change, add, or build something (request, idea, complaint about a behavior).\n" +
    "action=setting when pete wants to adjust how you act RIGHT NOW (be quieter, calmer, more chaotic) - pick the trait and a 0..1 value that honors the request given the current values.\n" +
    "action=chat for everything else.";

  state.busy = true;
  buddy.stop();
  buddy.play("scheming");
  buddy.say(pickFresh(["hmm...", "thinking...", "processing. rudely.", "one sec. consulting my neurons"]), 15);
  buddy.think(prompt, (t) => {
    let obj = null;
    if (t) {
      try {
        obj = JSON.parse(t.replace(/^```(json)?/i, "").replace(/```\s*$/, "").trim());
      } catch (err) {
        obj = null;
      }
    }
    let reply = (obj && obj.reply) || t || "my brain buffered. say that again?";
    if (obj && obj.action === "feedback" && obj.feedback) {
      buddy.feedback(obj.feedback);
    } else if (obj && obj.action === "setting" && obj.trait) {
      if (!buddy.traits.set(obj.trait, Number(obj.value))) {
        reply = "tried to adjust myself and failed. suspicious.";
      }
    }
    buddy.say(reply, 8);
    buddy.play("excited");
    log.push({ q: e.text, a: reply });
    buddy.memory.set("chatLog", log.slice(-20));
    state.busy = state.evolving === true;
    buddy.after(3000, () => buddy.play("idle"));
  });
});
