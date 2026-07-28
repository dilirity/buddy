// Being picked up, carried, and poked.
buddy.on("dragStart", () => {
  if (state.evolving) return;
  buddy.play("held");
  if (chance(0.8)) sayLine("dragStart", 2);
});

buddy.on("dragEnd", () => {
  if (state.evolving) return;
  buddy.play("scheming");
  if (chance(0.5)) sayLine("dragEnd", 3);
  buddy.after(1500, () => buddy.play("idle"));
});

buddy.on("poked", () => {
  // Acts (hide and seek etc.) own the poke while they run.
  if (state.busy) return;
  buddy.play("excited");
  if (chance(0.6)) sayLine("poked", 2);
  buddy.after(2000, () => buddy.play("idle"));
});
