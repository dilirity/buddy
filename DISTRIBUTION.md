# Distribution spec: buddy for other folks

Spec for making buddy installable by people who are not Pete. Drives implementation; each workstream below gets built and reviewed against this document.

## Goal and audience

v1 audience: developer colleagues willing to run one terminal command and follow a guided setup. Not a consumer product yet. Local building is enforced deliberately: people trust what they compile themselves, and it sidesteps signing/notarization entirely.

## Non-goals (v1)

- iOS. Dropped. Free provisioning expires sideloaded apps every 7 days; paid account plus TestFlight is a separate project.
- Codex or other AI engines. Claude Code only. Engine abstraction (mutator invocation plus Think stream-json protocol) is a later adapter layer.
- Signed/notarized mac binaries, dmg downloads, installers. Later, if ever, and it costs $99/yr.
- Code signing of ANY kind, including self-signed certificates (decided: too much hidden ceremony for users). Consequence: macOS keys permission grants (Accessibility, Automation) to the binary's hash, so every rebuild/update voids them and macOS re-prompts. Handled in UI, not by signing: the Setup panel explains the re-grant steps, and the app detects a binary change on launch and points the user at Setup when grants were lost.
- Non-developer install path.
- Nothing Glyph production key. Test key plus documented adb debug flag is fine for sideloaders.

## Principles

1. **Local build for trust.** No prebuilt binaries. setup.sh compiles on the user's machine.
2. **Never silently spend.** Anything that consumes Claude usage (evolution, think, chat) is off until the user explicitly consents, with the detected account shown to them first.
3. **Inform, then consent.** Every system touch (hooks in ~/.claude/settings.json, launchd service, Accessibility) shows exactly what it will do before doing it, and is reversible from the same place.
4. **Degrade gracefully.** No Claude Code = small brain mode (canned lines, no evolution). No Accessibility = no cursor mischief. No phone = one body. Nothing is a hard requirement except macOS itself.
5. **CAPS LAW everywhere, including evolution.** The mutator must never be told about capabilities the installation does not have.
6. **Nothing Pete-specific ships hardcoded.** Persona, references, ntfy topic, pairing secret: all generated or collected at setup.

## Workstreams

### WS1: setup.sh (outside-app setup)

One script at repo root. Idempotent: safe to re-run after partial failure.

Steps, in order:

1. **Dependency check.** git, swift/Xcode CLT. Missing CLT: offer to run `xcode-select --install`, then exit with "re-run after install completes". No silent installs.
2. **Build.** `swift build -c release` in macos/. Fail loudly with the actual compiler output.
3. **Install.** Binary plus bin scripts to ~/.buddy/bin. Seed brain from repo brain/ (no overwrite of existing user brain; same rule the app already uses). `git init` ~/.buddy/brain if new, initial commit.
4. **Secrets generation.** Per-install random ntfy topic (`buddy-<random>`), per-install random pairing secret. Written to ~/.buddy config files, never committed anywhere.
   **Code change required, both platforms:** the pairing secret is currently a compile-time literal (`"buddy-doorknob"`) in macos Coordination.swift and android Coordination.kt. It must become a runtime read: mac from a ~/.buddy config file, Android from app storage populated during pairing. No secret literal survives in source; a build without a configured secret refuses coordination rather than falling back to a default.
5. **Launch app.** First-run wizard (WS2/WS3/WS4/WS5) takes over from here. setup.sh does NOT install hooks, does NOT install the launchd service, does NOT touch ~/.claude - all of that requires in-app consent screens.

Pairing secret note: both devices need the same secret. Setup on the phone side reads it from the mac during pairing (or user copies it); exact pairing UX specced in WS6.

### WS2: Setup/health panel (in-app)

One window, reachable from the status bar menu at any time (not just first run). Checklist rows; each row: status indicator, one-line "why buddy wants this", required/optional tag, Fix button.

| Row | Detection | Fix action | Without it |
|---|---|---|---|
| Accessibility | `AXIsProcessTrusted()` via fresh helper process (in-process answers are launch-time-stale) | `AXIsProcessTrustedWithOptions(prompt)` registers the binary + deep-link to the pane | No typing sense, no double-Esc panic |
| Automation (Music/Spotify) | no row - the brain's early music.status poke makes macOS prompt organically right after first launch | n/a | DJ acts silently fail if denied |
| Claude Code | `which claude` + `claude --version` | Link to install docs | Small brain mode: no think, no chat, no evolution |
| Hooks | Parse ~/.claude/settings.json for buddy marker | Opens WS4 consent flow | No reactions to Claude sessions |
| Evolution service | launchd job loaded? next run time | Toggle: load/unload the agent | Buddy never changes |
| Spend consent | consent recorded in config? | Opens WS3 flow | think/evolution stay disabled |
| Device pairing | known peers list | Opens pairing instructions | One body |

