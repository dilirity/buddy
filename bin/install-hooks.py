#!/usr/bin/env python3
"""Merge buddy event hooks into ~/.claude/settings.json.

Idempotent: skips events that already have a buddy-hook entry.
A timestamped backup of settings.json is written before any change.
"""
import json
import os
import shutil
import time

SETTINGS = os.path.expanduser("~/.claude/settings.json")
HOOK_CMD = os.path.expanduser("~/.buddy/bin/buddy-hook")
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Notification",
    "SessionEnd",
]


def main():
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
        backup = SETTINGS + ".bak-" + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(SETTINGS, backup)
        print(f"backup: {backup}")

    hooks = settings.setdefault("hooks", {})
    changed = False
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        if any(
            h.get("command", "").endswith(f"buddy-hook {event}")
            for e in entries
            for h in e.get("hooks", [])
        ):
            print(f"{event}: already installed")
            continue
        entry = {"hooks": [{"type": "command", "command": f"{HOOK_CMD} {event}"}]}
        if event in ("PreToolUse", "PostToolUse"):
            entry["matcher"] = "*"
        entries.append(entry)
        changed = True
        print(f"{event}: installed")

    if changed:
        with open(SETTINGS, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        print("settings.json updated")
    else:
        print("nothing to do")


if __name__ == "__main__":
    main()
