#!/usr/bin/env bash
# fleet installer — macOS + Linux, bash + zsh. Idempotent. Fleet-only: it wires the
# `fleet` command into your shell, points tmux at the bundled config, records the
# repo location (so `fleet remote` finds it over SSH), writes the config, and installs
# a login auto-start. It assumes the box is already provisioned (Tailscale + git/jq/
# tmux + claude) — on a bare machine run bootstrap/bootstrap.sh first.
#
#   ./install.sh                     install for the current user from this clone
#   FLEET_PREFIX=/opt/fleet ./install.sh          point at a shared clone instead

set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${FLEET_PREFIX:-$REPO}"
OS="$(uname -s)"

# ~/.local/bin (where the claude installer puts its CLI) isn't on a non-interactive
# SSH PATH, so detect already-installed CLIs correctly instead of trying to reinstall.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

# Positional args:  install.sh [server|client] [location]  (run via `fleet init`)
#   fleet init server            # a box that runs agents
#   fleet init client laptop     # attach-only, tagged 'laptop'
# (FLEET_MODE / FLEET_LOCATION env still work and take a back seat to these.)
for _a in "$@"; do
  case "$_a" in
    server|client) FLEET_MODE="$_a" ;;
    -*) echo "install: unknown option: $_a" >&2; exit 1 ;;
    *) FLEET_LOCATION="$_a" ;;
  esac
done

# server = full node: runs local agents + a login autostart.
# client = attach-only: no local sessions, no autostart (this laptop).
# Preserve the mode chosen last time (from fleet.json, then the legacy file), else server —
# so a re-run / `fleet update` never silently resets it.
MODE="${FLEET_MODE:-}"
[ -z "$MODE" ] && MODE="$(jq -r '.mode // empty' "$HOME/.config/fleet/fleet.json" 2>/dev/null || true)"
[ -z "$MODE" ] && MODE="$(cat "$HOME/.config/fleet/mode" 2>/dev/null || true)"
[ -z "$MODE" ] && MODE=server
case "$MODE" in server|client) ;; *) echo "install: mode must be 'server' or 'client' (got: $MODE)" >&2; exit 1 ;; esac

# fleet needs git, jq, tmux to exist — provisioning them (plus Tailscale + claude)
# is bootstrap/bootstrap.sh's job now, not the installer's. Fail clearly if the box
# hasn't been provisioned rather than limp on and break later.
_missing=""; for _d in git jq tmux; do command -v "$_d" >/dev/null 2>&1 || _missing="$_missing$_d "; done
if [ -n "$_missing" ]; then
  echo "install: missing core tools: ${_missing% }" >&2
  echo "  provision this box first:  $REPO/bootstrap/bootstrap.sh   (Tailscale + deps + claude)" >&2
  echo "  or install by hand:        sudo apt-get install -y ${_missing% }" >&2
  exit 1
fi

# --- pick the login shell's rc file ---
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc"; [ "$OS" = Darwin ] && RC="$HOME/.bash_profile" ;;
  *)    RC="$HOME/.profile" ;;
esac

add_line() { local f=$1 l=$2; touch "$f"; grep -qxF "$l" "$f" || printf '\n%s\n' "$l" >> "$f"; }

echo "installing fleet for $(id -un) on $OS, shell rc: $RC"
echo "  repo: $PREFIX"

# 1. record the repo location (shell-agnostic; used by `fleet remote` and fleet.bashrc)
mkdir -p "$HOME/.config/fleet"
printf '%s\n' "$PREFIX" > "$HOME/.config/fleet/home"
echo "  + ~/.config/fleet/home -> $PREFIX"

