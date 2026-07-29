// Conversation, unified: desktop (double-click) and phone (ntfy) run the SAME
// intent triage - chat, feedback, setting, command - only delivery differs.
//   desktop -> speech bubble;  phone -> notification reply + on-screen texting.
globalThis.handleChatMessage = function (text, source) {
  const phone = source === "phone";
  const deliver = (msg, secs) => {
    if (phone) {
      buddy.phoneReply(msg);
      buddy.play("excited");
      buddy.say("sent!", 3, "phone");
    } else {
      buddy.say(msg, secs || 8);
      buddy.play("excited");
    }
  };
  const finish = () => {
    state.busy = state.evolving === true;
    buddy.after(3000, () => buddy.play("idle"));
  };

  // Fast path: explicit feedback prefix, no LLM needed.
  const fb = text.trim().match(/^(feedback|note)[:,-]\s*(.+)$/i);
  if (fb) {
    buddy.feedback(fb[2]);
    deliver(pickFresh(["noted. the night me will handle it", "written down. no promises", "filed under homework"]), 5);
    buddy.after(2500, () => buddy.play("idle"));
    return;
  }

  // No thinking hardware here (phone): stay charming, skip the LLM.
  if (!can("think")) {
    const log = buddy.memory.get("chatLog") || [];
    const reply = pickFresh([
      "small brain mode. my big thoughts live on the mac",
      "im cute here but dumb. ask me at the mac",
      "no deep thoughts on this tiny rock. but hi",
    ]);
    deliver(reply, 6);
    log.push({ q: (phone ? "[phone] " : "") + text, a: reply });
    buddy.memory.set("chatLog", log.slice(-20));
    buddy.after(2500, () => buddy.play("idle"));
    return;
  }

  const log = buddy.memory.get("chatLog") || [];
  const recent = log.slice(-4).map((x) => "pete: " + x.q + "\nbuddy: " + x.a).join("\n");
  const grudges = buddy.memory.get("grudges") || 0;
  const traits = buddy.traits.all();
  const tests = buddy.data("tests.json") || [];
  const prompt =
    (recent ? "recent conversation:\n" + recent + "\n\n" : "") +
    "your personality sliders right now: " + JSON.stringify(traits) +
    ". your mood: " + state.mood + ".\n" +
    (grudges > 0 ? "(you hold " + grudges + " grudges against pete for lowering your traits)\n" : "") +
    "things you can DO on command (id - what it is): " +
    tests.map((x) => x.id + " - " + x.title).join("; ") + "\n" +
    (phone
      ? 'pete texted you FROM HIS PHONE: "' + text + '" (he is away from the mac; your reply arrives as a notification)\n\n'
      : 'pete just said to you: "' + text + '"\n\n') +
    "Ignore your usual output format. Reply ONLY with a JSON object, no other text:\n" +
    '{"action": "chat"|"feedback"|"setting"|"command", "reply": "what buddy says, in character, 1-2 short lines", "feedback": "if action=feedback: the note to file", "trait": "if action=setting: one of ' +
    Object.keys(traits).join("|") + '", "value": 0.0, "command": "if action=command: one id from the list above"}\n' +
    "action=command when pete tells you to DO something right now (hide, steal the cursor, play music, visit his phone...) and one of your listed abilities fits.\n" +
    "action=feedback when pete asks future-you to change, add, or build something.\n" +
    "action=setting when pete wants to adjust how you act RIGHT NOW (be quieter, calmer, more chaotic) - pick the trait and a 0..1 value honoring the request given current values.\n" +
    "action=chat for everything else, including commands you have no ability for (be sassy about those).";

  state.busy = true;
  buddy.stop();
  buddy.play("scheming");
  if (phone) {
    buddy.say(pickFresh(["texting back...", "replying. one thumb.", "hold on. composing."]), 20, "phone");
  } else {
    buddy.say(pickFresh(["hmm...", "thinking...", "processing. rudely.", "one sec. consulting my neurons"]), 20);
  }
  const tSent = Date.now();
  (buddy.thinkNow || buddy.think)(prompt, (t) => {
    buddy.log("CHAT-LATENCY " + (Date.now() - tSent) + "ms (" + source + ")");
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
    } else if (obj && obj.action === "command" && obj.command) {
      const valid = tests.some((x) => x.id === obj.command);
      log.push({ q: (phone ? "[phone] " : "") + text, a: reply });
      buddy.memory.set("chatLog", log.slice(-20));
      if (valid) {
        deliver(reply, 4);
        state.busy = state.evolving === true;
        buddy.after(1500, () => buddy.emit("test:" + obj.command));
      } else {
        deliver("i dont know how to do that yet. add it to my homework?", 6);
        finish();
      }
      return;
    }
    deliver(reply);
    log.push({ q: (phone ? "[phone] " : "") + text, a: reply });
    buddy.memory.set("chatLog", log.slice(-20));
    finish();
  });
};

buddy.on("chat", (e) => handleChatMessage(e.text, "desktop"));
