// TV/movie references and random facts, from quips.json.
// The nightly mutator is expected to keep expanding that file.
// References carry a show tag; buddy dons a matching prop from sprites.json.
// The show -> prop mapping lives in quips.json ("showProps") so adding a show
// is pure data: quotes + prop pixels + one mapping entry.
function showProps() {
  const q = buddy.data("quips.json");
  return (q && q.showProps) || {};
}

globalThis.sayRef = function (secs) {
  const q = buddy.data("quips.json");
  if (!q || !q.references || !q.references.length) return false;
  const texts = q.references.map((r) => (typeof r === "string" ? r : r.text));
  const t = pickFresh(texts);
  const entry = q.references.find((r) => (typeof r === "string" ? r : r.text) === t);
  const show = entry && typeof entry === "object" ? entry.show : null;
  // Prop rides along with the line - the shell strips it when the bubble goes.
  buddy.say(t, secs || 5, show ? showProps()[show] : null);
  return true;
};

// Glasses on, fact out. Looking smart is half the fact.
globalThis.sayFact = function (secs) {
  const q = buddy.data("quips.json");
  if (!q || !q.facts || !q.facts.length) return false;
  buddy.say(pickFresh(q.facts), secs || 7, "glasses");
  return true;
};

// References sneak into celebrations.
buddy.on("claude:Stop", () => {
  if (state.busy) return;
  if (chance(0.2 * buddy.traits.get("weirdness"))) {
    buddy.after(2000, () => sayRef(5));
  }
});

// Facts when bored.
buddy.every(180000, () => {
  if (state.busy) return;
  if (buddy.isFrozen() || state.mood === "sleepy") return;
  if (!chance(0.25 * buddy.traits.get("chattiness"))) return;
  buddy.play("scheming");
  sayFact(7);
  buddy.after(4000, () => buddy.play("idle"));
});

// Poke it enough times, get a reference.
buddy.on("poked", () => {
  if (state.busy) return;
  if (chance(0.25)) sayRef(4);
});