# 1b. the consolidated config: ~/.config/fleet/fleet.json (needs jq). Create it with
# sensible defaults (4 general scratch agents, no repos, no hosts) and this machine's
# mode + location; keep the roster on re-install and just refresh those two keys.
FJ="$HOME/.config/fleet/fleet.json"
LOC="${FLEET_LOCATION:-}"
[ -z "$LOC" ] && LOC="$(jq -r '.location // empty' "$FJ" 2>/dev/null)"
[ -z "$LOC" ] && LOC="$(cat "$HOME/.config/fleet/location" 2>/dev/null || true)"
[ -z "$LOC" ] && LOC=local
if ! command -v jq >/dev/null 2>&1; then
  echo "  ! jq not found — install it ($( [ "$OS" = Darwin ] && echo 'brew install jq' || echo 'sudo apt install jq' )) so fleet.json works"
elif [ -s "$FJ" ] && jq -e . "$FJ" >/dev/null 2>&1; then
  # keep an existing *valid* config, only refreshing mode+location; an empty or
  # corrupt file falls through to regenerate (don't "keep" garbage).
  T="$(mktemp)"; jq --arg m "$MODE" --arg l "$LOC" '.mode=$m | .location=$l' "$FJ" > "$T" && mv "$T" "$FJ"
  echo "  = $FJ kept (mode=$MODE, location=$LOC)"
else
  # migrate legacy hosts file (if any) into the new .hosts map
  HJ='{}'
  if [ -f "$HOME/.config/fleet/hosts" ]; then
    HJ="$(awk -F: '{sub(/#.*/,"")} /[^[:space:]]/ && /:/{gsub(/[[:space:]]/,"",$1);gsub(/[[:space:]]/,"",$2); if($1!="") printf "{\"%s\":\"%s\"}\n",$1,($2==""?$1:$2)}' "$HOME/.config/fleet/hosts" | jq -s 'add // {}')"
  fi
  jq -n --arg m "$MODE" --arg l "$LOC" --argjson h "$HJ" \
    '{mode:$m, location:$l, general:{count:4, chrome:true, remoteControl:false}, agents:{}, hosts:$h}' > "$FJ"
  echo "  + $FJ (mode=$MODE, location=$LOC, 4 general agents, no repos)"
fi

# 2. shell integration. When run from the single binary (FLEET_BUNDLED=1) the
# `fleet` command already lives on PATH, so sourcing the fleet.bashrc function would
# only SHADOW the binary with a stale cache path — skip it, just persist the
# location tag. Script installs still wire the function + FLEET_HOME.
if [ -n "${FLEET_BUNDLED:-}" ]; then
  [ -n "${FLEET_LOCATION:-}" ] && { add_line "$RC" "export FLEET_LOCATION=$FLEET_LOCATION"; echo "  + $RC exports FLEET_LOCATION=$FLEET_LOCATION"; }
  echo "  · bundled binary: 'fleet' is on PATH (no shell function wired)"
else
  add_line "$RC" "# fleet — Claude Code agent fleet"
  add_line "$RC" "export FLEET_HOME=$PREFIX"
  # Persist this machine's location tag when given: FLEET_LOCATION=laptop ./install.sh
  # names its agents <owner>-laptop-* instead of the default <owner>-local-*.
  [ -n "${FLEET_LOCATION:-}" ] && add_line "$RC" "export FLEET_LOCATION=$FLEET_LOCATION"
  add_line "$RC" "[ -r \$FLEET_HOME/shell/fleet.bashrc ] && . \$FLEET_HOME/shell/fleet.bashrc"
  echo "  + $RC sources the fleet command${FLEET_LOCATION:+ (location: $FLEET_LOCATION)}"
fi

# 3. tmux config. Bundled: copy to a STABLE path (the binary's cache dir changes
# every upgrade, which would leave ~/.tmux.conf sourcing a dead file). Script: point
# straight at the checkout.
if [ -n "${FLEET_BUNDLED:-}" ]; then
  cp "$PREFIX/tmux.conf" "$HOME/.config/fleet/tmux.conf"
  add_line "$HOME/.tmux.conf" "source-file $HOME/.config/fleet/tmux.conf"
  echo "  + ~/.tmux.conf sources ~/.config/fleet/tmux.conf"
