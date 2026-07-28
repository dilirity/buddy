#!/bin/bash
# Build buddy and install runtime files into ~/.buddy.
# Does NOT touch ~/.claude/settings.json (run bin/install-hooks.py yourself)
# and does NOT install the nightly mutator (see mutator/README section in README.md).
set -euo pipefail
cd "$(dirname "$0")"

echo "== building =="
swift build -c release

echo "== installing to ~/.buddy =="
mkdir -p "$HOME/.buddy/bin"
cp .build/release/Buddy "$HOME/.buddy/bin/Buddy"
cp bin/buddy-hook "$HOME/.buddy/bin/buddy-hook"
chmod +x "$HOME/.buddy/bin/buddy-hook"

# Seed the live brain without overwriting an evolved one.
mkdir -p "$HOME/.buddy/brain"
for f in brain/*; do
  base="$(basename "$f")"
  if [ ! -e "$HOME/.buddy/brain/$base" ]; then
    cp "$f" "$HOME/.buddy/brain/$base"
    echo "seeded brain/$base"
  fi
done

# Mutator lives at a stable path so both launchd and the Evolve Now menu find it.
mkdir -p "$HOME/.buddy/mutator"
cp mutator/run.sh mutator/prompt.md "$HOME/.buddy/mutator/"
chmod +x "$HOME/.buddy/mutator/run.sh"

# Brain gets its own git history so the mutator can commit (and revert) itself.
if [ ! -d "$HOME/.buddy/brain/.git" ]; then
  git -C "$HOME/.buddy/brain" init -q
  git -C "$HOME/.buddy/brain" add -A
  git -C "$HOME/.buddy/brain" commit -qm "buddy is born"
  echo "initialized brain git repo"
fi

echo
echo "done. run it with:  ~/.buddy/bin/Buddy &"
echo "hooks:              python3 bin/install-hooks.py"
echo "nightly mutator:    see README.md"
