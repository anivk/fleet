#!/usr/bin/env bash
# bootstrap — provision a bare machine into a fleet-ready node: Tailscale (+ SSH),
# the core deps (git, jq, tmux), and the Claude Code CLI (Node + Codex on request).
# Provisioning ONLY — it does NOT install fleet. After this: run install.sh (or
# `fleet remote-install <host>` from your laptop), then `claude login`.
#
#   bootstrap.sh [--authkey=tskey-…] [--with-codex] [--no-claude]
#   TS_AUTHKEY=tskey-… bootstrap.sh            # non-interactive Tailscale auth
#   UPGRADE_CLIS=1 bootstrap.sh --clis-only    # just (re)install/upgrade the CLIs
set -euo pipefail
OS="$(uname -s)"
# the claude installer lands its CLI in ~/.local/bin, which isn't on a
# non-interactive SSH PATH — put it on so detection/upgrade work either way.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

AUTHKEY="${TS_AUTHKEY:-}"; WANT_CLAUDE=1; WANT_CODEX=0; CLIS_ONLY=0
for a in "$@"; do
  case "$a" in
    --authkey=*)  AUTHKEY="${a#*=}" ;;
    --with-codex) WANT_CODEX=1 ;;
    --no-claude)  WANT_CLAUDE=0 ;;
    --clis-only)  CLIS_ONLY=1 ;;   # skip tailscale + system deps, only touch the CLIs
    -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "bootstrap: unknown arg: $a" >&2; exit 1 ;;
  esac
done

# sudo escalation. Root: none. TTY (run interactively): prime sudo once so its
# password prompt happens up front and the quiet installs reuse the credential.
# No TTY (unattended): `sudo -n` so a prompt can never hang the run.
SUDO=""
if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
  if [ -t 0 ]; then
    echo "(may prompt for sudo to install system packages)"
    if sudo -v; then SUDO="sudo"; else SUDO="sudo -n"; fi
  else
    SUDO="sudo -n"
  fi
fi

# --- package helpers (best-effort; `|| true` so a failed sudo/install never aborts
# under set -e — we check success and report it, then continue) ---
_pm_updated=""
ensure_dep() {
  command -v "$1" >/dev/null 2>&1 && { echo "  = $1 present"; return 0; }
  echo "  installing $1…"
  if command -v brew >/dev/null 2>&1; then brew install "$1" >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
    $SUDO apt-get install -y "$1" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y "$1" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y "$1" >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then $SUDO apk add "$1" >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm "$1" >/dev/null 2>&1 || true
  fi
  if command -v "$1" >/dev/null 2>&1; then echo "  + $1 installed"
  else echo "  ! could not install $1 — needs passwordless sudo, or run: <pkg-mgr> install $1"; fi
}
ensure_node() {
  command -v npm >/dev/null 2>&1 && { echo "  = node present"; return 0; }
  echo "  installing node (for codex)…"
  if command -v brew >/dev/null 2>&1; then brew install node >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
    $SUDO apt-get install -y nodejs npm >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y nodejs npm >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y nodejs npm >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then $SUDO apk add nodejs npm >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm nodejs npm >/dev/null 2>&1 || true
  fi
  command -v npm >/dev/null 2>&1 && echo "  + node installed" || echo "  ! could not install node — install node/npm for codex"
}
# Install, or (with UPGRADE_CLIS set) upgrade, an agent CLI. claude: native script /
# self-update. codex: npm, else brew if present (we never auto-install brew).
install_cli() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    if [ -n "${UPGRADE_CLIS:-}" ]; then
      echo "  upgrading ${c}…"
      case "$c" in
        claude) claude update >/dev/null 2>&1 || true ;;
        codex)  { command -v npm >/dev/null 2>&1 && npm update -g @openai/codex >/dev/null 2>&1; } \
                  || { command -v brew >/dev/null 2>&1 && brew upgrade codex >/dev/null 2>&1; } || true ;;
      esac
      echo "  = $c $("$c" --version 2>/dev/null | head -1)"
    else
      echo "  = $c already installed"
    fi
    return 0
  fi
  case "$c" in
    claude)
      echo "  installing Claude Code…"
      curl -fsSL https://claude.ai/install.sh 2>/dev/null | bash >/dev/null 2>&1 \
        || { command -v npm >/dev/null 2>&1 && npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; } || true ;;
    codex)
      ensure_node
      echo "  installing Codex…"
      { command -v npm >/dev/null 2>&1 && npm install -g @openai/codex >/dev/null 2>&1; } \
        || { command -v brew >/dev/null 2>&1 && brew install codex >/dev/null 2>&1; } || true ;;
    *) echo "  ? unknown cli: $c"; return 0 ;;
  esac
  if command -v "$c" >/dev/null 2>&1; then echo "  + $c installed"
  else echo "  ! could not install $c — install it manually (codex needs node/npm, or brew)"; fi
}

if [ "$CLIS_ONLY" = 0 ]; then
  echo "bootstrap: provisioning $(id -un) on $OS"

  # 1. Tailscale (+ SSH). An auth key makes `up` non-interactive; without one we
  #    install it and tell you the one interactive command to run.
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "  installing tailscale…"
    if [ "$OS" = Darwin ]; then
      command -v brew >/dev/null 2>&1 && brew install tailscale >/dev/null 2>&1 \
        || echo "  ! install Tailscale from https://tailscale.com/download"
    else
      curl -fsSL https://tailscale.com/install.sh 2>/dev/null | $SUDO sh >/dev/null 2>&1 \
        || echo "  ! tailscale install failed — see https://tailscale.com/download"
    fi
  fi
  if command -v tailscale >/dev/null 2>&1; then
    if [ -n "$AUTHKEY" ]; then
      $SUDO tailscale up --ssh --authkey="$AUTHKEY" >/dev/null 2>&1 \
        && echo "  + tailscale up (--ssh, authkey)" || echo "  ! 'tailscale up' failed (check the auth key)"
    elif tailscale status >/dev/null 2>&1; then
      echo "  = tailscale already up"
    else
      echo "  · tailscale installed — bring it up (interactive): sudo tailscale up --ssh"
    fi
  fi

  # 2. core deps
  for _d in git jq tmux; do ensure_dep "$_d"; done
  _missing=""; for _d in git jq tmux; do command -v "$_d" >/dev/null 2>&1 || _missing="$_missing $_d"; done
  [ -n "$_missing" ] && echo "  !! still missing:$_missing — run: sudo apt-get install -y$_missing"
fi

# 3. agent CLIs
if [ "$CLIS_ONLY" = 1 ]; then
  # update mode: upgrade only what's already installed, don't newly install codex
  command -v claude >/dev/null 2>&1 && install_cli claude
  command -v codex  >/dev/null 2>&1 && install_cli codex
  exit 0
fi
[ "$WANT_CODEX" = 1 ] && ensure_node
[ "$WANT_CLAUDE" = 1 ] && install_cli claude
[ "$WANT_CODEX" = 1 ] && install_cli codex

echo
echo "bootstrap done. next:"
[ "$WANT_CLAUDE" = 1 ] && echo "  claude login                 # authenticate (device flow; or export ANTHROPIC_API_KEY)"
[ "$WANT_CODEX" = 1 ]  && echo "  codex login                  # authenticate (or export OPENAI_API_KEY)"
echo "  install fleet:  <fleet-repo>/install.sh   (or: fleet remote-install <host> from your laptop)"