else
  add_line "$HOME/.tmux.conf" "source-file $PREFIX/tmux.conf"
  echo "  + ~/.tmux.conf sources $PREFIX/tmux.conf"
fi

# 4. login auto-start — SERVER mode only. A client machine never runs local
# agents, so we install no autostart and clear any left by a prior server install.
# Launch via the single binary when bundled, else the script.
LAUNCH="${FLEET_BIN:-$PREFIX/bin/fleet.sh}"
if [ "$MODE" = server ]; then
  case "$OS" in
    Linux)
      AS="$HOME/.config/autostart/fleet.desktop"; mkdir -p "$(dirname "$AS")"
      sed "s#Exec=.*#Exec=$LAUNCH up#" "$REPO/autostart/fleet.desktop" > "$AS"
      echo "  + $AS (XDG autostart: 'fleet up' on graphical login)"
      ;;
    Darwin)
      PLIST="$HOME/Library/LaunchAgents/com.anivk.fleet.plist"; mkdir -p "$(dirname "$PLIST")"
      cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.anivk.fleet</string>
  <key>ProgramArguments</key><array>
    <string>$LAUNCH</string><string>up</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
      echo "  + $PLIST (launchd: 'fleet up' at login) — enable: launchctl load -w '$PLIST'"
      ;;
    *) echo "  ! unknown OS ($OS): skipping auto-start (fleet command still installed)" ;;
  esac

  # Wire Claude hooks so agents report status to the tray (best-effort).
  if command -v "$PREFIX/bin/fleet.sh" >/dev/null 2>&1 || [ -x "$PREFIX/bin/fleet.sh" ]; then
    FLEET_HOME="$PREFIX" "$PREFIX/bin/fleet.sh" install-hooks 2>/dev/null \
      && echo "  + Claude hooks wired (status/alerts/summaries)" \
      || echo "  ! hooks not wired (install jq, then: fleet install-hooks)"
  fi
else
  case "$OS" in
    Linux)  rm -f "$HOME/.config/autostart/fleet.desktop" ;;
    Darwin) PLIST="$HOME/Library/LaunchAgents/com.anivk.fleet.plist"
            [ -e "$PLIST" ] && { launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; } ;;
  esac
  echo "  · client mode: no local autostart (cleared any prior autostart entry)"
fi

# The tray lives inside the fleet binary now (`fleet tray start`). Bundled installs
# already have it; a script/dev checkout builds the binary with `go build -o fleet .`.
if [ -z "${FLEET_BUNDLED:-}" ] && command -v go >/dev/null 2>&1 && [ -f "$PREFIX/main.go" ]; then
  ( cd "$PREFIX" && go build -o fleet . ) \
    && echo "  + built ./fleet (run: fleet tray start)" \
    || echo "  ! fleet binary build failed (see: cd $PREFIX && go build -o fleet .)"
fi

echo
echo "done ($MODE mode). open a new shell (or 'source $RC'), then:"
if [ "$MODE" = server ]; then
  # claude is provisioned by bootstrap, not here — warn if the box wasn't bootstrapped.
  if ! command -v claude >/dev/null 2>&1; then
    echo "  ! claude not found — agents can't run. Provision it: fleet init server"
  fi
  # Auth is per-machine and interactive — not something the installer can do headlessly.
  command -v claude >/dev/null 2>&1 && echo "  claude login                         # authenticate Claude (or export ANTHROPIC_API_KEY)"
  command -v codex  >/dev/null 2>&1 && echo "  codex login                          # authenticate Codex (or export OPENAI_API_KEY)"
  echo "  fleet setup <owner>/<repo> [count]   # clone the repo agents into ~/co"
  echo "  fleet start                          # launch this machine's fleet"
else
  echo "  fleet remote <host>                  # attach a server machine's fleet"
  echo "  fleet update <host>                  # keep a server machine up to date"
fi
