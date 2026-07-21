#!/usr/bin/env bash
# bootstrap — provision a bare machine into a fleet-ready node. Batteries included:
# Tailscale (+ SSH), core deps (git, jq, tmux), the agent CLIs (Claude + Codex/Node),
# and a browser for --chrome agents — all by default. Extra tooling is config-driven:
# fleet.json's `install.deps` (e.g. az, aws, kubectl) is provisioned here too.
# Provisioning ONLY — it does NOT install fleet. After this: run install.sh (or
# `fleet remote-install <host>` from your laptop), then `claude login`.
#
#   bootstrap.sh [--authkey=tskey-…] [--no-codex] [--headless] [--no-extension] [--with-xvfb] [--with-rdp] [--no-claude]
#     defaults install codex+node, a browser, AND force-install the Claude-in-Chrome
#     extension. --no-codex / --headless / --no-extension opt out; --with-xvfb adds a
#     virtual display for headless --chrome; --with-rdp installs xrdp remote desktop.
#   TS_AUTHKEY=tskey-… bootstrap.sh            # non-interactive Tailscale auth
#   UPGRADE_CLIS=1 bootstrap.sh --clis-only    # just (re)install/upgrade the CLIs
set -euo pipefail
OS="$(uname -s)"
# the claude installer lands its CLI in ~/.local/bin, which isn't on a
# non-interactive SSH PATH — put it on so detection/upgrade work either way.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

# Batteries included: claude, codex (+ node), and a browser all install by DEFAULT.
# --no-codex / --headless / --no-claude opt out.
AUTHKEY="${TS_AUTHKEY:-}"; WANT_CLAUDE=1; WANT_CODEX=1; WANT_XVFB=0; WANT_CHROME=1; WANT_EXT=1; WANT_RDP=0; CLIS_ONLY=0
for a in "$@"; do
  case "$a" in
    --authkey=*)  AUTHKEY="${a#*=}" ;;
    --no-codex)   WANT_CODEX=0 ;;             # skip codex + node
    --with-codex) WANT_CODEX=1 ;;             # (default; kept for compat)
    --with-xvfb)  WANT_XVFB=1 ;;    # virtual display for --chrome agents (headless boot)
    --with-rdp)   WANT_RDP=1 ;;     # xrdp remote desktop (reach it over Tailscale)
    --headless|--no-chrome) WANT_CHROME=0 ;;  # skip the browser (true headless server)
    --with-chrome) WANT_CHROME=1 ;;           # (default; kept for compat)
    --no-extension) WANT_EXT=0 ;;             # skip the Claude-in-Chrome extension policy
    --auto-extension) WANT_EXT=1 ;;           # (default; kept for compat)
    --no-claude)  WANT_CLAUDE=0 ;;
    --clis-only)  CLIS_ONLY=1 ;;   # skip tailscale + system deps, only touch the CLIs
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "bootstrap: unknown arg: $a" >&2; exit 1 ;;
  esac
