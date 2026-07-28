# buddy

A pixel goblin that lives on your screen, watches your Claude Code sessions, talks, wanders, steals your cursor (rate-limited), holds grudges when you edit its settings, and mutates itself a little every night so you never quite know what it will do next.

## Architecture

- **Native shell** (Swift/AppKit, `Sources/Buddy/`): transparent always-on-top panel, pixel sprite renderer, speech bubble, cursor control, senses (Claude Code hook events, idle, frontmost app, typing), invariant enforcement. Compiled once, rarely changes.
- **Brain** (`~/.buddy/brain/*.js` + JSON): all behavior, appearance (`sprites.json` pixel maps), persona, and quips. Plain JS run in JavaScriptCore, hot-reloaded on change. Bad JS logs and skips - it cannot crash the shell.
- **Mutator** (`mutator/`): nightly `claude -p` run against the live brain with standing orders to evolve it. Verifies with `Buddy --check`, reverts on failure, commits to the brain's own git repo. Writes a `secret-changelog.md` you promised not to read.

## Install

```bash
./install.sh                      # build + install to ~/.buddy, seed brain
~/.buddy/bin/Buddy &              # run
python3 bin/install-hooks.py      # wire Claude Code hooks (backs up settings.json)
```

Nightly mutator (optional, needs `claude` CLI logged in):

```bash
sed "s|__HOME__|$HOME|" mutator/com.buddy.mutator.plist > ~/Library/LaunchAgents/com.buddy.mutator.plist
launchctl load ~/Library/LaunchAgents/com.buddy.mutator.plist
```

Or trigger a mutation on demand: menu bar `ᴥ` > Evolve Now. Buddy plays its evolve animation while the mutator works; tests added by the latest mutation appear under "What's New ✨" until the next one graduates them.

Grant Accessibility/Input Monitoring permission when macOS asks - needed for cursor mischief, typing awareness, and the panic gesture. Buddy degrades gracefully without it.

## Controls

- **Drag** buddy anywhere. **Click** to poke.
- **Double-tap Esc**: panic - buddy freezes for `panicFreezeMinutes`.
- Menu bar `ᴥ`: freeze/wake, reload brain, open brain folder, quit.
- `~/.buddy/traits.json`: personality sliders (mischief, chattiness, energy, clinginess, weirdness) with min/max bounds the mutator cannot escape. Edit values while buddy is awake - it will notice, and it will comment.
- `~/.buddy/invariants.json`: hard limits (max disruptive acts per hour, freeze length). The mutator has no write path here.

## Dev

```bash
swift run             # runs against ~/.buddy/brain (seeds it from ./brain on first run)
swift run Buddy --check   # headless brain validation
echo '{"_event":"Stop","_ts":0}' >> ~/.buddy/events.jsonl   # fake a hook event
```

## v1.5 ideas

Ball toy (drop it, buddy fetches), peek-from-screen-edge, menu-bar walking, Slack event feed, "what is Pete looking at" vision comments. The mutator files wishes for new capabilities in `~/.buddy/brain/wishes.md` - read it occasionally.
