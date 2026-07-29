// Random wandering, frequency and speed scaled by energy.
buddy.every(9000, () => {
  if (buddy.isHeld() || buddy.isFrozen() || state.mood === "sleepy") return;
  // Never hijack an in-progress walk or heist.
  if (buddy.isMoving() || state.busy) return;
  const energy = buddy.traits.get("energy");
  if (!chance(energy * 0.45)) return;
  const s = buddy.screen();
  const x = s.x + 20 + Math.random() * (s.w - 140);
  const y = s.y + 10 + Math.random() * (s.h - 220);
  buddy.play("walk");
  buddy.moveTo(x, y, 100 + energy * 140);
});

buddy.on("arrived", () => {
  if (state.mood !== "sleepy") buddy.play("idle");
});