Audited permission map (verified empirically 2026-07-29 on macOS 26): cursor warp/grab, idle detection, and window awareness need NO macOS permission. The global key monitor (typing sense, double-Esc panic) is an NSEvent API gated by ACCESSIBILITY - macOS auto-lists the app there on the arm attempt, and Input Monitoring never lists it (that list is for CGEventTap/IOHID APIs, which buddy does not use). Music verbs need per-app Automation. The key monitor must be re-armed when the grant arrives mid-run; a monitor armed without the grant stays dead forever.

Panel re-checks live (poll or on-focus), so a revoked permission shows up without restart. First-run wizard is this same panel in sequential mode with buddy narrating in character.

Post-update grant loss (no-signing consequence): on launch the app compares the running binary against a stored stamp; if the binary changed and Accessibility is no longer granted, buddy says so out loud and opens the Setup panel instead of silently losing abilities. Evolution never triggers this - it edits brain JS only, never the binary.

Permission prompts fire ONLY from Setup panel buttons (Accessibility Fix registers the current binary then opens the pane; Music "Request access" pokes the player). Never automatically on launch - the app may point at Setup, but the user clicks the trigger.

### WS3: Claude detection, spend consent, evolution schedule

Detection:

- `which claude`, `claude --version`.
- Account identity from ~/.claude.json `oauthAccount` (email, organization name). Displayed verbatim: "logged in as X (org: Y)".
- `ANTHROPIC_API_KEY` in env = API billing; different warning text (per-token cost, not subscription usage).
- There is no reliable API for plan tier. Do not guess. Show what we know, state what we do not.

Consent screen states plainly: which features spend (nightly evolution = one large claude -p run; chat/think = small haiku calls), on whose account, and that buddy never spends without this consent. If organization is present in oauthAccount, add: "This looks like a company/org account. Check that personal-project usage is okay with your org before enabling." We inform; the user decides. Nothing is blocked, nothing is silent.

Granularity: two independent switches.

- **Chat/think** (small spend): on/off.
- **Evolution** (large spend): off / manual only / weekly / nightly. Default: **off**. Schedule maps to launchd plist interval; manual-only keeps the Evolve Now menu item but no service.

