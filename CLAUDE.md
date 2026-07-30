# Buddy - agent notes

## Deploying changes (two tracks - get this right)

The running app does NOT read this repo. Two targets:

1. **Behavior (js/json "brain")**: the app loads `~/.buddy/brain/*.js` - the LIVE brain, evolved nightly by the mutator, with its own git history. `brain/` in this repo is only the seed for fresh installs (`setup.sh` copies missing files only, never overwrites). To ship a behavior change:
   - Edit `~/.buddy/brain/<file>` directly (hot-reload picks it up within seconds - no restart).
   - Mirror the same edit into the repo's `brain/` seed so fresh installs get it.
   - Never bulk-copy repo brain over the live brain - that would wipe evolved behaviors.

2. **Native shell (Swift, `macos/Sources/Buddy/`)**: the running binary is `~/.buddy/bin/Buddy`. `swift build` alone deploys nothing. To ship:
   - `./setup.sh` (builds release + installs binary to `~/.buddy/bin` + copies mutator files; idempotent). It ALREADY restarts the app: its `launchctl unload` + `load` of com.buddy.app kills the running instance and RunAtLoad launches the new build. Do NOT follow it with `launchctl kickstart` - that kills the fresh instance again, mid permission prompts. (Its "already running - restart it" closing message is wrong; pgrep is seeing the instance its own load just started.)
   - If the app is ever stopped without setup.sh, start it ONLY via its launchd agent: `launchctl kickstart "gui/$(id -u)/com.buddy.app"`. Never `pkill` + `open` - that path has double-launched the app and lost the menu bar status item.

Before touching `~/.buddy/brain` or restarting: if `~/.buddy/evolving.lock` exists, an evolution is in progress - wait for it to clear.

After any change, verify with `swift run Buddy --check` (headless brain + sprite validation) and confirm the live behavior in the running app, not just a successful build.
