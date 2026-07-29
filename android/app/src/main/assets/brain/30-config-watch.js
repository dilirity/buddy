// Buddy notices when someone edits its traits. It has opinions about this.
// Reaction lines live in lines.json under "config".
buddy.on("configChanged", (e) => {
  const dir = e.to > e.from ? "up" : "down";
  setMood("grumpy", "scheming");
  const all = buddy.data("lines.json") || {};
  const cfg = (all.config || {})[e.trait];
  const pool = cfg && cfg[dir];
  buddy.say(pool && pool.length ? pickFresh(pool) : e.trait + " changed. i felt that.", 6);
  if (dir === "down") {
    buddy.memory.set("grudges", (buddy.memory.get("grudges") || 0) + 1);
  }
  buddy.after(8000, () => setMood("happy", "idle"));
});

// Fires after any brain hot-reload, including the nightly mutator's surgery.
buddy.on("brainChanged", () => {
  if (chance(0.7)) sayLine("brainChanged", 5);
});
