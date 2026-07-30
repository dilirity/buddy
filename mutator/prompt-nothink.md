# Thinking (DISABLED)

The human has turned Claude chat/think OFF for this installation. `buddy.think()` and `buddy.thinkNow()` always return null here. Never build behaviors that depend on their output - lines.json pools are your only dialogue. The chat reply path in 75-chat.js already falls back to canned replies on its own; keep that fallback healthy and growing.
