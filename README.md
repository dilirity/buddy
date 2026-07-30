# buddy

A pixel goblin that lives on your screen, watches your Claude Code sessions, talks, wanders, steals your cursor (rate-limited), holds grudges when you edit its settings, and mutates itself a little every night so you never quite know what it will do next.

## Architecture

- **Native shell** (Swift/AppKit, `macos/Sources/Buddy/`): transparent always-on-top panel, pixel sprite renderer, speech bubble, cursor control, senses (Claude Code hook events, idle, frontmost app, typing), invariant enforcement. Compiled once, rarely changes.
- **Brain** (`~/.buddy/brain/*.js` + JSON): all behavior, appearance (`sprites.json` pixel maps), persona, and quips. Plain JS run in JavaScriptCore, hot-reloaded on change. Bad JS logs and skips - it cannot crash the shell.
- **Mutator** (`mutator/`): nightly `claude -p` run against the live brain with standing orders to evolve it. Verifies with `Buddy --check`, reverts on failure, commits to the brain's own git repo. Writes a `secret-changelog.md` you promised not to read.

## Requirements

- macOS 13+ with Xcode Command Line Tools (`xcode-select --install`)
- Optional but strongly recommended: [Claude Code](https://claude.com/claude-code) logged in - powers chat, generative remarks, and nightly evolution. Without it buddy still runs, on canned lines only.

## Install

```bash
./setup.sh    # deps check + build + install to ~/.buddy + per-install secrets + launch
```

On first launch buddy introduces itself and asks a few questions (your name, pronouns, what you love, how much of a menace to be). Skippable; everything is editable later.

**Then open the menu bar goblin `ᴥ` > Setup.** Everything that spends money or touches your config is OFF until you consent there:

- **Accessibility permission** - typing awareness, cursor mischief, the double-Esc panic gesture. Buddy degrades gracefully without it.
- **Claude Code hooks** - lets buddy react to your coding sessions. Shows a diff, backs up `~/.claude/settings.json`, reversible.
- **Chat** - talk to buddy (double-click it). Uses your Claude subscription; pick the model.
- **Nightly evolution** - the self-mutation service (off / manual / weekly / nightly). Until enabled, "Evolve Now" in the menu still works for one-off mutations.

`setup.sh` itself never touches `~/.claude` and never installs the evolution service - the Setup panel owns both, with consent.

## Controls

- **Drag** buddy anywhere. **Click** to poke. **Double-click** to talk.
- **Double-tap Esc**: panic - buddy freezes for `panicFreezeMinutes`.
- Menu bar `ᴥ`: freeze/wake, reload brain, open brain folder, Evolve Now, Settings, Setup, quit. Tests added by the latest mutation appear under "What's New ✨" until the next one graduates them.
- **Settings** (menu > Settings): personality sliders, hard limits, and "Your World" - facts buddy's behaviors rely on (your name, what you love, your hours). Evolutions add new entries; they show up there on their own.
- `~/.buddy/traits.json`: the personality sliders on disk (mischief, chattiness, energy, clinginess, weirdness) with min/max bounds the mutator cannot escape. Edit values while buddy is awake - it will notice, and it will comment.
- `~/.buddy/invariants.json`: hard limits (max disruptive acts per hour, freeze length). The mutator has no write path here.
- `~/.buddy/config.json`: your declared facts (written by Settings and onboarding). Outside the brain repo on purpose - evolution failures can never touch it.

## Dev

Rule one: if `~/.buddy/evolving.lock` exists, an evolution is in progress - do not edit `~/.buddy/brain` or restart the app until it clears. The lock is taken by `mutator/run.sh` (launchd schedule or Evolve Now) and doubles as the app's signal to run the evolve ritual and pause hot-reloading.

```bash
cd macos
swift run Buddy --check   # headless brain validation
swift run                 # run from the checkout (install with setup.sh first so ~/.buddy/brain is seeded)
echo '{"_event":"Stop","_ts":0}' >> ~/.buddy/events.jsonl   # fake a hook event
```

## v1.5 ideas

Ball toy (drop it, buddy fetches), peek-from-screen-edge, menu-bar walking, Slack event feed, "what is the human looking at" vision comments. The mutator files wishes for new capabilities in `~/.buddy/brain/wishes.md` (appears once it starts evolving) - read it occasionally.