Model configuration: separate model picker for chat/think (currently hardcoded `--model haiku` in Think.swift) and for evolution (currently the mutator's default). Stored in config, passed through to the claude invocations, validated by a cheap test call before saving. Defaults: haiku for chat, account default for evolution.

All of it changeable later from the setup panel, not just first run.

### WS4: Hooks install/uninstall

Consent flow, launched from setup panel:

1. Read ~/.claude/settings.json, compute the exact merged result.
2. Show a rendered diff of what will change. User approves or cancels.
3. Backup to ~/.buddy/backups/settings.json.<timestamp> before writing.
4. Every injected hook command tagged with a stable marker (e.g. contains `~/.buddy/bin/buddy-hook`) so detection, reinstall, and removal are exact and never touch user-authored hooks.
5. **Remove hooks** button reverses it: strips only marker-tagged entries, shows the diff first.
6. Idempotent: install over existing install = no-op, never duplicates.

BUDDY_SELF guard (so buddy's own claude sessions do not fire the user's hooks) is part of the injected commands, same as Pete's current setup, but generated rather than hand-woven.

### WS5: Persona onboarding (de-Pete-ing the brain)

Everything Pete-flavored lives in brain data files; the shipped defaults must become neutral, with a first-run interview filling them in.

Collected at first run via a small in-character form (skippable, editable later from Settings > Your World; existing installs get an `onboarded` marker from setup.sh and never see it):

- What to call the user, and their pronouns.
- Shows/games/movies for references (the starter references list ships empty and the reference act self-gates on empty; the nightly mutator grows quips.json references from the loves list).
- Menace slider (seeds the mischief trait, clamped by bounds as always).

As-built: declared facts live in `~/.buddy/config.json` (flat values, human-owned, unversioned, OUTSIDE the brain repo so a failed-evolution revert can never touch them), declared by `brain/config-schema.json` entries (`{default, type, label}`, mutator-owned) - the interview, the Settings "Your World" section, and chat-confirmed promotions all write the same store through `UserConfig`. Brain JS reads facts via `cfg(name, fallback)` and `userName()` ("boss" fallback); Think composes them into the system prompt at use time ("Facts: the human is called X; their pronouns are Y; they love Z"), and the mutator's orders say never to hardcode them in prose or code. Buddy may propose a newly-heard love in chat; the human's yes promotes it to config via the confirmation-gated `buddy.configSet`. persona.md stays buddy's own evolving prose - no UI ever writes it. Prefill for pre-interview installs parses the original template phrasing out of persona.md as best effort. Starter brain audit done - no author-specific names, shows, or feedback items ship; mutator/prompt.md speaks of "the human".

### WS6: Android as optional extra, glyph gating

Positioning: mac-only is the complete v1 product. Phone is "experimental, optional" with its own doc.

- ANDROID.md: install command-line Android SDK or Android Studio, `./gradlew assembleRelease`, sign with a local key, sideload via adb. Not part of setup.sh.
- Brain-in-assets is fine for local builders: assets seed from the same repo brain at build time. Known gap, documented: mac brain evolves nightly, phone brain does not sync (existing backlog item "brain sync mac to phone"); phone gets stale until reinstall. Acceptable for experimental tier.
- Pairing: shares the WS1 per-install secret; phone setup screen accepts topic + secret (manual entry v1; QR later if wanted).
- **Glyph gating**: runtime capability, not a build flag. `Build.MANUFACTURER == "Nothing"` plus SDK availability check; only then GlyphBridge initializes and caps() reports glyph true. Non-Nothing phones simply never have the capability; no crash, no config. Test-key adb debug flag documented in ANDROID.md for Nothing owners.

### WS7: Capability-aware mutator prompt

Problem: mutator/prompt.md hardcodes Pete's world (two bodies, travel, glyph, phone chat). A mac-only user's mutator would evolve behavior that never runs.

As built:

- prompt.md is the static core (laws, API docs, staging, TRAIT/SCHEDULER/VARIETY laws, neutral CAPS LAW). Conditional parts live beside it: prompt-phone.md (phone push/chat, glyph, the whole two-bodies/travel section), prompt-think.md vs prompt-nothink.md (think lanes vs "think returns null, canned lines only").
- mutator/run.sh `assemble_prompt` concatenates: core, plus phone section only if `~/.buddy/peer-seen` exists, plus the think variant matching spend.json chatEnabled.
- `peer-seen` is written once by Coordination when any peer is first discovered; setup.sh migrates it for installs that paired before the marker existed (coordination state file present).
- Core hard rule added (CAPABILITY REALITY): if a device or capability is not described in this prompt, it does not exist for this install - never write behavior for it. Runtime caps abort in runAct remains the second line of defense.

## Sequencing

1. WS1 setup.sh + secrets generation
2. WS2 setup/health panel
3. WS3 claude detection + spend consent + schedule
4. WS4 hooks consent flow
5. **Guinea pig milestone: one colleague installs on their mac from scratch. Their breakage feeds the backlog before further polish.**
6. WS5 persona onboarding
7. WS7 capability-aware mutator prompt
8. WS6 Android doc + glyph gating

Rationale: 1-4 make an install possible and safe; a real stranger install is the cheapest way to find the remaining "works on Pete's machine" assumptions; 5-8 are quality and reach.

## Testing strategy (developing this while a live buddy runs)

Pete's machine already runs buddy: live ~/.buddy, evolved brain, installed hooks, loaded launchd service. Fresh-install work cannot be tested against that. Three tiers:

1. **BUDDY_HOME env override** (small code change: Paths.swift, plus the hook script and launchd plist must respect it). A second instance runs against a sandbox directory for cheap iteration on panel/wizard/setup.sh code. Known collisions it does NOT solve: two status bar buddies, launchd label, Bonjour service name, and ~/.claude (hooks, account) is shared. Tests the app, not the install.
2. **Separate macOS user account.** Fresh home, fresh ~/.claude, fast user switching; the live buddy is untouched. This is the honest end-to-end fresh-install test. Needs its own claude login to exercise WS3 detection paths.
3. **macOS VM** (UTM/Tart on Apple Silicon). Most faithful, catches OS-level prompts (xcode-select, Accessibility dialogs). Run once before the guinea pig milestone, not every iteration.

BUDDY_HOME lands first as its own small workstream; it stays useful for development forever.

## Open questions

- Evolution token cost: measure a real nightly run's usage so WS3 consent text can state an honest number instead of "roughly N".
- Persona interview depth: minimal 3 questions vs richer conversation. Start minimal.
- Phone pairing UX: manual topic+secret entry acceptable for experimental tier, or QR from day one?
- What does "uninstall buddy" look like? Probably a setup.sh flag: remove hooks (via WS4 path), unload service, optionally delete ~/.buddy. Should be specced before guinea pig milestone.
- ntfy.sh is public infrastructure: per-install topic makes it unguessable, but phone chat still transits a public server. Minimum: disclose in setup. Better: configurable ntfy server for self-hosters. Decide before wider rollout.
