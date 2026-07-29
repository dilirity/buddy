// The evolution ritual. Native emits evolveStart when the mutator begins
// (nightly or via Evolve Now) and evolveEnd {changed} when it finishes.
// If the brain changed it hot-reloads first, so the NEW brain handles the
// ending - but on a no-change run THIS context survives, so clean up here too.
let evolveTicker = null;

buddy.on("evolveStart", () => {
  state.busy = true;
  state.evolving = true;
  buddy.stop();
  buddy.play("evolve");
  sayLine("evolveStart", 6);
  // Mutations take minutes; keep signalling life (and keep the anim asserted
  // in case something overrode it).
  evolveTicker = buddy.every(45000, () => {
    buddy.play("evolve");
    if (chance(0.7)) sayLine("evolveProgress", 5);
  });
});

// Pokes during surgery get a firm but polite no.
buddy.on("poked", () => {
  if (state.evolving) sayLine("evolveBusy", 3);
});

buddy.on("evolveEnd", (e) => {
  state.busy = false;
  state.evolving = false;
  if (evolveTicker) {
    buddy.cancel(evolveTicker);
    evolveTicker = null;
  }
  buddy.play("excited");
  sayLine(e.changed ? "evolveChanged" : "evolveSame", 6);
  buddy.after(3500, () => buddy.play("idle"));
});
