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
PROMPT="$(dirname "$0")/prompt.md"
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

claude -p "$(cat "$PROMPT")" \
  --permission-mode acceptEdits \
  --add-dir "$BUDDY_HOME" \
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
