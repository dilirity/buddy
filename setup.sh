#!/bin/bash
# Buddy guided setup: dependency check, local build, install into ~/.buddy,
# per-install secrets, launch. Touches nothing outside ~/.buddy,
# ~/Applications/Buddy.app and its own autostart entry. Claude hooks and the
# nightly evolution service are consented to inside the app (Settings > System) -
# never installed from here.
# Idempotent: safe to re-run after a partial failure or to update.
set -euo pipefail
cd "$(dirname "$0")"

BUDDY_HOME="${BUDDY_HOME:-$HOME/.buddy}"
# Captured before any install step: does a brain already exist here?
EXISTING_INSTALL=0
[ -d "$BUDDY_HOME/brain/.git" ] && EXISTING_INSTALL=1

echo "== checking dependencies =="
if ! command -v git >/dev/null 2>&1; then
  echo "git is required. Install Xcode Command Line Tools first: xcode-select --install"
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are missing. Starting Apple's installer..."
  xcode-select --install || true
  echo "Re-run ./setup.sh once that install finishes."
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi
if command -v claude >/dev/null 2>&1; then
  echo "claude found: $(claude --version 2>/dev/null || echo '(version unknown)')"
else
  echo "note: Claude Code not found. Buddy still works, in small-brain mode"
  echo "(canned lines, no chat, no evolution). Install it any time; the app's"
  echo "System tab picks it up."
fi

echo "== building (takes a minute the first time) =="
(cd macos && swift build -c release)

echo "== installing to $BUDDY_HOME =="
mkdir -p "$BUDDY_HOME/bin"
cp macos/.build/release/Buddy "$BUDDY_HOME/bin/Buddy"
cp macos/bin/buddy-hook "$BUDDY_HOME/bin/buddy-hook"
cp macos/bin/activity-report "$BUDDY_HOME/bin/activity-report"
chmod +x "$BUDDY_HOME/bin/activity-report"
chmod +x "$BUDDY_HOME/bin/buddy-hook"

# Seed the live brain without overwriting an evolved one.
mkdir -p "$BUDDY_HOME/brain"
for f in brain/*; do
  base="$(basename "$f")"
  if [ ! -e "$BUDDY_HOME/brain/$base" ]; then
    cp "$f" "$BUDDY_HOME/brain/$base"
    echo "seeded brain/$base"
  fi
done

# Mutator files at a stable path so launchd and the Evolve Now menu find
# them. The nightly SERVICE is not installed here - the app's System tab
# does that, with consent, because it spends the user's Claude usage.
mkdir -p "$BUDDY_HOME/mutator"
cp mutator/run.sh mutator/prompt*.md "$BUDDY_HOME/mutator/"
chmod +x "$BUDDY_HOME/mutator/run.sh"

# Brain gets its own git history so the mutator can commit (and revert) itself.
# Repo-local identity: a fresh mac often has no global user.email, and without
# one every commit here (this one, nightly drift, feedback) dies.
if [ ! -d "$BUDDY_HOME/brain/.git" ]; then
  git -C "$BUDDY_HOME/brain" init -q
  git -C "$BUDDY_HOME/brain" config user.name buddy
  git -C "$BUDDY_HOME/brain" config user.email buddy@localhost
  git -C "$BUDDY_HOME/brain" add -A
  git -C "$BUDDY_HOME/brain" commit -qm "buddy is born"
  echo "initialized brain git repo"
fi

echo "== per-install secrets =="
# ntfy topic for phone chat. Random per install; never committed anywhere.
if [ ! -f "$BUDDY_HOME/phone.json" ]; then
  printf '{"topic": "buddy-%s"}\n' "$(openssl rand -hex 10)" > "$BUDDY_HOME/phone.json"
  echo "generated ntfy topic"
fi
# Existing installs already have a persona - never show them the first-run
# interview. (Fresh installs get it on first launch.)
if [ "$EXISTING_INSTALL" = 1 ] && [ ! -f "$BUDDY_HOME/onboarded" ]; then
  touch "$BUDDY_HOME/onboarded"
fi

# This install has paired with a phone before the peer-seen marker existed.
if [ -f "$BUDDY_HOME/coordination-mac.json" ] && [ ! -f "$BUDDY_HOME/peer-seen" ]; then
  date +%s > "$BUDDY_HOME/peer-seen"
fi

# Spend config. Fresh installs spend nothing until consented in the app's
# System tab; an install that predates spend.json was built when chat and
# nightly evolution were always-on, so keep that behavior for it. The
# launchctl probe is user-global, so only the real install may trust it -
# a sandbox (BUDDY_HOME override) is always fresh.
if [ ! -f "$BUDDY_HOME/spend.json" ] && [ "$BUDDY_HOME" = "$HOME/.buddy" ]; then
  if [ -f "$BUDDY_HOME/coordination-mac.json" ] || launchctl list com.buddy.mutator >/dev/null 2>&1; then
    cat > "$BUDDY_HOME/spend.json" <<'JSON'
{
  "chatEnabled": true,
  "chatModel": "haiku",
  "evolutionModel": "",
  "evolutionSchedule": "nightly"
}
JSON
    echo "kept existing spend behavior (chat on, nightly evolution)"
  fi
fi
# Device-pairing secret. No secret file = coordination stays off entirely.
if [ ! -f "$BUDDY_HOME/secret" ]; then
  if [ -f "$BUDDY_HOME/coordination-mac.json" ]; then
    # Existing install that already paired using the legacy compiled-in
    # secret: keep that value so the phone keeps answering, until the
    # Android side reads its secret from storage and both get re-keyed.
    printf 'buddy-doorknob\n' > "$BUDDY_HOME/secret"
    echo "kept legacy pairing secret (re-key when the phone app updates)"
  else
    openssl rand -hex 16 > "$BUDDY_HOME/secret"
    echo "generated pairing secret"
  fi
  chmod 600 "$BUDDY_HOME/secret"
fi

# Sandbox installs (BUDDY_HOME override) stop here: the app bundle, autostart
# entry, and launch are shared per-user resources that must keep pointing at
# the real install.
if [ "$BUDDY_HOME" != "$HOME/.buddy" ]; then
  echo
  echo "sandbox install done. run it with:  BUDDY_HOME=\"$BUDDY_HOME\" \"$BUDDY_HOME/bin/Buddy\""
  exit 0
fi

# App bundle in ~/Applications so Raycast/Spotlight launch buddy by name.
APP="$HOME/Applications/Buddy.app/Contents"
mkdir -p "$APP/MacOS"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Buddy</string>
    <key>CFBundleIdentifier</key><string>com.buddy.app</string>
    <key>CFBundleExecutable</key><string>Buddy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
cat > "$APP/MacOS/Buddy" <<'SH'
#!/bin/bash
exec "${BUDDY_HOME:-$HOME/.buddy}/bin/Buddy"
SH
chmod +x "$APP/MacOS/Buddy"
echo "installed ~/Applications/Buddy.app"

# Autostart at login. RunAtLoad only - quitting from the menu stays quit.
# A fresh account has no LaunchAgents dir yet.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.buddy.app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.buddy.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BUDDY_HOME/bin/Buddy</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.buddy.app.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.buddy.app.plist"
echo "autostart installed"

echo
if pgrep -xq Buddy; then
  echo "done. Buddy is already running - restart it (menu bar goblin > Quit,"
  echo "then relaunch) to pick up the new build."
else
  open "$HOME/Applications/Buddy.app"
  echo "done. Buddy is launching - look for the goblin."
fi
echo "everything else (permissions, Claude hooks, evolution) happens in the"
echo "app: menu bar goblin > Settings > System."