done
[ "$WANT_CHROME" = 0 ] && WANT_EXT=0   # no browser => no extension policy

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
# --- config-driven extras (fleet.json → install.deps) -----------------------------
# Can we actually escalate? A box without passwordless sudo, provisioned over SSH with
# no TTY, gets SUDO="sudo -n" — which fails on every install and would otherwise report
# a bare "could not install". Detect it once so the installers that CAN land in a
# user-local prefix (~/.local/bin is already on PATH, see the top of this file) do.
_can_sudo() { [ -z "$SUDO" ] && return 0; $SUDO true >/dev/null 2>&1; }
# Route a tool name to the right installer. The cloud CLIs each need a vendor path
# (none ships as a plain apt/dnf package), everything else is just a package name.
ensure_tool() {
  case "$1" in
    az)      ensure_az ;;
    aws)     ensure_aws ;;
    kubectl) ensure_kubectl ;;
    *)       ensure_dep "$1" ;;
  esac
}
# kubectl — official release binary (arch-aware); brew on macOS.
ensure_kubectl() {
  command -v kubectl >/dev/null 2>&1 && { echo "  = kubectl present"; return 0; }
  echo "  installing kubectl…"
  if command -v brew >/dev/null 2>&1; then brew install kubectl >/dev/null 2>&1 || true
  else
    local a v
    case "$(uname -m)" in x86_64|amd64) a=amd64 ;; arm64|aarch64) a=arm64 ;; *) a="" ;; esac
    v="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || true)"
    if [ -n "$a" ] && [ -n "$v" ] \
       && curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/$v/bin/linux/$a/kubectl" 2>/dev/null; then
      if _can_sudo; then $SUDO install -m 0755 /tmp/kubectl /usr/local/bin/kubectl >/dev/null 2>&1 || true
      else mkdir -p "$HOME/.local/bin"
           install -m 0755 /tmp/kubectl "$HOME/.local/bin/kubectl" >/dev/null 2>&1 || true; fi
      rm -f /tmp/kubectl
    fi
  fi
  command -v kubectl >/dev/null 2>&1 && echo "  + kubectl installed" \
    || echo "  ! could not install kubectl — see https://kubernetes.io/docs/tasks/tools/"
}
# aws — CLI v2 ships only as a zipped installer on Linux (no distro package).
ensure_aws() {
  command -v aws >/dev/null 2>&1 && { echo "  = aws present"; return 0; }
  echo "  installing aws cli…"
  if command -v brew >/dev/null 2>&1; then brew install awscli >/dev/null 2>&1 || true
  else
    local m
    case "$(uname -m)" in x86_64|amd64) m=x86_64 ;; arm64|aarch64) m=aarch64 ;; *) m="" ;; esac
    command -v unzip >/dev/null 2>&1 || ensure_dep unzip
    if [ -n "$m" ] && command -v unzip >/dev/null 2>&1; then
      if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$m.zip" -o /tmp/awscliv2.zip 2>/dev/null \
         && unzip -q -o /tmp/awscliv2.zip -d /tmp >/dev/null 2>&1; then
        # v2's installer takes an explicit prefix, so a no-root box still gets a real aws.
        if _can_sudo; then $SUDO /tmp/aws/install --update >/dev/null 2>&1 || true
        else /tmp/aws/install --update -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" >/dev/null 2>&1 || true; fi
      fi
      rm -rf /tmp/awscliv2.zip /tmp/aws
    fi
  fi
  command -v aws >/dev/null 2>&1 && echo "  + aws installed" \
    || echo "  ! could not install aws — see https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
}
# az — Microsoft's own apt/dnf repo installer (their documented path).
ensure_az() {
  command -v az >/dev/null 2>&1 && { echo "  = az present"; return 0; }
  echo "  installing azure cli…"
  if command -v brew >/dev/null 2>&1; then brew install azure-cli >/dev/null 2>&1 || true
  elif ! _can_sudo; then
    # Unlike kubectl/aws there's no supported user-local install — say so instead of
    # reporting a generic failure the operator can't act on.
    echo "  ! az needs root and this run has no sudo. On the box, run:"
    echo "      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
    return 0
  elif command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://aka.ms/InstallAzureCLIDeb 2>/dev/null | $SUDO bash >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y azure-cli >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm azure-cli >/dev/null 2>&1 || true
  fi
  command -v az >/dev/null 2>&1 && echo "  + az installed" \
    || echo "  ! could not install az — see https://learn.microsoft.com/cli/azure/install-azure-cli"
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
# Xvfb — a virtual X display so --chrome browser agents (Chrome + the Claude Code
# extension) run with nobody logged in (headless server + `fleet boot --xvfb`).
# Binary is `Xvfb`; package name varies by distro.
ensure_xvfb() {
  command -v Xvfb >/dev/null 2>&1 && { echo "  = Xvfb present"; return 0; }
  echo "  installing xvfb (virtual display for browser agents)…"
  if command -v apt-get >/dev/null 2>&1; then
    [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
    $SUDO apt-get install -y xvfb >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y xorg-x11-server-Xvfb >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y xorg-x11-server-Xvfb >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm xorg-server-xvfb >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then $SUDO apk add xvfb >/dev/null 2>&1 || true
  fi
  command -v Xvfb >/dev/null 2>&1 && echo "  + xvfb installed" || echo "  ! could not install xvfb — install your distro's Xvfb package"
}
# A Chromium-based browser for --chrome agents. Google Chrome where available (amd64
# Linux via Google's .deb; macOS via brew cask), else Chromium. NOTE: the "Claude in
# Chrome" extension is a Web Store install you do once in the browser by hand — this
# only provides the browser.
_have_browser() { for b in google-chrome google-chrome-stable chromium chromium-browser; do command -v "$b" >/dev/null 2>&1 && return 0; done; return 1; }
ensure_chrome() {
  _have_browser && { echo "  = browser present"; return 0; }
  echo "  installing a browser for --chrome agents…"
  if [ "$OS" = Darwin ]; then
    command -v brew >/dev/null 2>&1 && brew install --cask google-chrome >/dev/null 2>&1 || echo "  ! install Chrome from https://google.com/chrome"
  elif command -v apt-get >/dev/null 2>&1; then
    if [ "$(uname -m)" = x86_64 ]; then
      local deb; deb="$(mktemp)"; mv "$deb" "$deb.deb"; deb="$deb.deb"
      if curl -fsSL -o "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb 2>/dev/null; then
        $SUDO apt-get install -y "$deb" >/dev/null 2>&1 || { $SUDO dpkg -i "$deb" >/dev/null 2>&1; $SUDO apt-get -f install -y >/dev/null 2>&1; }
      fi
      rm -f "$deb"
    fi
    # arm64, or if Chrome didn't land: Chromium (deb, else snap)
    _have_browser || $SUDO apt-get install -y chromium >/dev/null 2>&1 || $SUDO apt-get install -y chromium-browser >/dev/null 2>&1 \
      || { command -v snap >/dev/null 2>&1 && $SUDO snap install chromium >/dev/null 2>&1; } || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y google-chrome-stable >/dev/null 2>&1 || $SUDO dnf install -y chromium >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm chromium >/dev/null 2>&1 || true
  fi
  _have_browser && echo "  + browser installed" || echo "  ! could not install a browser — install Chrome/Chromium manually"
}
# Remote desktop over Tailscale (RDP :3389). Modern GNOME (49+) is Wayland-only and xrdp is
# Xorg-only, so xrdp CANNOT serve GNOME; use gnome-remote-desktop (GNOME's own RDP). Fall
# back to xrdp + xfce only where there's no GNOME. Over Tailscale we allow :3389 on the
# tailnet only. CRITICAL: the RDP *client* must set 'use redirection server name:i:1' or
# grd remote-login's server redirection never completes (session drops, LOGOFF_BY_USER) —
# _ensure_grd writes a ready .rdp carrying that flag, since the client GUI hides it.
ensure_rdp() {
  [ "$OS" = Linux ] || { echo "  · --with-rdp: Linux only"; return 0; }
  if command -v gnome-shell >/dev/null 2>&1; then
    _ensure_grd && { _rdp_ufw; return 0; }
    echo "  · gnome-remote-desktop unavailable — falling back to xrdp + xfce"
  fi
  _ensure_xrdp; _rdp_ufw
}

# Open RDP on the tailnet only (never a public port); no-op if ufw is inactive/absent.
_rdp_ufw() {
  command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qiw active || return 0
  $SUDO ufw allow in on tailscale0 to any port 3389 proto tcp >/dev/null 2>&1 \
    || $SUDO ufw allow 3389/tcp >/dev/null 2>&1 || true
}

# Write a ready-to-open .rdp for the client. The macOS/Windows RDP client MUST carry
# 'use redirection server name:i:1' — without it grd remote-login's server redirection
# never completes and the session drops (LOGOFF_BY_USER). The client GUI hides this flag,
# so fleet ships a file with it (+ the box's Tailscale FQDN so the redirected reconnect
# resolves). scp it to your Mac and open it.
_rdp_client_file() {
  local fqdn rdp; fqdn="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//')"
  [ -n "$fqdn" ] || fqdn="$(hostname)"
  mkdir -p "$HOME/.config/fleet"
  rdp="$HOME/.config/fleet/$(hostname).rdp"
  cat > "$rdp" <<RDP
full address:s:${fqdn}:3389
use redirection server name:i:1
enablecredsspsupport:i:1
authentication level:i:2
allowed security protocols:s:*
username:s:$(id -un)
prompt for credentials on client:i:1
networkautodetect:i:1
bandwidthautodetect:i:1
connection type:i:7
screen mode id:i:2
dynamic resolution:i:1
redirectclipboard:i:1
session bpp:i:32
RDP
  echo "  + RDP client file → $rdp"
  echo "    on your Mac:  scp $(id -un)@${fqdn}:.config/fleet/$(hostname).rdp ~/Downloads/ && open ~/Downloads/$(hostname).rdp"
}

# gnome-remote-desktop in --system "remote login" mode: RDP straight into a real, headless
# GNOME session (works with Wayland-only GNOME). Returns non-zero if grd can't be set up.
_ensure_grd() {
  if ! command -v grdctl >/dev/null 2>&1; then
    echo "  installing gnome-remote-desktop…"
    command -v apt-get >/dev/null 2>&1 && { [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }; \
      $SUDO apt-get install -y gnome-remote-desktop >/dev/null 2>&1 || true; }
  fi
  command -v grdctl >/dev/null 2>&1 || return 1
  # gnome-shell can segfault in libmutter-cogl on some GPUs (amdgpu/mesa) with an
  # out-of-date mutter, leaving the RDP session black — pull the latest mutter/gnome-shell.
  if command -v apt-get >/dev/null 2>&1; then
    [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade 'libmutter-*' gnome-shell mutter-common >/dev/null 2>&1 || true
  fi
  local dir=/etc/gnome-remote-desktop crt=/etc/gnome-remote-desktop/rdp-tls.crt key=/etc/gnome-remote-desktop/rdp-tls.key
  if ! $SUDO test -f "$crt"; then          # grd requires a TLS cert; self-sign one
    $SUDO mkdir -p "$dir"
    $SUDO openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=$(hostname)" -keyout "$key" -out "$crt" >/dev/null 2>&1 || true
  fi
  # grd's daemon runs unprivileged (User=gnome-remote-desktop); openssl made the key
  # root:root 600, which it can't read → "TLS not configured properly". Hand both to it.
  local grd_user; grd_user="$($SUDO systemctl show gnome-remote-desktop.service -p User --value 2>/dev/null)"
  [ -n "$grd_user" ] && $SUDO chown "$grd_user" "$crt" "$key" 2>/dev/null || true
  # RDP-layer password. Skip the prompt entirely on re-runs when credentials are already
  # set — unless RDP_PASSWORD is given explicitly to rotate them.
  local rpass="${RDP_PASSWORD:-}"
  if [ -z "$rpass" ] && $SUDO grdctl --system status 2>/dev/null | grep -i 'Username:' | grep -qv '(empty)'; then
    echo "  = RDP credentials already set — keeping them (RDP_PASSWORD=… to rotate)"
  elif [ -z "$rpass" ] && [ -t 0 ]; then
    printf "  set an RDP password for %s (blank to skip): " "$(id -un)"; stty -echo 2>/dev/null; read -r rpass; stty echo 2>/dev/null; echo
  fi
  $SUDO grdctl --system rdp set-tls-cert "$crt" >/dev/null 2>&1 || true
  $SUDO grdctl --system rdp set-tls-key  "$key" >/dev/null 2>&1 || true
  [ -n "$rpass" ] && $SUDO grdctl --system rdp set-credentials "$(id -un)" "$rpass" >/dev/null 2>&1 || true
  $SUDO grdctl --system rdp disable-view-only >/dev/null 2>&1 || true   # allow remote control
  $SUDO grdctl --system rdp enable >/dev/null 2>&1 || true
  $SUDO systemctl enable gnome-remote-desktop.service >/dev/null 2>&1 || true
  $SUDO systemctl restart gnome-remote-desktop.service >/dev/null 2>&1 || true   # apply cert/creds on re-runs
  # Retire xrdp/xfce if a prior run installed them (they'd fight grd for :3389).
  command -v xrdp >/dev/null 2>&1 && $SUDO systemctl disable --now xrdp xrdp-sesman >/dev/null 2>&1 || true
  rm -f "$HOME/.xsession" 2>/dev/null || true
  echo "  + gnome-remote-desktop on :3389 — RDP the real GNOME desktop over Tailscale (login: $(id -un))"
  [ -z "$rpass" ] && echo "    ! no RDP password set — run: sudo grdctl --system rdp set-credentials $(id -un) <password>"
  _rdp_client_file
  return 0
}

# Fallback for non-GNOME boxes: xrdp + a lightweight xfce X11 session.
_ensure_xrdp() {
  if command -v xrdp >/dev/null 2>&1; then echo "  = xrdp present"; else
    echo "  installing xrdp (remote desktop on :3389)…"
    if command -v apt-get >/dev/null 2>&1; then
      [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
      $SUDO apt-get install -y xrdp >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y xrdp >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm xrdp >/dev/null 2>&1 || true
    fi
  fi
  command -v xrdp >/dev/null 2>&1 || { echo "  ! could not install xrdp"; return 1; }
  $SUDO adduser xrdp ssl-cert >/dev/null 2>&1 || true
  # A remote xrdp session isn't "console", so Xorg's allowed_users=console kills its X
  # server ("Xorg server closed connection"). Let any user start X.
  if [ -f /etc/X11/Xwrapper.config ]; then
    $SUDO sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config
    grep -q '^needs_root_rights=' /etc/X11/Xwrapper.config \
      && $SUDO sed -i 's/^needs_root_rights=.*/needs_root_rights=yes/' /etc/X11/Xwrapper.config \
      || echo 'needs_root_rights=yes' | $SUDO tee -a /etc/X11/Xwrapper.config >/dev/null
  else
    printf 'allowed_users=anybody\nneeds_root_rights=yes\n' | $SUDO tee /etc/X11/Xwrapper.config >/dev/null
  fi
  if ! command -v startxfce4 >/dev/null 2>&1; then
    echo "  installing xfce4 (a reliable X11 desktop for xrdp)…"
    if command -v apt-get >/dev/null 2>&1; then
      [ -z "$_pm_updated" ] && { $SUDO apt-get update >/dev/null 2>&1 || true; _pm_updated=1; }
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4 dbus-x11 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y @xfce dbus-x11 >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -S --noconfirm xfce4 >/dev/null 2>&1 || true
    fi
  fi
  command -v startxfce4 >/dev/null 2>&1 && printf 'startxfce4\n' > "$HOME/.xsession"   # xrdp runs ~/.xsession
  $SUDO systemctl enable --now xrdp >/dev/null 2>&1 || true
  $SUDO systemctl restart xrdp >/dev/null 2>&1 || true
  echo "  + xrdp on :3389 — RDP to this box's Tailscale name/IP (xfce desktop)"
}
# Force-install the "Claude in Chrome" extension via Chrome's ExtensionInstallForcelist
# enterprise policy — Chrome auto-installs it on launch, no Web Store click. Undocumented
# for this extension (a generic Chrome capability); the one-time connect may still need a
# click. Linux only; needs sudo (writes /etc policy).
_EXT_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
ensure_extension_policy() {
  if [ "$OS" != Linux ]; then echo "  · auto-extension: Linux only — install the extension manually in the browser"; return 0; fi
  local body wrote=0 d
  body="{ \"ExtensionInstallForcelist\": [\"${_EXT_ID};https://clients2.google.com/service/update2/crx\"] }"
  # write the policy for whichever browser(s) are present
  command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 \
    && { d=/etc/opt/chrome/policies/managed; $SUDO mkdir -p "$d" 2>/dev/null && printf '%s\n' "$body" | $SUDO tee "$d/claude-fleet.json" >/dev/null 2>&1 && wrote=1; }
  if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
    for d in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
      $SUDO mkdir -p "$d" 2>/dev/null && printf '%s\n' "$body" | $SUDO tee "$d/claude-fleet.json" >/dev/null 2>&1 && wrote=1
    done
  fi
  if [ "$wrote" = 1 ]; then
    echo "  + Claude-in-Chrome extension policy installed (force-installs on next Chrome launch)"
  else
    echo "  ! couldn't write the extension policy (needs sudo, or no browser found) — install it from the Web Store"
  fi
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
        codex)  { command -v npm >/dev/null 2>&1 && $SUDO npm update -g @openai/codex >/dev/null 2>&1; } \
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
      { command -v npm >/dev/null 2>&1 && $SUDO npm install -g @openai/codex >/dev/null 2>&1; } \
        || { command -v brew >/dev/null 2>&1 && brew install codex >/dev/null 2>&1; } || true ;;
    *) echo "  ? unknown cli: $c"; return 0 ;;
  esac
  if command -v "$c" >/dev/null 2>&1; then echo "  + $c installed"
  else echo "  ! could not install $c — install it manually (codex needs node/npm, or brew)"; fi
}
# The claude/codex CLIs land in ~/.local/bin. Their installer adds that to ~/.profile
# (login shells only), so `claude`/`codex` are "command not found" in a plain non-login
# shell or a new tmux pane. Add it to the interactive rc too.
ensure_local_bin_path() {
  case "$OS/${SHELL##*/}" in Darwin/*) return 0 ;; esac
  local rc; case "${SHELL##*/}" in zsh) rc="$HOME/.zshrc" ;; *) rc="$HOME/.bashrc" ;; esac
  [ -f "$rc" ] || touch "$rc"
  grep -q '\.local/bin' "$rc" 2>/dev/null && { echo "  = ~/.local/bin already on PATH ($rc)"; return 0; }
  printf '\n# fleet: agent CLIs live in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
  echo "  + $rc: added ~/.local/bin to PATH (open a new shell or 'source $rc')"
}
# Device/browser login for a CLI — interactive only (needs a terminal to show the
# prompt); skipped when already authed or run unattended.
_login() {
  local c=$1 authed=0 logincmd
  command -v "$c" >/dev/null 2>&1 || return 0
  case "$c" in
    claude) logincmd="claude login"
            { [ -f "$HOME/.claude/.credentials.json" ] || grep -qs oauthAccount "$HOME/.claude.json" 2>/dev/null || [ -n "${ANTHROPIC_API_KEY:-}" ]; } && authed=1 ;;
    codex)  logincmd="codex login --device-auth"   # device code — works over SSH, no local browser
            { codex login status 2>&1 | grep -qiE 'logged in (using|with|as|via)' || [ -n "${OPENAI_API_KEY:-}" ]; } && authed=1 ;;
  esac
  [ "$authed" = 1 ] && { echo "  = $c already logged in"; return 0; }
  [ -t 0 ] || { echo "  · $c not logged in — run: $logincmd"; return 0; }
  echo "  → $logincmd   (approve the prompt it prints)"
  $logincmd || echo "  ! $c login didn't finish — run: $logincmd"
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
  # 2b. extra tooling from fleet.json → install.deps (jq is in place by now). Absent
  # config (a bare box, pre-install.sh) simply means no extras — re-running init or
  # `fleet config push` + init picks them up later.
  _fj="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/fleet.json"
  if command -v jq >/dev/null 2>&1 && [ -r "$_fj" ]; then
    for _d in $(jq -r '(.install.deps // []) | .[]' "$_fj" 2>/dev/null); do ensure_tool "$_d"; done
  fi
  [ "$WANT_XVFB" = 1 ] && ensure_xvfb
  [ "$WANT_RDP" = 1 ] && ensure_rdp
  [ "$WANT_CHROME" = 1 ] && ensure_chrome
  [ "$WANT_EXT" = 1 ] && ensure_extension_policy
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

# 4. PATH fix
ensure_local_bin_path

# Everything is installed — print the summary, THEN log in as the final step (so the
# interactive auth prompt never interrupts the install).
echo
echo "bootstrap done."
if [ "$WANT_CHROME" = 1 ] && [ "$WANT_EXT" = 1 ]; then
  echo "  --chrome: extension force-installs on next Chrome launch (desktop); then run"
  echo "            'claude --chrome' once — approve the connect prompt if it appears."
elif [ "$WANT_CHROME" = 1 ]; then
  echo "  --chrome: open the browser (needs a desktop), install the 'Claude in Chrome'"
  echo "            extension from the Web Store, then run 'claude --chrome' once to connect."
fi
echo "  install fleet:  <fleet-repo>/install.sh   (or: fleet remote-install <host> from your laptop)"

# 5. Auth — LAST, after all installation + the summary.
if [ "$WANT_CLAUDE" = 1 ] || [ "$WANT_CODEX" = 1 ]; then
  echo
  echo "logging in the agent CLIs:"
  [ "$WANT_CLAUDE" = 1 ] && _login claude
  [ "$WANT_CODEX" = 1 ]  && _login codex
fi
