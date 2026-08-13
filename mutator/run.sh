#!/bin/bash
# Nightly buddy mutation. Runs claude against the live brain with the standing
# orders in prompt.md, verifies the result loads, reverts if it does not.
set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
# The mutation session must not feed buddy's own event stream.
export BUDDY_SELF=1

# BUDDY_HOME sandboxing: evolve a test install instead of the live one.
export BUDDY_HOME="${BUDDY_HOME:-$HOME/.buddy}"
BRAIN="$BUDDY_HOME/brain"
# The prompt is assembled from the installation's actual shape: core orders,
# plus the phone section only when a peer device has ever been seen, plus
# think guidance matching the chat spend switch. CAPABILITY REALITY law in
# the core makes this assembly authoritative for the mutator.
PROMPT_DIR="$(dirname "$0")"
assemble_prompt() {
  cat "$PROMPT_DIR/prompt.md"
  if [ -f "$BUDDY_HOME/peer-seen" ]; then
    cat "$PROMPT_DIR/prompt-phone.md"
  fi
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('$BUDDY_HOME/spend.json')).get('chatEnabled') else 1)" 2>/dev/null; then
    cat "$PROMPT_DIR/prompt-think.md"
  else
    cat "$PROMPT_DIR/prompt-nothink.md"
  fi
}
LOG="$BUDDY_HOME/mutator.log"
LOCK="$BUDDY_HOME/evolving.lock"

# One evolution at a time; the app watches this lock to run the ritual
# (and to pause brain hot-reloading) for nightly runs too.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "=== $(date) evolution already in progress, skipping ===" >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cd "$BRAIN" || exit 1
echo "=== mutation $(date) ===" >> "$LOG"

# Dark wakes often have no network yet - wait up to 5 minutes for it.
for _ in $(seq 1 30); do
  nc -z -w 3 api.anthropic.com 443 2>/dev/null && break
  sleep 10
done
if ! nc -z -w 3 api.anthropic.com 443 2>/dev/null; then
  echo "no network, skipping (the app's staleness check will catch up)" >> "$LOG"
  exit 0
fi

# Snapshot the test roster: entries added by this mutation show under
# "What's New" in the menu until the next mutation graduates them.
cp "$BRAIN/tests.json" "$BUDDY_HOME/tests.prev.json" 2>/dev/null || true

# Model for evolution runs, picked in the app's Setup panel (empty = default).
EVOLVE_MODEL=$(python3 -c "import json; print(json.load(open('$BUDDY_HOME/spend.json')).get('evolutionModel', ''))" 2>/dev/null || true)

# Night-shift pass (granted wish): acceptEdits only auto-approves file edits,
# so headless runs had every Bash call denied - the mutator could not verify
# or commit its own work. Allow exactly its verify/commit loop: the Buddy
# binary's two headless flags, and git in the brain repo. Nothing else.
claude -p "$(assemble_prompt)" \
  --permission-mode acceptEdits \
  --add-dir "$BUDDY_HOME" \
  --allowedTools \
    "Bash($BUDDY_HOME/bin/Buddy --check)" \
    "Bash($BUDDY_HOME/bin/Buddy --render)" \
    "Bash(cd $BRAIN)" \
    "Bash(git add:*)" \
    "Bash(git commit:*)" \
    "Bash(git status:*)" \
    "Bash(git diff:*)" \
    "Bash(git log:*)" \
  ${EVOLVE_MODEL:+--model "$EVOLVE_MODEL"} \
  >> "$LOG" 2>&1

# Safety net: the mutator was told to check and commit, but trust nothing.
if ! "$BUDDY_HOME/bin/Buddy" --check >> "$LOG" 2>&1; then
  echo "check failed, reverting" >> "$LOG"
  git checkout -- . >> "$LOG" 2>&1
  git clean -fd >> "$LOG" 2>&1
  exit 1
fi

# Commit anything the mutator left uncommitted so history stays complete.
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git status --porcelain)" ]; then
  git add -A >> "$LOG" 2>&1
  git commit -m "nightly drift (auto)" >> "$LOG" 2>&1
fi
# Success marker - the app's staleness check auto-triggers when this gets old.
date +%s > "$BUDDY_HOME/last-evolution"
echo "=== done $(date) ===" >> "$LOG"
