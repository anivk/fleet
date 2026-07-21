#!/usr/bin/env bash
# Fleet launcher: one Claude Code session per workspace, inside tmux.
#
#   ./fleet.sh setup <owner>/<repo> [count]   clone N copies + save the roster
#   ./fleet.sh update [host]   git-pull latest + re-wire (or a remote over tailscale)
#   ./fleet.sh start     launch every agent that isn't already running
#   ./fleet.sh attach    attach to the tmux session
#   ./fleet.sh status    what's alive, per window
#   ./fleet.sh stop      kill the whole fleet
#   ./fleet.sh restart <name>   respawn one agent
#
# Each agent is a tmux window named after its workspace, running an
# interactive `claude` session named for its workspace; tmux lets you attach
# locally. Remote Control (claude.ai/code) is opt-in via FLEET_REMOTE_CONTROL=1.

set -euo pipefail

# Agent CLIs (claude, codex) commonly install under ~/.local/bin, which is NOT on
# the PATH of a non-interactive `ssh host <cmd>` (no login rc is sourced). Prepend
# it so fleet finds them however it's invoked — doctor, agent launch, respawn,
# remote commands — and so the agents fleet spawns inherit it too. Idempotent.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

# Self-locate the repo root so the script works when invoked directly (launchd /
# XDG autostart don't source the shell RC that normally exports FLEET_HOME).
FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SESSION="${FLEET_TMUX_SESSION:-fleet}"
CO_DIR="${FLEET_CO_DIR:-$HOME/co}"   # each user's own workspaces
CLAUDE="${FLEET_CLAUDE_BIN:-claude}"
CODEX="${FLEET_CODEX_BIN:-codex}"   # used by agents whose harness is "codex"
# Every agent's display + remote-control name is namespaced <owner>-<location>-<name>
# (e.g. my-nyc-space-1, webserver-nyc-agent-A), so on a shared box you can tell
# whose fleet an agent belongs to and where it's based. OWNER auto-derives from
# whoever runs the script, so the same fleet.sh namespaces correctly per user, no per-
# user edits. Workspace dirs stay unprefixed — the
# namespace belongs in the name, not the path.
OWNER="${FLEET_OWNER:-$(id -un)}"
_cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/fleet"
# The consolidated config. Everything (roster, hosts, mode, location) lives here as
# JSON; `fleet.json` is the source of truth. Requires jq. If it's absent we fall
# back to the legacy per-file config so existing installs keep working.
FLEET_JSON="${FLEET_JSON:-$_cfgdir/fleet.json}"
STATE_DIR="$_cfgdir/state"
FLEET_STATE_TTL="${FLEET_STATE_TTL:-900}"   # state files older than this ⇒ scrape
# Pin the tmux socket to a fixed path so `fleet` reaches the SAME server from any login
# context. A bare `tmux` derives its socket dir from the ambient TMUX_TMPDIR/XDG_RUNTIME_DIR,
# which differ between console, RDP/xfce and ssh sessions — so a running fleet looked "not
# running" from a different shell. /tmp is one fixed global path in every context; keep it
# short too (AF_UNIX caps socket paths at ~104 chars). Route every tmux call through this
# wrapper; `exec tmux` sites pass -S explicitly (exec bypasses shell functions).
TMUX_SOCK="${FLEET_TMUX_SOCK:-/tmp/fleet-$(id -u).sock}"
# tmux refuses to start or attach when $TERM has no terminfo entry on THIS host — common
# over ssh from Ghostty/Kitty/WezTerm to a box that lacks their terminfo ("missing or
# unsuitable terminal: xterm-ghostty"). Resolve a TERM that exists here, keeping the real
# one when present (full fidelity) and falling back to xterm-256color otherwise so fleet
# still works. Install the real terminfo for fidelity: infocmp -x $TERM | ssh <host> 'tic -x -'
if [ -n "${TERM:-}" ] && command -v infocmp >/dev/null 2>&1 && infocmp "$TERM" >/dev/null 2>&1; then
  FLEET_TERM="$TERM"
else
  FLEET_TERM="${FLEET_TERM:-xterm-256color}"
fi
tmux() { TERM="$FLEET_TERM" command tmux -S "$TMUX_SOCK" "$@"; }
_LETTERS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# Roster + per-agent settings as parallel indexed arrays (bash-3.2 safe). An agent
# with a repo is a cloned workspace; without one it's a scratch agent (empty folder
# it owns and can clear). mode is per-machine, so `fleet config push` never ships it.
AGENTS=(); A_REPO=(); A_CHROME=(); A_RC=(); A_MODEL=(); A_PMODE=(); A_HARNESS=(); FLEET_HOSTS=()
_add_agent() { AGENTS+=("$1"); A_REPO+=("$2"); A_CHROME+=("$3"); A_RC+=("$4"); A_MODEL+=("$5"); A_PMODE+=("$6"); A_HARNESS+=("$7"); }
# Fleet-wide launch defaults, overridable per-agent (or the general tier) in fleet.json.
# harness picks the CLI that runs in the pane: claude (default) or codex. The model
# default is per-harness — opus for claude, gpt-5-codex for codex.
_DEF_MODEL="opus"; _DEF_MODEL_CODEX="gpt-5-codex"; _DEF_PMODE="bypassPermissions"; _DEF_HARNESS="claude"

if command -v jq >/dev/null 2>&1 && [[ -r "$FLEET_JSON" ]]; then
  MODE="${FLEET_MODE:-$(jq -r '.mode // "server"' "$FLEET_JSON")}"
  LOCATION="${FLEET_LOCATION:-$(jq -r '.location // "local"' "$FLEET_JSON")}"
  _dm="${FLEET_MODEL:-$(jq -r --arg d "$_DEF_MODEL" '.model // $d' "$FLEET_JSON")}"    # claude-side default
  _dp="${FLEET_PERMISSION_MODE:-$(jq -r --arg d "$_DEF_PMODE" '.permissionMode // $d' "$FLEET_JSON")}"
  _dh="$(jq -r --arg d "$_DEF_HARNESS" '.harness // $d' "$FLEET_JSON")"
  # general scratch agents
  _gc="$(jq -r '.general.count // 0' "$FLEET_JSON")"
  _gch="$(jq -r 'if (.general.chrome == false) then "false" else "true" end' "$FLEET_JSON")"
  _grc="$(jq -r 'if (.general.remoteControl == true) then "true" else "false" end' "$FLEET_JSON")"
  _gp="$(jq -r --arg d "$_dp" '.general.permissionMode // $d' "$FLEET_JSON")"
  _gh="$(jq -r --arg d "$_dh" '.general.harness // $d' "$FLEET_JSON")"
  _gm="$(jq -r --arg mcl "$_dm" --arg mc "$_DEF_MODEL_CODEX" --arg dh "$_dh" '.general.model // (if (.general.harness // $dh) == "codex" then $mc else $mcl end)' "$FLEET_JSON")"
  for ((_i = 0; _i < _gc; _i++)); do _add_agent "agent-${_LETTERS:$_i:1}" "" "$_gch" "$_grc" "$_gm" "$_gp" "$_gh"; done
  # named agents (repo optional → scratch when absent), each fully self-describing.
  # '|' delimiter, not tab — tab is IFS-whitespace and would collapse empty fields.
  while IFS='|' read -r _n _repo _ch _rc _model _pmode _h; do
    [[ -n "$_n" ]] && _add_agent "$_n" "$_repo" "$_ch" "$_rc" "$_model" "$_pmode" "$_h"
  done < <(jq -r --arg dp "$_dp" --arg dh "$_dh" --arg mcl "$_dm" --arg mc "$_DEF_MODEL_CODEX" '(.agents // {}) | to_entries[] | [ .key, (.value.repo // ""),
             (if (.value.chrome == false) then "false" else "true" end),
             (if (.value.remoteControl == true) then "true" else "false" end),
             (.value.model // (if (.value.harness // $dh) == "codex" then $mc else $mcl end)),
             (.value.permissionMode // $dp),
             (.value.harness // $dh) ] | join("|")' "$FLEET_JSON")
  # hosts map: short -> tailscale hostname
  while IFS='|' read -r _s _h; do [[ -n "$_s" ]] && FLEET_HOSTS+=("$_s:$_h"); done \
    < <(jq -r '(.hosts // {}) | to_entries[] | [.key, .value] | join("|")' "$FLEET_JSON")
else
  # --- legacy per-file fallback (until this machine has fleet.json) ---
  LOCATION="${FLEET_LOCATION:-$(cat "$_cfgdir/location" 2>/dev/null || echo local)}"
  MODE="${FLEET_MODE:-$(cat "$_cfgdir/mode" 2>/dev/null || echo server)}"
  # shellcheck source=/dev/null
  [[ -r "$_cfgdir/config" ]] && . "$_cfgdir/config"
  _lrc=false; [[ "${FLEET_REMOTE_CONTROL:-0}" == 1 ]] && _lrc=true
  _dm="${FLEET_MODEL:-$_DEF_MODEL}"; _dp="${FLEET_PERMISSION_MODE:-$_DEF_PMODE}"
  for _a in A B C D; do _add_agent "agent-$_a" "" true "$_lrc" "$_dm" "$_dp" claude; done
  if [[ -n "${FLEET_REPO_SPEC:-}" && "${FLEET_REPO_COUNT:-0}" -gt 0 ]]; then
    _base="${FLEET_REPO_SPEC##*/}"
    for ((_i = 1; _i <= FLEET_REPO_COUNT; _i++)); do _add_agent "$_base-$_i" "$FLEET_REPO_SPEC" true "$_lrc" "$_dm" "$_dp" claude; done
  fi
  if [[ -r "$_cfgdir/hosts" ]]; then
    while IFS= read -r _line; do
      _line="${_line%%#*}"; _line="${_line//[[:space:]]/}"; [[ -z "$_line" ]] && continue
      [[ "$_line" == *:* ]] && FLEET_HOSTS+=("$_line") || FLEET_HOSTS+=("$_line:$_line")
    done < "$_cfgdir/hosts"
  fi
fi
FLEET_SSH_USER="${FLEET_SSH_USER:-$(id -un)}"

# `fleet grid` tiled windows: scratch agents together; repo agents grouped by name
# prefix (space-1..6 → grid-space). Built from the roster (indexed arrays only).
GRID_GROUPS=(); _scratch=""; _prefixes=""
for _i in "${!AGENTS[@]}"; do
  if [[ -z "${A_REPO[$_i]}" ]]; then _scratch+="${AGENTS[$_i]} "
  else _p="${AGENTS[$_i]%-*}"; case " $_prefixes " in *" $_p "*) ;; *) _prefixes+="$_p ";; esac; fi
done
for _p in $_prefixes; do
  _m=""; for _i in "${!AGENTS[@]}"; do [[ "${AGENTS[$_i]%-*}" == "$_p" && -n "${A_REPO[$_i]}" ]] && _m+="${AGENTS[$_i]} "; done
  GRID_GROUPS+=("grid-$_p:${_m% }")
done
[[ -n "$_scratch" ]] && GRID_GROUPS+=("grid-agents:${_scratch% }")

die() { echo "fleet: $*" >&2; exit 1; }

# Apply a jq filter to fleet.json in place (creating it if missing), atomically.
# _json_edit '<filter>' [--arg k v ...]
_json_edit() {
  command -v jq >/dev/null || die "jq is required to edit the config (brew/apt install jq)"
  local filter=$1; shift
  mkdir -p "$(dirname "$FLEET_JSON")"
  [[ -f "$FLEET_JSON" ]] || echo '{}' > "$FLEET_JSON"
  local tmp; tmp="$(mktemp)"
  jq "$@" "$filter" "$FLEET_JSON" > "$tmp" && mv -f "$tmp" "$FLEET_JSON" \
    || { rm -f "$tmp"; die "config edit failed"; }
}

# Escape a string as a JSON string literal (with surrounding quotes). Single-line:
# newlines/CR/tabs become escapes; other control chars are dropped.
json_str() {
  local s=$1
  s=$(printf '%sX' "$s" | tr -d '\000-\010\013\014\016-\037'); s=${s%X}  # strip exotic control chars, keep trailing newlines
  s=${s//\\/\\\\}       # backslash first
  s=${s//\"/\\\"}       # quote
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# name mapping: short (=dir) <-> display (=owner-location-short, window + rc + session name)
disp()  { printf '%s-%s-%s' "$OWNER" "$LOCATION" "$1"; }   # agent-A -> my-nyc-agent-A
short() { printf '%s' "${1#"$OWNER-$LOCATION-"}"; }         # my-nyc-agent-A -> agent-A (idempotent on bare short names)

# Per-agent settings, resolved from the roster arrays by name.
_agent_idx() { local i; for i in "${!AGENTS[@]}"; do [[ "${AGENTS[$i]}" == "$1" ]] && { printf '%s' "$i"; return 0; }; done; return 1; }
agent_repo()   { local i; i="$(_agent_idx "$1")" && printf '%s' "${A_REPO[$i]}"; }
agent_chrome() { local i; i="$(_agent_idx "$1")" && [[ "${A_CHROME[$i]}" == true ]]; }
agent_rc()     { local i; i="$(_agent_idx "$1")" && [[ "${A_RC[$i]}" == true ]]; }
agent_model()  { local i; i="$(_agent_idx "$1")" && printf '%s' "${A_MODEL[$i]}"; }
agent_pmode()  { local i; i="$(_agent_idx "$1")" && printf '%s' "${A_PMODE[$i]}"; }
agent_harness() { local i; i="$(_agent_idx "$1")" && printf '%s' "${A_HARNESS[$i]}" || printf 'claude'; }

agent_flags() { agent_chrome "$1" && printf '%s\n' '--chrome'; }

# The command tmux runs in a window. Takes the SHORT name; the remote-control
# name it launches with is the display (location-prefixed) form. Kept as a
# string because tmux respawn takes a shell command.
agent_cmd() {
  local name=$1 dname; dname="$(disp "$name")"

  # --- codex harness -----------------------------------------------------------
  # Codex has no -n / --chrome / --remote-control; its "bypassPermissions" is the
  # --dangerously-* flag, anything else maps to --full-auto (sandboxed). FLEET_AGENT
  # is still set (harmless). Like claude, it RESUMES the last session by default
  # (codex resume --last) with a fresh fallback.
  if [[ "$(agent_harness "$name")" == codex ]]; then
    local model approval cx cont
    model="$(agent_model "$name")"
    case "$(agent_pmode "$name")" in
      bypassPermissions) approval="--dangerously-bypass-approvals-and-sandbox" ;;
      *)                 approval="--full-auto" ;;
    esac
    cx="$(printf 'FLEET_AGENT=%q %q' "$dname" "$CODEX")"
    [[ -n "$model" ]] && cx+="$(printf ' --model %q' "$model")"
    cx+=" $approval"
    if [[ "${FLEET_RESUME:-0}" == 1 ]]; then
      cont="$(printf 'FLEET_AGENT=%q %q resume --last' "$dname" "$CODEX")"
      printf 'bash -c %q' "$cont || $cx"
    else
      printf '%s' "$cx"
    fi
    return
  fi

  # --- claude harness (default) ------------------------------------------------
  local flags flagstr="" f fresh cont rc="" extra="" _v
  mapfile -t flags < <(agent_flags "$name")
  for f in "${flags[@]:-}"; do [[ -n "$f" ]] && flagstr+=" $(printf '%q' "$f")"; done
  # Per-agent (from fleet.json): remoteControl (claude.ai/code), model, permission-mode.
  agent_rc "$name" && rc="$(printf ' --remote-control %q' "$dname")"
  _v="$(agent_model "$name")"; [[ -n "$_v" ]] && extra+="$(printf ' --model %q' "$_v")"
  _v="$(agent_pmode "$name")"; [[ -n "$_v" ]] && extra+="$(printf ' --permission-mode %q' "$_v")"
  fresh="$(printf 'FLEET_AGENT=%q %q' "$dname" "$CLAUDE")$rc$extra$(printf ' -n %q' "$dname")$flagstr"
  if [[ "${FLEET_RESUME:-0}" == 1 ]]; then
    # Resume this workspace's most recent conversation; fall back to a fresh
    # session if there's nothing to continue (first boot, or transcript gone).
    cont="$(printf 'FLEET_AGENT=%q %q --continue' "$dname" "$CLAUDE")$rc$extra$(printf ' -n %q' "$dname")$flagstr"
    printf 'bash -c %q' "$cont || $fresh"
  else
    printf '%s' "$fresh"
  fi
}

window_exists() { tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; }

start_agent() {
  local name=$1 dir="$CO_DIR/$1" win repo
  win="$(disp "$name")"; repo="$(agent_repo "$name")"
  if [[ -n "$repo" ]]; then
    [[ -d "$dir" ]] || die "workspace missing: $dir (repo agent — run 'fleet setup $repo <count>' to clone it)"
  else
    mkdir -p "$dir"   # scratch agent: an empty working folder it owns
  fi

  # "Already running?" must follow the agent, not its window name — after `fleet grid`
  # the pane lives in a grid-* window, so a window-name check would miss it and spawn a
  # DUPLICATE. Check the stable @agent pane tag (present in any window, gridded or not).
  if [[ -n "$(pane_for "$win")" ]]; then
    echo "  = $win already running"
    return
  fi

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-window -d -t "$SESSION" -n "$win" -c "$dir" "$(agent_cmd "$name")"
  else
    tmux new-session -d -s "$SESSION" -n "$win" -c "$dir" "$(agent_cmd "$name")"
  fi
  # Stamp the pane with a STABLE identity in a tmux pane option. grid/spread move
  # panes by this, never by relaunching — so agent state is preserved. We use a
  # pane OPTION (@agent) rather than the pane title because Claude Code overwrites
  # the title with its own status glyph; it cannot touch a tmux option.
  tmux set-option -p -t "$SESSION:$win" @agent "$win" 2>/dev/null || true
  # Keep dead panes visible instead of vanishing, so a crash is diagnosable.
  tmux set-option -t "$SESSION" -w remain-on-exit on 2>/dev/null || true
  echo "  + $win"
}

# Echo the tmux target (session:win.pane) of the pane tagged @agent == $1, or nothing.
pane_for() {
  tmux list-panes -s -t "$SESSION" -F '#{@agent}=#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
    | awk -F= -v t="$1" '$1==t{print $2; exit}'
}

# fleet setup <owner>/<repo> [count] — provision repo agents.
# Clones `count` copies of a GitHub repo into $CO_DIR/<repo>-1..N and writes one
# entry per clone into fleet.json's `agents` (repo bound, chrome on, RC off by
# default — hand-tweak individual ones after). Idempotent; existing per-agent
# settings are preserved.
cmd_setup() {
  local spec=${1:-} count=${2:-4} base url i dir
  [[ -n "$spec" ]] || die "usage: fleet setup <owner>/<repo> [count]   (e.g. acme/app 4)"
  [[ "$spec" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "repo must be <owner>/<repo> (e.g. acme/app), got: $spec"
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || die "count must be a positive integer, got: $count"
  command -v git >/dev/null || die "git not installed"
  base="${spec##*/}"
  # Default to SSH (matches this repo's own clone convention); override the base
  # for HTTPS: FLEET_GIT_BASE=https://github.com/ fleet setup <owner>/<repo>
  url="${FLEET_GIT_BASE:-git@github.com:}$spec.git"

  echo "setup: $count clone(s) of $spec -> $CO_DIR/$base-1..$count"
  mkdir -p "$CO_DIR"
  for ((i = 1; i <= count; i++)); do
    dir="$CO_DIR/$base-$i"
    if [[ -d "$dir/.git" ]]; then
      echo "  = $base-$i already cloned"
    else
      echo "  + cloning $base-$i"
      git clone "$url" "$dir" || die "clone failed: $url -> $dir"
    fi
  done

  # write one agent entry per clone into fleet.json (keep existing per-agent flags)
  for ((i = 1; i <= count; i++)); do
    _json_edit '.agents[$n] = ((.agents[$n] // {chrome:true, remoteControl:false}) + {repo:$spec})' \
      --arg n "$base-$i" --arg spec "$spec"
  done
  echo "  wrote $count agent(s) to $FLEET_JSON"
  echo
  echo "next: fleet start   # launches $base-1..$count + the general agents"
  echo "tweak: edit $FLEET_JSON to flip remoteControl/chrome on individual agents"
}

# fleet install-hooks — wire fleet-hook.sh into ~/.claude/settings.json for the
# three events. Idempotent. Server machines only (clients run no agents).
cmd_install_hooks() {
  local cfg="$HOME/.claude/settings.json" hook
  # Bundled: wire `fleet hook <event>` (binary on PATH — stable across upgrades).
  # Script: point at the hook script directly.
  if [[ -n "${FLEET_BUNDLED:-}" && -n "${FLEET_BIN:-}" ]]; then
    hook="$FLEET_BIN hook"
  else
    hook="$FLEET_HOME/hooks/fleet-hook.sh"
    [[ -x "$hook" ]] || die "missing hook script: $hook"
  fi
  mkdir -p "$HOME/.claude"
  [[ -f "$cfg" ]] || echo '{}' > "$cfg"
  if ! command -v jq >/dev/null; then
    echo "fleet: jq not found — add these hooks to $cfg manually:" >&2
    echo "  UserPromptSubmit -> $hook working ; Notification -> $hook waiting ; Stop -> $hook stop" >&2
    return 1
  fi
  local tmp; tmp="$(mktemp)"
  if ! jq --arg h "$hook" '
    def ensure($ev; $arg):
      .hooks[$ev] = ((.hooks[$ev] // []) | map(select(.__fleet != true)))
        + [{"__fleet": true, "hooks": [{"type":"command","command": ($h + " " + $arg)}]}];
    (.hooks //= {})
    | ensure("UserPromptSubmit"; "working")
    | ensure("Notification"; "waiting")
    | ensure("Stop"; "stop")
  ' "$cfg" > "$tmp"; then
    rm -f "$tmp"
    die "jq failed to update $cfg"
  fi
  mv -f "$tmp" "$cfg"
  echo "fleet: hooks installed in $cfg"
}

cmd_start() {
  [[ "$MODE" == client ]] && die "client mode: this machine doesn't run local agents — attach a server with 'fleet remote <host>'. Force once with: FLEET_MODE=server fleet start"
  command -v tmux >/dev/null || die "tmux not installed (sudo apt install -y tmux)"
  command -v "$CLAUDE" >/dev/null || die "claude not found: $CLAUDE"
  # Resume each agent's last conversation by default (claude --continue, falling
  # back to fresh if there's nothing to continue). `--fresh` forces a cold start.
  local a; for a in "$@"; do [[ "$a" == --fresh ]] && FLEET_RESUME=0; done
  FLEET_RESUME="${FLEET_RESUME:-1}"

  ensure_logins   # prompt for claude/codex login if the roster needs it and it's missing

  echo "starting fleet in tmux session '$SESSION' ($([[ "$FLEET_RESUME" == 1 ]] && echo resuming || echo fresh))"
  for a in "${AGENTS[@]}"; do start_agent "$a"; done
  echo
  cmd_status
  echo
  echo "attach: fleet attach   (or: tmux -S $TMUX_SOCK attach -t $SESSION; detach: Ctrl-b d)"
  echo "remote: claude.ai/code"
  [[ -n "${TERM:-}" && "$FLEET_TERM" != "$TERM" ]] && \
    echo "note: '$TERM' has no terminfo here — using '$FLEET_TERM'. Full fidelity: infocmp -x $TERM | ssh $(hostname) 'tic -x -'"
}

cmd_status() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "fleet not running"
    return
  fi
  printf '%-10s %-8s %s\n' WINDOW ALIVE PANE-CMD
  tmux list-windows -t "$SESSION" -F '#W|#{pane_dead}|#{pane_current_command}' \
    | while IFS='|' read -r w dead cmd; do
        [[ "$dead" == "1" ]] && alive=DEAD || alive=up
        printf '%-10s %-8s %s\n' "$w" "$alive" "$cmd"
      done
}

# The overview shown by `fleet status`, `fleet ls`, and a bare `fleet`: this
# machine's agents, then the other machines you can hop to. cmd_start still calls
# cmd_status directly so launching doesn't tack the remote table onto its output.
cmd_ls() {
  echo "local  ($OWNER-$LOCATION, $MODE mode, session '$SESSION'):"
  cmd_status
  echo
  echo "remote machines:"
  cmd_remote_ls
}

# Restart ONE agent in place — respawn just its pane, leaving every sibling pane
# (and the rest of the fleet) untouched. Works in grid OR spread mode because it
# finds the pane by its @agent tag, not by a window name. Also revives a dead pane
# (remain-on-exit keeps crashed panes around; respawn-pane -k brings them back).
# RESUMES the agent's last conversation (claude --continue) by default so you don't
# lose context; pass --restart-fresh for a clean start. Note: in-flight work is cut.
cmd_restart() {
  local in=${1:-} name dname pane fresh=0
  [[ "$in" == --restart-fresh ]] && { fresh=1; in=${2:-}; }
  [[ -n "$in" ]] || die "usage: fleet restart [--restart-fresh] <name>   (e.g. space-3)"
  name="$(short "$in")"; dname="$(disp "$name")"
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  pane="$(pane_for "$dname")"
  [[ -n "$pane" ]] || die "no pane tagged $dname (see: fleet status)"
  tmux respawn-pane -k -t "$pane" -c "$CO_DIR/$name" "$(FLEET_RESUME=$((1 - fresh)) agent_cmd "$name")"
  tmux set-option -p -t "$pane" @agent "$dname" 2>/dev/null || true   # re-assert tag
  echo "restarted $dname in place ($([[ $fresh == 1 ]] && echo fresh || echo resumed))"
}

# fleet respawn [host] — revive any DEAD agents and start any that aren't running,
# resuming their conversations. Idempotent (live agents untouched). No host: this
# machine; with a host: run it there over Tailscale SSH. A manual watchdog.
cmd_respawn() {
  local target=${1:-}
  if [[ -n "$target" ]]; then
    command -v tailscale >/dev/null || die "tailscale not installed"
    remote_exec "$(resolve_host "$target")" respawn; return
  fi
  [[ "$MODE" == client ]] && die "client mode: no local agents (use: fleet respawn <host>)"
  tmux has-session -t "$SESSION" 2>/dev/null || { echo "fleet not running — starting it"; cmd_start; return; }
  FLEET_RESUME="${FLEET_RESUME:-1}"
  local a dname pane dead revived=0 started=0 skipped=0
  for a in "${AGENTS[@]}"; do
    dname="$(disp "$a")"; pane="$(pane_for "$dname")"
    if [[ -z "$pane" ]]; then
      if [[ -n "$(agent_repo "$a")" && ! -d "$CO_DIR/$a" ]]; then
        echo "  ! $a not cloned (fleet setup) — skipped"; skipped=$((skipped + 1)); continue
      fi
      start_agent "$a" >/dev/null; echo "  + started $dname"; started=$((started + 1))
    else
      dead="$(tmux display-message -p -t "$pane" '#{pane_dead}' 2>/dev/null || echo 0)"
      if [[ "$dead" == 1 ]]; then
        tmux respawn-pane -k -t "$pane" -c "$CO_DIR/$a" "$(agent_cmd "$a")"
        tmux set-option -p -t "$pane" @agent "$dname" 2>/dev/null || true
        echo "  ↻ revived $dname"; revived=$((revived + 1))
      fi
    fi
  done
  echo "respawn: $revived revived, $started started, $skipped skipped (conversations resumed)"
}

cmd_attach() {
  local in=${1:-} name pane
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running (start it first)"
  if [[ -n "$in" ]]; then
    name="$(short "$in")"; pane="$(pane_for "$(disp "$name")")"
    [[ -n "$pane" ]] || die "no such agent: $(disp "$name") (see: fleet status)"
    tmux select-window -t "${pane%.*}"   # works in grid (selects the group window) or spread
    tmux select-pane -t "$pane"
  fi
  # Attach if outside tmux; switch-client if already inside one. exec bypasses the
  # tmux() wrapper (it runs the real binary), so pass the pinned socket explicitly.
  # switch-client only works within the SAME tmux server. If you're inside a DIFFERENT
  # tmux (e.g. an ssh-tmux on the default socket, not fleet's pinned one), switch-client
  # fails with "no current client" — so attach instead, with TMUX unset so tmux lets you
  # attach from within another session. ${TMUX%%,*} is the socket path in $TMUX.
  if [[ -n "${TMUX:-}" && "${TMUX%%,*}" == "$TMUX_SOCK" ]]; then
    exec env TERM="$FLEET_TERM" tmux -S "$TMUX_SOCK" switch-client -t "$SESSION"
  else
    exec env -u TMUX TERM="$FLEET_TERM" tmux -S "$TMUX_SOCK" attach -t "$SESSION"
  fi
}

# Regroup the LIVE agent panes into tiled multi-pane windows per GRID_GROUPS.
# NON-DESTRUCTIVE: it only moves panes (tmux join-pane re-parents them); the claude
# processes and their state are never touched. Driven by the stable pane title, so
# it's idempotent — safe to run when already gridded.
cmd_grid() {
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running (start it first)"
  local per="${FLEET_GRID_PER:-4}"          # max panes per grid window; overflow -> pages
  local g gname members m src base count page wname widx wn
  for g in "${GRID_GROUPS[@]}"; do
    gname="${g%%:*}"; members="${g#*:}"
    base=""; count=0; page=1
    for m in $members; do
      src="$(pane_for "$(disp "$m")")"        # session:win.pane, or empty if not running
      [[ -n "$src" ]] || continue
      if [[ -z "$base" ]]; then               # first member -> its window becomes page 1
        tmux rename-window -t "${src%.*}" "$gname" 2>/dev/null || true
        base="${src%.*}"; count=1; page=2; continue
      fi
      if [[ "${src%.*}" == "$base" && "$count" -lt "$per" ]]; then
        count=$((count+1)); continue          # already on the current page, within the limit
      fi
      if [[ "$count" -ge "$per" ]]; then       # current page full -> start a new page
        wname="$gname-$page"
        if [[ "${src%.*}" == "$base" ]]; then  # pane sits in an over-full page: break it out
          tmux break-pane -d -s "$src" -n "$wname" 2>/dev/null || true
          src="$(pane_for "$(disp "$m")")"     # re-find it in the new window
        else                                   # pane has its own window: adopt it as the page
          tmux rename-window -t "${src%.*}" "$wname" 2>/dev/null || true
        fi
        base="${src%.*}"; count=1; page=$((page+1))
      else                                     # room on the current page -> join in
        tmux select-layout -t "$base" tiled 2>/dev/null || true
        tmux join-pane -s "$src" -t "$base" 2>/dev/null || true
        count=$((count+1))
      fi
    done
    # tile every page window of this group (grid-<group> and grid-<group>-N)
    while read -r widx wn; do
      case "$wn" in "$gname"|"$gname"-*) tmux select-layout -t "$SESSION:$widx" tiled 2>/dev/null || true ;; esac
    done < <(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null)
  done
  echo "gridded: $(tmux list-windows -t "$SESSION" -F '#W' | tr '\n' ' ')"
  echo "  ≤$per panes/window; extras overflow to grid-<group>-2, -3, … (Ctrl-b <n> or click to page)"
  echo "  zoom one full-screen: Ctrl-b z (toggles) · back to one-window-per-agent: fleet spread"
}

# Break the LIVE panes back into one window per agent. NON-DESTRUCTIVE — break-pane
# re-parents each pane, never kills it. Robust to index shifts: it re-queries after
# every break instead of walking a stale snapshot (the bug that mangled it before).
cmd_spread() {
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  local multi ref pidx ptitle w t
  # 1. break every multi-pane window down, one pane at a time, re-querying each pass
  while :; do
    multi="$(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_panes}' 2>/dev/null | awk '$2>1{print $1; exit}')"
    [[ -n "$multi" ]] || break
    ref="$(tmux list-panes -t "$SESSION:$multi" -F '#{pane_index} #{@agent}' 2>/dev/null | tail -1)"
    pidx="${ref%% *}"; ptitle="${ref#* }"
    tmux break-pane -d -s "$SESSION:$multi.$pidx" -n "${ptitle:-agent}" 2>/dev/null || true
  done
  # 2. name each remaining single-pane window after its agent (the @agent tag)
  for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
    t="$(tmux list-panes -t "$SESSION:$w" -F '#{@agent}' 2>/dev/null | head -1)"
    [[ -n "$t" ]] && tmux rename-window -t "$SESSION:$w" "$t" 2>/dev/null || true
  done
  echo "spread: $(tmux list-windows -t "$SESSION" -F '#W' | tr '\n' ' ')"
}

# read_state <agent>  — echoes "status|alert|since|summary" from a FRESH state file,
# or empty if missing/stale. No sourcing: split each line on the first '='.
read_state() {
  local f="$STATE_DIR/$1" now mtime age status="" alert="0" since="0" summary="" k v
  [[ -f "$f" ]] || return 1
  now=$(date +%s)
  # GNU stat (-c) first, then BSD (-f); some GNU stats don't fail cleanly on -f,
  # so validate the result is numeric before the arithmetic below (set -u safe).
  mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  age=$(( now - mtime )); [[ "$age" -le "$FLEET_STATE_TTL" ]] || return 1
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    case "$k" in status) status=$v;; alert) alert=$v;; since) since=$v;; summary) summary=$v;; esac
  done < "$f"
  case "$status" in working|idle|waiting|dead|unknown) ;; *) status=unknown ;; esac
  [[ "$alert" =~ ^[01]$ ]] || alert=0
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  printf '%s|%s|%s|%s' "$status" "$alert" "$since" "$summary"
}

# scrape_pane <tmux-target> <dead?>  — echoes "status|alert|since|summary" guessed
# from the pane. Coarse: title glyph → waiting; last non-empty captured line → summary.
scrape_pane() {
  local tgt=$1 dead=$2 title last status="working" alert="0"
  [[ "$dead" == 1 ]] && { printf 'dead|0|0|'; return; }
  title=$(tmux display-message -p -t "$tgt" '#{pane_title}' 2>/dev/null || true)
  # Claude shows a prompt/❯ style glyph when awaiting input; treat '?' or '❯' as waiting.
  case "$title" in *'❯'*|*'?'*) status="waiting"; alert="1";; esac
  last=$(tmux capture-pane -p -t "$tgt" 2>/dev/null | tr -d '\r' \
         | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
  printf '%s|%s|0|%s' "$status" "$alert" "$last"
}

# fleet status --json — this machine's sessions as one JSON object (tray feed).
cmd_status_json() {
  local hostname running=false sessions="" first=1
  hostname="$(disp "" | sed 's/-$//')"
  tmux has-session -t "$SESSION" 2>/dev/null && running=true
  if [[ "$running" == true ]]; then
    while IFS='|' read -r agent tmuxt dead; do
      [[ -n "$agent" ]] || continue
      local st alive status alert since summary source
      if st="$(read_state "$agent")"; then source="hook"
      else st="$(scrape_pane "$tmuxt" "$dead")"; source="scrape"; fi
      IFS='|' read -r status alert since summary <<<"$st"
      if [[ "$dead" == 1 ]]; then alive=false; status=dead; alert=0; else alive=true; fi
      [[ "$alert" == 1 ]] && alert=true || alert=false
      [[ "$since" =~ ^[0-9]+$ ]] || since=0
      local obj="{\"agent\":$(json_str "$agent"),\"short\":$(json_str "$(short "$agent")"),"
      obj+="\"alive\":$alive,\"status\":$(json_str "${status:-unknown}"),\"alert\":$alert,"
      obj+="\"since\":${since:-0},\"summary\":$(json_str "$summary"),\"source\":$(json_str "$source"),"
      obj+="\"tmux\":$(json_str "$tmuxt"),\"rc\":$(json_str "$agent")}"
      [[ $first == 1 ]] && { sessions="$obj"; first=0; } || sessions+=",$obj"
    done < <(tmux list-panes -s -t "$SESSION" \
             -F '#{@agent}|#{session_name}:#{window_index}.#{pane_index}|#{pane_dead}' 2>/dev/null)
  fi
  printf '{"host":%s,"location":%s,"mode":%s,"session_running":%s,"sessions":[%s]}\n' \
    "$(json_str "$hostname")" "$(json_str "$LOCATION")" "$(json_str "$MODE")" "$running" "$sessions"
}

# fleet hosts [--json] — list configured hosts. --json feeds the tray.
# fleet hosts [ls|--json|add <short> [host]|rm <short>] — manage remote machines
# in ~/.config/fleet/hosts. `add nyc my-box` stores an alias; `add my-box` stores a
# bare hostname (shown as-is); `rm` deletes by short name.
cmd_hosts() {
  case "${1:-}" in
    add)         shift; hosts_add "$@"; return ;;
    rm|remove)   shift; hosts_rm "$@"; return ;;
    scan)        shift; hosts_scan "$@"; return ;;
    --json)      ;;   # fall through to the JSON block below
    ""|ls|list)
      printf '%-12s %s\n' HOST TAILSCALE-NAME
      printf '%-12s %s\n' "$(disp "" | sed 's/-$//')" "(this machine, $MODE)"
      local h; for h in "${FLEET_HOSTS[@]}"; do printf '%-12s %s\n' "${h%%:*}" "${h#*:}"; done
      return ;;
    *) die "usage: fleet hosts [ls|--json|add <short> [host]|rm <short>|scan [--add]]" ;;
  esac
  # JSON: local machine first, then each configured host.
  local out h lname
  lname="$(disp "" | sed 's/-$//')"     # e.g. my-nyc (owner-location)
  out='['
  out+="{\"short\":$(json_str local),\"host\":$(json_str "$lname"),\"local\":true,\"mode\":$(json_str "$MODE")}"
  for h in "${FLEET_HOSTS[@]}"; do
    out+=",{\"short\":$(json_str "${h%%:*}"),\"host\":$(json_str "${h#*:}"),\"local\":false}"
  done
  out+=']'
  printf '%s\n' "$out"
}

# hosts_add <short> [host] — one arg: bare hostname (short = host). Two args:
# short alias -> host. Writes fleet.json's `.hosts` map (idempotent).
hosts_add() {
  local short=${1:-} name=${2:-}
  [[ -n "$short" ]] || die "usage: fleet hosts add <short> <host>   (or: fleet hosts add <host>)"
  [[ -n "$name" ]] || name="$short"
  [[ "$short" =~ ^[A-Za-z0-9._-]+$ ]] || die "short name must be alphanumeric/._-, got: $short"
  [[ "$name"  =~ ^[A-Za-z0-9._-]+$ ]] || die "host must be alphanumeric/._-, got: $name"
  _json_edit '.hosts[$s] = $h' --arg s "$short" --arg h "$name"
  echo "hosts: $short -> $name"
}

# hosts_rm <short> — remove the entry from fleet.json's `.hosts`.
hosts_rm() {
  local short=${1:-}
  [[ -n "$short" ]] || die "usage: fleet hosts rm <short>"
  _json_edit 'if .hosts then .hosts |= del(.[$s]) else . end' --arg s "$short"
  echo "hosts: removed $short"
}

# hosts_scan [--add] — discover tailnet peers; print them (or --add them all as
# bare hostnames — alias later with `fleet hosts add <short> <host>`).
hosts_scan() {
  command -v tailscale >/dev/null || die "tailscale not installed"
  command -v jq >/dev/null || die "jq required"
  local add=0; [[ "${1:-}" == --add ]] && add=1
  local st self h
  st="$(tailscale status --json 2>/dev/null)" || die "tailscale not running (run: tailscale up)"
  self="$(printf '%s' "$st" | jq -r '.Self.HostName // empty')"
  echo "tailnet peers (self: ${self:-?}):"
  while read -r h; do
    [[ -z "$h" || "$h" == "$self" ]] && continue
    if printf '%s\n' "${FLEET_HOSTS[@]:-}" | grep -q ":$h$"; then echo "  = $h (already configured)"
    elif [[ "$add" == 1 ]]; then _json_edit '.hosts[$h] = $h' --arg h "$h"; echo "  + $h"
    else echo "  ? $h   (add: fleet hosts add $h)"; fi
  done < <(printf '%s' "$st" | jq -r '.Peer[]?.HostName // empty')
  [[ "$add" == 0 ]] && echo "add all as-is: fleet hosts scan --add   (or alias: fleet hosts add <short> <host>)"
}

# fleet remote ls — list the configured hosts and their reachability.
# Reachability comes from `tailscale status`, a local read of last-known peer
# state (no network round-trip, so it never blocks); shown only if tailscale is
# installed.
cmd_remote_ls() {
  local st="" stj="" have_ts="" h short hn state self seen=" " first=1 _remote_all="${_remote_all:-0}"
  command -v tailscale >/dev/null && { have_ts=1; st="$(tailscale status 2>/dev/null || true)"; }
  printf '%-10s %-26s %s\n' HOST TAILSCALE-NAME REACHABLE
  for h in "${FLEET_HOSTS[@]}"; do
    short="${h%%:*}"; hn="${h#*:}"; state="-"; seen+="$hn "
    if [[ -n "$have_ts" ]]; then
      if grep -Fq -- "$hn" <<<"$st"; then
        grep -F -- "$hn" <<<"$st" | grep -qi offline && state="offline" || state="online"
      else
        state="unknown"
      fi
    fi
    printf '%-10s %-26s %s\n' "$short" "$hn" "$state"
  done
  # Auto-discovery: surface YOUR OWN online tailnet machines (same Tailscale user) that
  # aren't configured yet, so a new fleet box shows up without `fleet hosts add` — without
  # flooding the list with a shared tailnet's other people. They're connectable as-is
  # (`fleet remote <name>` takes a bare hostname); `--all` shows every online peer.
  if [[ -n "$have_ts" ]] && command -v jq >/dev/null 2>&1; then
    local uid filter='select(.Online==true)'
    stj="$(tailscale status --json 2>/dev/null || true)"
    self="$(printf '%s' "$stj" | jq -r '.Self.HostName // empty' 2>/dev/null)"
    uid="$(printf '%s' "$stj" | jq -r '.Self.UserID // empty' 2>/dev/null)"
    [[ "$_remote_all" == 1 || -z "$uid" ]] || filter="select(.Online==true and ((.UserID|tostring)==\"$uid\"))"
    while read -r hn; do
      [[ -z "$hn" || "$hn" == "$self" || "$seen" == *" $hn "* ]] && continue
      [[ "$first" == 1 ]] && { echo "── discovered ($([[ "$_remote_all" == 1 ]] && echo "all online peers" || echo "your online machines")) ──"; first=0; }
      printf '%-10s %-26s %s\n' "·" "$hn" "online"
    done < <(printf '%s' "$stj" | jq -r ".Peer[]? | $filter | .HostName // empty" 2>/dev/null)
  fi
  [[ -n "$have_ts" ]] || echo "(install tailscale to see reachability)"
  echo "attach one with: fleet remote <host>   ·   pin one: fleet hosts add <short> <host>"
}

# short name (from FLEET_HOSTS) -> tailscale hostname; a bare hostname passes through.
resolve_host() {
  local t=$1 h
  for h in "${FLEET_HOSTS[@]}"; do [[ "${h%%:*}" == "$t" ]] && { printf '%s' "${h#*:}"; return; }; done
  printf '%s' "$t"
}

# Run `fleet <sub>` on another machine over Tailscale SSH. Prefers the installed
# `fleet` binary on the remote (a login shell puts /usr/local/bin on PATH), and
# falls back to the recorded script path (~/.config/fleet/home). <sub> is a trusted
# literal (attach/update) — not user free-text — so it's safe inline.
remote_exec() {
  local host=$1 sub=$2
  command -v ssh >/dev/null || die "ssh not installed"
  echo "fleet -> $FLEET_SSH_USER@$host  (tailscale): $sub"
  # `attach` needs a PTY for tmux. `tailscale ssh` won't allocate one in command mode
  # (and rejects -t), so use plain `ssh -tt` over the tailnet: the box's Tailscale SSH
  # intercepts port 22 keylessly, and -tt forces the PTY. Host-key checking is skipped
  # because the tailnet transport (WireGuard + Tailscale-SSH ACLs) already authenticates
  # the peer — and Tailscale rotates the box's SSH host key on reinstall anyway.
  exec ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$FLEET_SSH_USER@$host" \
    "sh -lc 'command -v fleet >/dev/null 2>&1 && exec fleet $sub || exec \"\$(cat ~/.config/fleet/home 2>/dev/null || echo ~/.fleet)\"/bin/fleet.sh $sub'"
}

# fleet update [host] — pull the latest fleet and re-wire.
# No arg: fast-forward THIS machine's checkout (never clobbers local work) and, if
# anything changed, re-run the idempotent installer so new features land. With a
# host: run `fleet update` on that machine over Tailscale SSH instead.
# Note: already-running agents keep the old launcher until you restart them.
cmd_update() {
  local target="" nocl=0 force=0 root before after a args=()
  for a in "$@"; do case "$a" in --no-clis) nocl=1 ;; --force|-f) force=1 ;; *) args+=("$a") ;; esac; done
  target="${args[0]:-}"
  [[ -n "$target" ]] && { remote_exec "$(resolve_host "$target")" update; return; }

  # Bundled binary: no git checkout — download the latest release binary in place
  # (over itself; the running process keeps its inode), then upgrade the agent CLIs.
  # Check the latest tag first and skip if we're already current (unless --force).
  if [[ -n "${FLEET_BUNDLED:-}" ]]; then
    local self="${FLEET_BIN:-$(command -v fleet 2>/dev/null)}" dir cur latest
    [[ -n "$self" ]] || die "can't locate the fleet binary to update"
    dir="$(dirname "$self")"; cur="${FLEET_VERSION:-dev}"
    latest="$(curl -fsSL https://api.github.com/repos/anivk/fleet/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
    if [[ "$force" == 0 && -n "$latest" && "$cur" != dev && "$cur" == "$latest" ]]; then
      echo "update: already up to date ($cur)"; return
    fi
    [[ -z "$latest" && "$force" == 0 ]] && echo "update: couldn't reach GitHub to check the version — downloading anyway"
    echo "update: $cur -> ${latest:-latest}…"
    # FLEET_VERSION=latest overrides the binary's own version (inherited in the env)
    # so get.sh fetches the latest release, not the version we're on.
    FLEET_VERSION=latest FLEET_INSTALL_DIR="$dir" sh "$FLEET_HOME/get.sh" || die "download failed"
    if [[ "$nocl" == 0 && -x "$FLEET_HOME/bootstrap/bootstrap.sh" ]]; then
      echo "update: upgrading claude/codex…"
      UPGRADE_CLIS=1 "$FLEET_HOME/bootstrap/bootstrap.sh" --clis-only >/dev/null 2>&1 || true
    fi
    echo "  done — new binary in place; running agents keep the old launcher until restart."
    return
  fi

  command -v git >/dev/null || die "git not installed"
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -d "$root/.git" ]] || die "not a git checkout: $root — can't self-update"
  git -C "$root" remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote in $root"
  # Refuse on ANY uncommitted change so an update never mixes with local edits
  # (merge --ff-only alone only guards files the incoming commits touch).
  git -C "$root" diff --quiet && git -C "$root" diff --cached --quiet \
    || die "working tree not clean in $root — commit or stash there, then retry"

  echo "update: $root"
  before="$(git -C "$root" rev-parse --short HEAD)"
  git -C "$root" fetch --quiet origin || die "fetch failed"
  # Fast-forward only: refuse to merge or rewrite over local commits / dirty tree. Fall
  # back to origin/<branch> when the branch has no upstream configured (@{u} would fail
  # even on a clean, in-sync tree and wrongly report "diverged").
  local branch up
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  up="$(git -C "$root" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "origin/$branch")"
  git -C "$root" merge --ff-only "$up" >/dev/null 2>&1 \
    || die "can't fast-forward $root (diverged from $up, or local commits) — commit/stash there, then retry"
  after="$(git -C "$root" rev-parse --short HEAD)"

  if [[ "$before" == "$after" ]]; then
    echo "  already up to date ($after)"
  else
    echo "  $before -> $after:"
    git -C "$root" --no-pager log --oneline "$before..$after" | sed 's/^/    /'
  fi
  # Upgrade the agent CLIs (claude/codex) via bootstrap unless --no-clis, then
  # re-run the (idempotent) fleet installer to re-wire dotfiles/config.
  if [[ "$nocl" == 0 && -x "$root/bootstrap/bootstrap.sh" ]]; then
    echo "  upgrading claude/codex…"
    UPGRADE_CLIS=1 "$root/bootstrap/bootstrap.sh" --clis-only >/dev/null 2>&1 || true
  fi
  echo "  re-running installer…"
  FLEET_PREFIX="$root" "$root/install.sh" >/dev/null || die "installer failed"
  echo "  refreshed"
  echo
  echo "running agents keep the old launcher until 'fleet restart <name>' (or 'fleet stop && fleet start')."
}

# fleet remote <host> — attach another machine's fleet over Tailscale SSH.
# fleet remote ls      — list configured hosts (see cmd_remote_ls).
# Requires: tailscale (with SSH) on both ends, and fleet installed on the remote.
cmd_remote() {
  local a target="" use_cmux=0
  _remote_all=0
  for a in "$@"; do
    case "$a" in
      --cmux)  use_cmux=1 ;;                 # open the attach in a new cmux workspace
      --all)   _remote_all=1 ;;
      attach)  ;;                            # the only remote action; implied
      *)       [[ -z "$target" ]] && target="$a" ;;
    esac
  done
  case "$target" in ""|ls|list) cmd_remote_ls; return ;; esac
  local host; host="$(resolve_host "$target")"
  [[ "$use_cmux" == 1 ]] && { cmd_remote_cmux "$host"; return; }
  remote_exec "$host" attach
}

# fleet remote <host> --cmux — open the remote fleet attach in a NEW cmux workspace
# (cmux.app, macOS). Run it from inside cmux: the cmux CLI only accepts cmux-spawned
# callers unless CMUX_SOCKET_PASSWORD is set. cmux gives the workspace a PTY, so the
# remote `fleet attach` (tmux) works; SSH goes over the tailnet keylessly (Tailscale SSH).
cmd_remote_cmux() {
  local host=$1 cmux fqdn
  cmux="$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
  [[ -x "$cmux" ]] || die "cmux not found (install cmux.app, or add its CLI to PATH)"
  fqdn="$(tailscale status --json 2>/dev/null | jq -r --arg h "$host" '.Peer[]? | select(.HostName==$h) | .DNSName // empty' 2>/dev/null | sed 's/\.$//')"
  [[ -n "$fqdn" ]] || fqdn="$host"
  echo "cmux -> $FLEET_SSH_USER@$fqdn : fleet attach"
  exec "$cmux" ssh "$FLEET_SSH_USER@$fqdn" --name "fleet: $host" \
    --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null \
    --command 'fleet attach'
}

# fleet rdp-reset [host] — terminate this user's hung graphical (wayland/x11) sessions.
# grd remote-login leaves a session behind when the RDP client closes abruptly (Cmd-W),
# and that stale session then blocks the next login. This clears them. Leaves ssh/tty
# sessions alone. On a host: runs over Tailscale SSH. Run it while DISCONNECTED (it kills
# every graphical session for the user, including one you're actively in).
cmd_rdp_reset() {
  local host="${1:-}"
  if [[ -n "$host" ]]; then
    local sshhost; sshhost="$(_sshhost "$host")"
    echo "rdp-reset -> $sshhost"
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$sshhost" \
      'n=0; for s in $(loginctl list-sessions --no-legend | awk -v u="$(id -un)" "\$3==u{print \$1}"); do case "$(loginctl show-session "$s" -p Type --value)" in x11|wayland|mir) loginctl terminate-session "$s" >/dev/null 2>&1 && n=$((n+1));; esac; done; echo "rdp-reset: cleared $n hung graphical session(s)"'
  fi
  command -v loginctl >/dev/null || die "loginctl is Linux-only — run: fleet rdp-reset <host>"
  local s n=0
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3==u{print $1}'); do
    case "$(loginctl show-session "$s" -p Type --value 2>/dev/null)" in
      x11|wayland|mir) loginctl terminate-session "$s" 2>/dev/null && { echo "  terminated $s"; n=$((n+1)); } ;;
    esac
  done
  echo "rdp-reset: cleared $n hung graphical session(s)"
}

# Resolve a host alias to a full user@host for tailscale ssh (pass through an
# explicit user@... target untouched).
_sshhost() {
  local host; host="$(resolve_host "$1")"
  [[ "$host" == *@* ]] && printf '%s' "$host" || printf '%s@%s' "$FLEET_SSH_USER" "$host"
}

# fleet remote-ssh <host> [command...] — a plain shell (or one command) on the
# remote over Tailscale SSH. Works even when its fleet isn't running — for login,
# provisioning, or debugging. (`fleet remote <host>` attaches the fleet instead.)
cmd_remote_ssh() {
  local target=${1:-}; [[ -n "$target" ]] && shift || true
  [[ -n "$target" ]] || die "usage: fleet remote-ssh <host> [command...]"
  command -v tailscale >/dev/null || die "tailscale not installed"
  local sshhost; sshhost="$(_sshhost "$target")"
  if [[ $# -gt 0 ]]; then exec tailscale ssh "$sshhost" "$@"; fi
  echo "ssh -> $sshhost  (tailscale)"; exec tailscale ssh "$sshhost"
}

# fleet keys {setup <host>|forward [on|off]|check <host>} — let remote git use
# your GitHub keys. Two complementary mechanisms:
#   forward  (A) — ForwardAgent for tailnet hosts in ~/.ssh/config, so your local
#                  ssh-agent reaches the remote during a session (interactive git,
#                  the remote-install clone). Nothing is stored on the remote.
#   setup    (B) — generate a durable key ON the remote and print how to add it to
#                  GitHub, so the autonomous agents there can push on their own.
cmd_keys() {
  local sub=${1:-status}; [[ $# -gt 0 ]] && shift || true
  case "$sub" in
    setup)        keys_setup "$@" ;;
    forward)      keys_forward "$@" ;;
    check|verify) keys_check "$@" ;;
    status|ls|"") keys_status ;;
    *) die "usage: fleet keys {setup <host>|forward [on|off]|check <host>}" ;;
  esac
}

# (B) Ensure a git SSH key exists on the remote, then show how to add it to GitHub.
keys_setup() {
  local target=${1:-}; [[ -n "$target" ]] || die "usage: fleet keys setup <host>"
  command -v tailscale >/dev/null || die "tailscale not installed"
  local sshhost; sshhost="$(_sshhost "$target")"
  echo "keys: ensuring a git SSH key on ${sshhost}…"
  # Single-quoted so $HOME/$(hostname) stay literal here and evaluate on the remote.
  local remote='
key="$HOME/.ssh/id_ed25519"
if [ ! -f "$key" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$key" -C "fleet-$(hostname)" >/dev/null
  echo "  (generated a new key)" >&2
fi
cat "$key.pub"'
  local pub; pub="$(tailscale ssh "$sshhost" "$remote")" || die "could not reach $sshhost"
  echo
  echo "  $pub"
  echo
  echo "Add it to GitHub once (as a user or deploy key):"
  echo "  • gh:  fleet remote-ssh $target 'gh ssh-key add ~/.ssh/id_ed25519.pub -t fleet-$target'"
  echo "  • web: https://github.com/settings/ssh/new   (paste the key above)"
  echo
  echo "Then verify:  fleet keys check $target"
}

# (A) Manage a marked ForwardAgent block in ~/.ssh/config for the configured hosts.
keys_forward() {
  local mode=${1:-on}
  local cfg="$HOME/.ssh/config"
  local begin="# >>> fleet agent-forwarding (managed) >>>"
  local end="# <<< fleet agent-forwarding (managed) <<<"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  local tmp; tmp="$(mktemp)"
  # Drop any existing managed block (portable — no sed -i quirks across mac/linux).
  if [[ -f "$cfg" ]]; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1} skip!=1 {print} $0==e {skip=0}' "$cfg" > "$tmp"
  fi
  if [[ "$mode" == off ]]; then
    mv "$tmp" "$cfg"; chmod 600 "$cfg"; echo "keys: agent forwarding disabled"; return
  fi
  [[ "$mode" == on ]] || die "usage: fleet keys forward [on|off]"
  ((${#FLEET_HOSTS[@]})) || { rm -f "$tmp"; die "no hosts configured — add one: fleet hosts add <short> <host>"; }
  { echo "$begin"
    echo "# 'fleet keys forward' — remote git uses your local keys via agent forwarding."
    printf 'Host'; local h; for h in "${FLEET_HOSTS[@]}"; do printf ' %s' "${h#*:}"; done; printf '\n'
    printf '    ForwardAgent yes\n'
    echo "$end"
  } >> "$tmp"
  mv "$tmp" "$cfg"; chmod 600 "$cfg"
  echo "keys: agent forwarding enabled for:"
  for h in "${FLEET_HOSTS[@]}"; do echo "  • ${h%%:*} (${h#*:})"; done
  echo "test it:  fleet remote-ssh <host> ssh-add -l   # should list your local keys"
}

# Verify a remote can authenticate to GitHub (via a forwarded agent or its own key).
keys_check() {
  local target=${1:-}; [[ -n "$target" ]] || die "usage: fleet keys check <host>"
  command -v tailscale >/dev/null || die "tailscale not installed"
  local sshhost; sshhost="$(_sshhost "$target")"
  echo "keys: testing GitHub SSH auth on ${sshhost}…"
  tailscale ssh "$sshhost" 'ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true'
}

# Show whether agent forwarding is wired up locally.
keys_status() {
  local cfg="$HOME/.ssh/config"
  if grep -qs 'fleet agent-forwarding (managed)' "$cfg"; then
    echo "agent forwarding: ON (~/.ssh/config)"
  else
    echo "agent forwarding: off — enable with: fleet keys forward on"
  fi
  echo "per-host keys:    fleet keys setup <host>   (then: fleet keys check <host>)"
}

# fleet remote-install [--copy] <host> [location] — bootstrap fleet on another
# machine over Tailscale SSH: get the repo onto the remote (~/.fleet by default,
# or /opt/fleet with --global) and run its
# install.sh (server mode). location defaults to the host's short name, so the
# remote's agents are namespaced <owner>-<location>-*.
#
# By default it tries `git clone/pull` on the remote (needs git + clone access to
# the origin there). If that fails — or with --copy — it falls back to rsync'ing
# THIS checkout over Tailscale, so a remote with no GitHub access still works.
cmd_remote_install() {
  local copy=0 global=0 args=() a
  for a in "$@"; do
    case "$a" in
      --copy)   copy=1 ;;
      --global) global=1 ;;
      *)        args+=("$a") ;;
    esac
  done
  local target="${args[0]:-}" loc="${args[1]:-}" host sshhost url
  [[ -n "$target" ]] || die "usage: fleet remote-install [--copy] [--global] <host> [location]"
  command -v tailscale >/dev/null || die "tailscale not installed"
  host="$(resolve_host "$target")"
  # target may be "host" or already "user@host" — don't double the default user.
  if [[ "$host" == *@* ]]; then sshhost="$host"; else sshhost="$FLEET_SSH_USER@$host"; fi

  # Where fleet lives on the remote. Default: per-user (~/.fleet, no sudo).
  # --global: /opt/fleet, a system path (sudo to create it, then owned by the
  # installing user so clone/rsync/update stay sudo-free). install.sh records
  # whichever path into ~/.config/fleet/home, so everything else resolves through it.
  local rdest rprep rsync_target
  if [[ "$global" == 1 ]]; then
    rdest='/opt/fleet'
    rprep='sudo mkdir -p /opt/fleet && sudo chown "$(id -un)":"$(id -gn)" /opt/fleet'
    rsync_target="$sshhost:/opt/fleet/"
  else
    rdest='$HOME/.fleet'          # $HOME expands on the remote; parent (home) always exists
    rprep='true'
    rsync_target="$sshhost:.fleet/"  # relative => remote home
  fi
  # default location = the hostname (minus user@ + domain), with a leading "<owner>-"
  # stripped so <owner>-<location> reconstitutes the hostname rather than doubling the
  # owner: my@my-webserver-nyc -> webserver-nyc (=> agents my-webserver-nyc-*). A host
  # that doesn't start with the owner is kept whole. Override with a 2nd arg.
  if [[ -z "$loc" ]]; then
    loc="${target##*@}"; loc="${loc%%.*}"      # hostname only
    loc="${loc#"$OWNER-"}"                       # drop a leading "<owner>-"
    loc="$(printf '%s' "$loc" | tr -cd 'A-Za-z0-9-')"; loc="${loc#-}"; loc="${loc%-}"
    [[ -n "$loc" ]] || loc="remote"
  fi

  # 0. pre-flight: one clear error instead of two cryptic failures.
  echo "remote-install -> $sshhost  (location=$loc)"
  if ! tailscale ssh "$sshhost" true 2>/dev/null; then
    die "can't reach $sshhost over Tailscale SSH. Check: tailscale is up on both ends; the
      remote has Tailscale SSH enabled ('tailscale set --ssh' on it); and '$sshhost' is the
      right target (a real tailnet node). Test it directly: tailscale ssh $sshhost"
  fi

  # 1. try the git path unless --copy forces the rsync fallback
  if [[ "$copy" == 0 ]] && url="$(git -C "$FLEET_HOME" remote get-url origin 2>/dev/null)"; then
    echo "  git clone/pull $rdest on the remote…"
    # $rprep/$rdest carry literal $HOME/$(id …) that expand on the REMOTE (they came
    # from single-quoted vars, so bash doesn't re-expand them here); url is quoted locally.
    if tailscale ssh "$sshhost" "set -e
$rprep
DIR=$rdest
command -v git >/dev/null || { echo 'remote: git not installed' >&2; exit 1; }
if [ -d \"\$DIR/.git\" ]; then git -C \"\$DIR\" pull --ff-only; else git clone $(printf '%q' "$url") \"\$DIR\"; fi"; then
      copy=-1   # git succeeded
    else
      echo "  remote clone/pull failed — falling back to copying this checkout"
    fi
  fi

  # 2. rsync fallback (copy=1 forced, or the git path failed => copy still 0/1)
  if [[ "$copy" != -1 ]]; then
    command -v rsync >/dev/null || die "rsync not installed (needed for the --copy fallback)"
    echo "  rsync this checkout -> ${rsync_target}…"
    tailscale ssh "$sshhost" "$rprep" || die "could not prepare $rdest on the remote"
    rsync -az --delete \
      --exclude='tray/Fleet.app' --exclude='tray/fleet-tray' --exclude='tray/*.icns' \
      --exclude='.superpowers' --exclude='.DS_Store' \
      -e 'tailscale ssh' "$FLEET_HOME/" "$rsync_target" \
      || die "rsync over Tailscale failed (does the remote have Tailscale SSH enabled? 'tailscale set --ssh' on it)"
  fi

  # 3. run the installer on the remote (server mode; location baked in)
  echo "  running installer on $sshhost (location=$loc)"
  exec tailscale ssh "$sshhost" "FLEET_LOCATION=$(printf '%q' "$loc") $rdest/install.sh"
}

# fleet config [path|edit|validate|push [host]] — the consolidated fleet.json.
cmd_config() {
  case "${1:-path}" in
    path)     printf '%s\n' "$FLEET_JSON" ;;
    edit)     "${EDITOR:-vi}" "$FLEET_JSON" ;;
    validate) config_validate ;;
    push)     shift; config_push "$@" ;;
    *)        die "usage: fleet config [path|edit|validate|push [host]]" ;;
  esac
}

# config_validate — sanity-check fleet.json: valid JSON, known keys (catches typos
# that would otherwise silently default), and value types. Non-zero on any issue.
config_validate() {
  command -v jq >/dev/null || die "jq required"
  [[ -r "$FLEET_JSON" ]] || die "no config at $FLEET_JSON"
  jq -e . "$FLEET_JSON" >/dev/null 2>&1 || die "invalid JSON: $FLEET_JSON"
  local issues=0 line bad
  bad="$(jq -r '(keys) - ["mode","location","model","permissionMode","harness","general","agents","hosts","install"] | .[]' "$FLEET_JSON")"
  [[ -n "$bad" ]] && { echo "  ! unknown top-level key(s): $(echo $bad | tr '\n' ' ')"; issues=$((issues + 1)); }
  jq -e '(.mode // "server") | (. == "server" or . == "client")' "$FLEET_JSON" >/dev/null 2>&1 \
    || { echo "  ! mode must be \"server\" or \"client\""; issues=$((issues + 1)); }
  jq -e '(.general.count // 0) | type == "number"' "$FLEET_JSON" >/dev/null 2>&1 \
    || { echo "  ! general.count must be a number"; issues=$((issues + 1)); }
  while IFS= read -r line; do
    [[ -n "$line" ]] && { echo "  ! $line"; issues=$((issues + 1)); }
  done < <(jq -r '
    (.agents // {}) | to_entries[] | .key as $n | .value as $v |
    ((($v | keys) - ["repo","chrome","remoteControl","model","permissionMode","harness"]) | .[] | "agent \($n): unknown key \"\(.)\""),
    (select($v.harness != null and (["claude","codex"] | index($v.harness) | not)) | "agent \($n): harness \"\($v.harness)\" not in claude/codex"),
    (select($v.chrome != null and ($v.chrome|type) != "boolean") | "agent \($n): chrome must be true/false"),
    (select($v.remoteControl != null and ($v.remoteControl|type) != "boolean") | "agent \($n): remoteControl must be true/false"),
    (select($v.permissionMode != null and (["default","acceptEdits","plan","bypassPermissions"] | index($v.permissionMode) | not)) | "agent \($n): permissionMode \"\($v.permissionMode)\" not in default/acceptEdits/plan/bypassPermissions")
  ' "$FLEET_JSON")
  if [[ "$issues" == 0 ]]; then echo "config valid ✓  ($FLEET_JSON — ${#AGENTS[@]} agents, ${#FLEET_HOSTS[@]} hosts)"
  else echo "$issues issue(s) in $FLEET_JSON"; return 1; fi
}

# config_push [--restart] [host] — ship this machine's fleet.json to the remote(s)
# over Tailscale SSH, jq-merging so each remote KEEPS its own mode + location. No
# host ⇒ every host in the roster. --restart relaunches the remote fleet to apply
# to already-running agents (otherwise config only affects the next `fleet start`).
config_push() {
  command -v tailscale >/dev/null || die "tailscale not installed"
  command -v jq >/dev/null || die "jq required"
  [[ -r "$FLEET_JSON" ]] || die "no config at $FLEET_JSON"
  local restart=0 args=() a
  for a in "$@"; do [[ "$a" == --restart ]] && restart=1 || args+=("$a"); done
  local roster targets=() h host sshhost remote
  roster="$(jq -c 'del(.mode, .location)' "$FLEET_JSON")"   # drop per-machine keys
  if [[ -n "${args[0]:-}" ]]; then targets=("$(resolve_host "${args[0]}")")
  else for h in "${FLEET_HOSTS[@]}"; do targets+=("${h#*:}"); done; fi
  [[ ${#targets[@]} -gt 0 ]] || die "no hosts to push to (add some: fleet hosts add <short> <host>)"
  remote='set -e
f="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/fleet.json"; mkdir -p "$(dirname "$f")"; [ -f "$f" ] || echo "{}" > "$f"
command -v jq >/dev/null || { echo "  remote: jq not installed" >&2; exit 1; }
jq -s ".[0] * .[1]" "$f" - > "$f.tmp" && mv "$f.tmp" "$f" && echo "  config updated"'
  # --restart relaunches via `up` (claude --continue) so agents RESUME their
  # conversations under the new config, rather than starting cold.
  [[ "$restart" == 1 ]] && remote="$remote"'
if command -v fleet >/dev/null 2>&1; then F=fleet; else F="$(cat ~/.config/fleet/home 2>/dev/null || echo ~/.fleet)/bin/fleet.sh"; fi; $F stop 2>/dev/null || true; $F up >/dev/null 2>&1 && echo "  fleet restarted (conversations resumed)"'
  for host in "${targets[@]}"; do
    [[ "$host" == *@* ]] && sshhost="$host" || sshhost="$FLEET_SSH_USER@$host"
    echo "config push -> $sshhost  (keeps its mode/location$([[ "$restart" == 1 ]] && echo ', will restart'))"
    printf '%s' "$roster" | tailscale ssh "$sshhost" "$remote" || echo "  push to $sshhost failed"
  done
  [[ "$restart" == 0 ]] && echo "(restart remotes to apply to running agents: add --restart, or 'fleet start' there)"
}

# fleet tray {start|stop|status|enable-autostart|disable-autostart}
# The menubar monitor. Runs on client OR server. Autostart is OPT-IN.
# Clear fleet's own config + wiring (not the provisioned deps/CLIs) so init starts fresh.
_reset_fleet() {
  echo "── init --reset: clearing fleet config + wiring ──"
  tmux kill-session -t "$SESSION" 2>/dev/null && echo "  killed the running session" || true
  rm -f "$_cfgdir/fleet.json" "$_cfgdir/mode" "$_cfgdir/location" "$_cfgdir/tmux.conf" && echo "  removed config"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [[ -f "$rc" ]] && grep -qE 'Claude Code agent fleet|FLEET_HOME|fleet\.bashrc' "$rc" 2>/dev/null || continue
    grep -vE 'Claude Code agent fleet|FLEET_HOME|FLEET_LOCATION|fleet\.bashrc' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc" && echo "  cleaned $(basename "$rc")"
  done
  [[ -f "$HOME/.tmux.conf" ]] && grep -qE 'source-file.*fleet' "$HOME/.tmux.conf" 2>/dev/null && {
    grep -vE 'source-file.*fleet' "$HOME/.tmux.conf" > "$HOME/.tmux.conf.tmp" && mv "$HOME/.tmux.conf.tmp" "$HOME/.tmux.conf"; }
  rm -f "$HOME/.config/autostart/fleet.desktop" "$HOME/.config/autostart/fleet-tray.desktop"
  [[ "$(uname -s)" == Darwin ]] && rm -f "$HOME/Library/LaunchAgents/com.anivk.fleet.plist" "$HOME/Library/LaunchAgents/com.anivk.fleet-tray.plist"
  local cfg="$HOME/.claude/settings.json"
  [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1 && jq 'if .hooks then (.hooks |= (with_entries(.value |= map(select(.__fleet != true))) | with_entries(select((.value|length)>0)))) else . end' "$cfg" > "$cfg.tmp" 2>/dev/null && mv "$cfg.tmp" "$cfg" && echo "  cleared Claude hooks"
  echo
}

# fleet init [server|client] [location] [--reset] — one command: provision (bootstrap,
# server only) + wire fleet (install). Idempotent, so safe to re-run; --reset wipes the
# existing fleet config + wiring first for a clean redo.
cmd_init() {
  local mode="" loc="" reset=0 bflags=() a
  for a in "$@"; do
    case "$a" in
      server|client) mode="$a" ;;
      --reset)       reset=1 ;;
      -*)            bflags+=("$a") ;;
      *)             loc="$a" ;;
    esac
  done
  [[ -z "$mode" ]] && mode="$(jq -r '.mode // "server"' "$FLEET_JSON" 2>/dev/null || echo server)"
  [[ "$reset" == 1 ]] && _reset_fleet
  if [[ "$mode" == server ]]; then   # a client needs no agent stack, so no bootstrap
    echo "── init: provisioning the machine (bootstrap) ──"
    "$FLEET_HOME/bootstrap/bootstrap.sh" "${bflags[@]}" || die "bootstrap failed"
    echo
  fi
  echo "── init: wiring fleet (install $mode) ──"
  exec "$FLEET_HOME/install.sh" "$mode" ${loc:+"$loc"}
}

# Ensure the agent CLIs the roster needs are logged in — called by `fleet start`.
# Prompts interactively (device flow) when there's a TTY; otherwise just warns so an
# autostart/boot never blocks on login. codex is only checked if an agent uses it.
_claude_authed() { [[ -f "$HOME/.claude/.credentials.json" ]] || grep -qs oauthAccount "$HOME/.claude.json" 2>/dev/null || [[ -n "${ANTHROPIC_API_KEY:-}" ]]; }
_codex_authed()  { "$CODEX" login status 2>&1 | grep -qiE 'logged in (using|with|as|via)' || [[ -n "${OPENAI_API_KEY:-}" ]]; }
ensure_logins() {
  if command -v "$CLAUDE" >/dev/null 2>&1 && ! _claude_authed; then
    if [[ -t 0 ]]; then echo "fleet: claude not logged in — logging you in…"; "$CLAUDE" login || true
    else echo "fleet: claude not logged in — run 'claude login' then 'fleet start'" >&2; fi
  fi
  local uses_codex=0 i
  for i in "${!AGENTS[@]}"; do [[ "${A_HARNESS[$i]:-claude}" == codex ]] && uses_codex=1; done
  if [[ "$uses_codex" == 1 ]] && command -v "$CODEX" >/dev/null 2>&1 && ! _codex_authed; then
    if [[ -t 0 ]]; then echo "fleet: codex not logged in…"; "$CODEX" login --device-auth || true
    else echo "fleet: codex not logged in — run 'codex login --device-auth'" >&2; fi
  fi
}

# fleet boot {enable|disable|status} — start the fleet on BOOT, before any login
# (Linux/systemd). Unlike the XDG login-autostart (which only fires on graphical
# login), this installs a systemd *user* service + enables linger, so a headless
# server comes up with its fleet already running. Note: --chrome browser agents
# need a graphical session, so this suits non-chrome agents (or a virtual display).
cmd_boot() {
  local sub=${1:-status} user xvfb=0 a; user="$(id -un)"
  for a in "$@"; do [[ "$a" == --xvfb ]] && xvfb=1; done
  [[ "$(uname -s)" == Linux ]] || die "fleet boot is Linux/systemd only (macOS starts agents via the login autostart)"
  command -v systemctl >/dev/null 2>&1 || die "systemd not found (systemctl) — can't install a boot service"
  local udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  local unit="$udir/fleet.service" xunit="$udir/fleet-xvfb.service"
  local fbin="${FLEET_BIN:-}"; [[ -z "$fbin" || "$fbin" == *.sh ]] && fbin="$(command -v fleet 2>/dev/null || echo "$FLEET_HOME/bin/fleet.sh")"
  case "$sub" in
    enable|on)
      mkdir -p "$udir"
      local xdeps="" xenv=""
      # --xvfb: run a virtual X display so --chrome (Chrome + the Claude Code
      # extension) works with nobody logged in. Regular Chrome under Xvfb — not
      # --headless — so the extension loads normally.
      if [[ "$xvfb" == 1 ]]; then
        command -v Xvfb >/dev/null 2>&1 || echo "  ! Xvfb not installed — run: fleet init --with-xvfb"
        cat > "$xunit" <<XU
[Unit]
Description=Xvfb virtual display for fleet browser agents

[Service]
ExecStart=$(command -v Xvfb 2>/dev/null || echo /usr/bin/Xvfb) :99 -screen 0 1920x1080x24 -nolisten tcp
Restart=always

[Install]
WantedBy=default.target
XU
        xdeps=$'Requires=fleet-xvfb.service\nAfter=fleet-xvfb.service'
        xenv='Environment=DISPLAY=:99'
      else
        rm -f "$xunit"
      fi
      cat > "$unit" <<UNIT
[Unit]
Description=fleet — Claude Code agent fleet
After=network-online.target
Wants=network-online.target
$xdeps

[Service]
Type=oneshot
RemainAfterExit=yes
$xenv
ExecStart=$fbin up
ExecStop=$fbin stop

[Install]
WantedBy=default.target
UNIT
      systemctl --user daemon-reload
      [[ "$xvfb" == 1 ]] && { systemctl --user enable fleet-xvfb.service >/dev/null 2>&1 && echo "  + fleet-xvfb.service enabled (DISPLAY=:99)"; }
      systemctl --user enable fleet.service >/dev/null 2>&1 && echo "  + fleet.service enabled (user)"
      # linger makes the user's systemd manager (and thus fleet.service) start at
      # boot without a login. Needs root.
      if loginctl show-user "$user" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        echo "  = linger already on"
      else
        echo "  enabling linger (needs sudo) so fleet starts before login…"
        sudo loginctl enable-linger "$user" >/dev/null 2>&1 && echo "  + linger on" \
          || echo "  ! could not enable linger — run: sudo loginctl enable-linger $user"
      fi
      [[ "$xvfb" == 1 ]] && systemctl --user start fleet-xvfb.service >/dev/null 2>&1 || true
      systemctl --user start fleet.service >/dev/null 2>&1 || true
      echo "boot: fleet starts on boot (before login)."
      if [[ "$xvfb" == 1 ]]; then echo "  --chrome agents run under the Xvfb virtual display (:99)."
      else echo "  note: --chrome agents need a display — re-run with --xvfb for a headless virtual one."; fi
      ;;
    disable|off)
      systemctl --user disable --now fleet.service fleet-xvfb.service >/dev/null 2>&1 || true
      rm -f "$unit" "$xunit"; systemctl --user daemon-reload >/dev/null 2>&1 || true
      echo "boot: disabled (fleet.service removed)."
      echo "  (to also stop the user manager at boot: sudo loginctl disable-linger $user)"
      ;;
    status)
      if systemctl --user is-enabled fleet.service >/dev/null 2>&1; then
        local linger; linger="$(loginctl show-user "$user" -p Linger 2>/dev/null | cut -d= -f2)"
        echo "boot: enabled (linger=${linger:-?}) — $(systemctl --user is-active fleet.service 2>/dev/null)"
      else echo "boot: not enabled (enable with: fleet boot enable)"; fi
      ;;
    *) die "usage: fleet boot {enable [--xvfb]|disable|status}" ;;
  esac
}

# fleet caffeinate [--prevent-screen-lock] | fleet decaffeinate — keep the machine
# awake (so long-running agents aren't interrupted by sleep) across macOS + Linux.
# macOS: `caffeinate`. Linux: a `systemd-inhibit` block. A backgrounded process holds
# the assertion; the pidfile tracks it so `decaffeinate` (or `caffeinate status`) works.
_caffeine_pid() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fleet/caffeinate.pid"; }
cmd_caffeinate() {
  local lock=0 a; for a in "$@"; do case "$a" in --prevent-screen-lock) lock=1 ;; status) cmd_caffeinate_status; return ;; esac; done
  local pid; pid="$(_caffeine_pid)"; mkdir -p "$(dirname "$pid")"
  if [[ -f "$pid" ]] && kill -0 "$(cat "$pid")" 2>/dev/null; then
    echo "already caffeinated (pid $(cat "$pid"))"; return
  fi
  case "$(uname -s)" in
    Darwin)
      command -v caffeinate >/dev/null || die "caffeinate not found"
      # -i idle, -m disk, -s system(on AC); +lock: -d display + -u user-active.
      local flags="-i -m -s"; [[ "$lock" == 1 ]] && flags="-d -u $flags"
      nohup caffeinate $flags >/dev/null 2>&1 & ;;
    Linux)
      command -v systemd-inhibit >/dev/null || die "systemd-inhibit not found (systemd-logind) — can't inhibit sleep"
      # sleep = suspend/hibernate; +lock: idle too, which holds off the screensaver/lock.
      local what="sleep"; [[ "$lock" == 1 ]] && what="sleep:idle"
      nohup systemd-inhibit --what="$what" --who=fleet --why="fleet caffeinate" --mode=block sleep infinity >/dev/null 2>&1 & ;;
    *) die "caffeinate: unsupported OS ($(uname -s))" ;;
  esac
  echo $! > "$pid"
  echo "caffeinated (pid $!) — sleep prevented$([[ "$lock" == 1 ]] && echo ' + screen lock')"
  echo "  stop with: fleet decaffeinate"
}
cmd_decaffeinate() {
  local pid; pid="$(_caffeine_pid)"
  if [[ -f "$pid" ]]; then
    local p; p="$(cat "$pid")"
    pkill -P "$p" 2>/dev/null || true      # the systemd-inhibit `sleep infinity` child
    kill "$p" 2>/dev/null && echo "decaffeinated" || echo "not caffeinated (removed stale pidfile)"
    rm -f "$pid"
  else echo "not caffeinated"; fi
}
cmd_caffeinate_status() {
  local pid; pid="$(_caffeine_pid)"
  if [[ -f "$pid" ]] && kill -0 "$(cat "$pid")" 2>/dev/null; then echo "caffeinated (pid $(cat "$pid"))"
  else echo "not caffeinated"; fi
}

# Generate a minimal Fleet.app wrapper around `<fbin> tray run` so macOS shows the
# menubar agent as "Fleet" with NO Dock icon (LSUIElement). Regenerated each start,
# so it always points at the current binary.
_make_tray_app() {
  local app=$1 fbin=$2
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fleet</string>
  <key>CFBundleIdentifier</key><string>com.anivk.fleet</string>
  <key>CFBundleExecutable</key><string>fleet-tray</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
  printf '#!/bin/sh\nexec %q tray run\n' "$fbin" > "$app/Contents/MacOS/fleet-tray"
  chmod +x "$app/Contents/MacOS/fleet-tray"
}

cmd_tray() {
  local sub=${1:-status}
  local pid="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/tray.pid"
  local app="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/Fleet.app" apppat="Fleet.app/Contents/MacOS/fleet-tray"
  mkdir -p "$(dirname "$pid")"
  # The tray lives inside the fleet binary — `fleet tray run`. Resolve the binary:
  # FLEET_BIN (set when invoked via the binary), else `fleet` on PATH, else a dev build.
  local fbin="${FLEET_BIN:-}"
  [[ -z "$fbin" || "$fbin" == *.sh ]] && fbin="$(command -v fleet 2>/dev/null || true)"
  [[ -x "$fbin" ]] || fbin="$FLEET_HOME/fleet"
  local mac=0; [[ "$(uname -s)" == Darwin ]] && mac=1
  case "$sub" in
    start)
      [[ -x "$fbin" ]] || die "no fleet binary for the tray — build it: (cd $FLEET_HOME && go build -o fleet .)"
      if [[ $mac == 1 ]]; then
        pgrep -f "$apppat" >/dev/null 2>&1 && { echo "tray already running (Fleet.app)"; return; }
        _make_tray_app "$app" "$fbin"
        open "$app" && echo "tray started (Fleet.app)"
      else
        if [[ -f "$pid" ]] && kill -0 "$(cat "$pid")" 2>/dev/null; then echo "tray already running (pid $(cat "$pid"))"; return; fi
        nohup "$fbin" tray run >/dev/null 2>&1 &
        echo $! > "$pid"; echo "tray started (pid $!)"
      fi ;;
    stop)
      if [[ $mac == 1 ]]; then
        pkill -f "$apppat" 2>/dev/null && echo "tray stopped" || echo "tray not running"
      elif [[ -f "$pid" ]]; then
        kill "$(cat "$pid")" 2>/dev/null && echo "tray stopped" || echo "tray not running (removed stale pidfile)"
        rm -f "$pid"
      else echo "tray not running"; fi ;;
    status)
      if [[ $mac == 1 ]]; then
        pgrep -f "$apppat" >/dev/null 2>&1 && echo "tray running (Fleet.app)" || echo "tray not running"
      elif [[ -f "$pid" ]] && kill -0 "$(cat "$pid")" 2>/dev/null; then echo "tray running (pid $(cat "$pid"))"; else echo "tray not running"; fi ;;
    enable-autostart)  tray_autostart on ;;
    disable-autostart) tray_autostart off ;;
    *) die "usage: fleet tray {start|stop|status|enable-autostart|disable-autostart}" ;;
  esac
}

# Opt-in login autostart for the TRAY (separate from agent autostart).
tray_autostart() {
  local on=$1
  # Resolve the fleet binary (same as cmd_tray).
  local fbin="${FLEET_BIN:-}"
  [[ -z "$fbin" || "$fbin" == *.sh ]] && fbin="$(command -v fleet 2>/dev/null || true)"
  [[ -x "$fbin" ]] || fbin="$FLEET_HOME/fleet"
  case "$(uname -s)" in
    Darwin)
      local pl="$HOME/Library/LaunchAgents/com.anivk.fleet-tray.plist"
      mkdir -p "$(dirname "$pl")"
      if [[ "$on" == on ]]; then
        # Launch via `fleet tray start`, which (re)generates Fleet.app and opens it
        # so the login item is attributed to "Fleet" with no Dock icon.
        cat > "$pl" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.anivk.fleet-tray</string>
  <key>ProgramArguments</key><array>
    <string>$fbin</string><string>tray</string><string>start</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
        echo "tray autostart enabled ($pl)"
      else rm -f "$pl"; echo "tray autostart disabled"; fi ;;
    Linux)
      local as="$HOME/.config/autostart/fleet-tray.desktop"
      if [[ "$on" == on ]]; then
        mkdir -p "$(dirname "$as")"
        { echo "[Desktop Entry]"; echo "Type=Application"; echo "Name=Fleet Tray"
          echo "Exec=$fbin tray start"; echo "X-GNOME-Autostart-enabled=true"; } > "$as"
        echo "tray autostart enabled ($as)"
      else rm -f "$as"; echo "tray autostart disabled"; fi ;;
  esac
}

# fleet send <agent> <text...> — type text into a running agent's pane, then Enter.
cmd_send() {
  local in=${1:-}; [[ -n "$in" ]] && shift || true
  local text="$*"
  [[ -n "$in" && -n "$text" ]] || die "usage: fleet send <agent> <text>"
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  local dname pane; dname="$(disp "$(short "$in")")"; pane="$(pane_for "$dname")"
  [[ -n "$pane" ]] || die "no running agent: $dname (see: fleet status)"
  tmux send-keys -t "$pane" -l "$text"; tmux send-keys -t "$pane" Enter
  echo "sent to $dname"
}

# fleet key <agent> <key...> — send tmux key(s) (Enter, Escape, "1", …) to an agent.
# Used by the tray's Approve action; also handy from the CLI.
cmd_key() {
  local in=${1:-}; [[ -n "$in" ]] && shift || true
  [[ -n "$in" && $# -gt 0 ]] || die "usage: fleet key <agent> <key> [key...]   (e.g. Enter, Escape, 1)"
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  local dname pane; dname="$(disp "$(short "$in")")"; pane="$(pane_for "$dname")"
  [[ -n "$pane" ]] || die "no running agent: $dname"
  tmux send-keys -t "$pane" "$@"
  echo "keys -> $dname: $*"
}

# fleet broadcast <text...> — send the same text to every RUNNING agent (every
# @agent-tagged pane), not just the configured roster.
cmd_broadcast() {
  local text="$*"; [[ -n "$text" ]] || die "usage: fleet broadcast <text>"
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  local pane n=0
  while read -r pane; do
    [[ -n "$pane" ]] || continue
    tmux send-keys -t "$pane" -l "$text"; tmux send-keys -t "$pane" Enter; n=$((n + 1))
  done < <(tmux list-panes -s -t "$SESSION" -F '#{@agent}=#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | awk -F= '$1!=""{print $2}')
  echo "broadcast to $n agent(s)"
}

# fleet log <agent> [lines] — recent output from an agent's pane (default 40).
cmd_log() {
  local in=${1:-} lines=${2:-40} dname pane
  [[ -n "$in" ]] || die "usage: fleet log <agent> [lines]"
  tmux has-session -t "$SESSION" 2>/dev/null || die "fleet not running"
  dname="$(disp "$(short "$in")")"; pane="$(pane_for "$dname")"
  [[ -n "$pane" ]] || die "no running agent: $dname"
  tmux capture-pane -p -t "$pane" -S "-$lines"
}

# fleet doctor — health check for this machine (tools, config, hooks, tray, hosts).
cmd_doctor() {
  local ok="✓" bad="✗"
  _chk() { command -v "$1" >/dev/null 2>&1 && echo "  $ok $1" || echo "  $bad $1 — $2"; }
  echo "fleet doctor — $(disp "" | sed 's/-$//'), $MODE mode"
  echo "tools:"; _chk tmux "sudo apt install tmux / brew install tmux"; _chk "$CLAUDE" "Claude Code CLI not on PATH"
  _chk jq "install jq — the config needs it"; _chk git "install git"; _chk tailscale "install tailscale (for remote)"
  echo "config:"
  if [[ -r "$FLEET_JSON" ]] && jq -e . "$FLEET_JSON" >/dev/null 2>&1; then
    echo "  $ok fleet.json valid — ${#AGENTS[@]} agents, ${#FLEET_HOSTS[@]} hosts"
  else echo "  $bad fleet.json missing/invalid: $FLEET_JSON (re-run install.sh)"; fi
  if jq -e '.hooks.Stop' "$HOME/.claude/settings.json" >/dev/null 2>&1; then echo "  $ok Claude hooks wired"
  else echo "  · Claude hooks not wired (server: fleet install-hooks)"; fi
  if [[ -x "$FLEET_HOME/tray/fleet-tray" || -d "$FLEET_HOME/tray/Fleet.app" ]]; then echo "  $ok tray built"
  else echo "  · tray not built (needs Go)"; fi
  # auth: heuristic — API-key env, a stored credential file, or (mac) the keychain
  # entry. Flags a fresh box that still needs `claude login` / `codex login`.
  echo "auth:"
  if command -v "$CLAUDE" >/dev/null 2>&1; then
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo "  $ok claude — ANTHROPIC_API_KEY set"
    elif grep -qs '"oauthAccount"' "$HOME/.claude.json" 2>/dev/null || [[ -f "$HOME/.claude/.credentials.json" ]] \
      || { [[ "$(uname -s)" == Darwin ]] && security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; }; then
      echo "  $ok claude logged in"
    else echo "  $bad claude not logged in — run: claude login"; fi
  fi
  if command -v "$CODEX" >/dev/null 2>&1; then
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then echo "  $ok codex — OPENAI_API_KEY set"
    elif [[ -f "$HOME/.codex/auth.json" ]]; then echo "  $ok codex logged in"
    else echo "  $bad codex not logged in — run: codex login"; fi
  fi
  if [[ ${#FLEET_HOSTS[@]} -gt 0 ]] && command -v tailscale >/dev/null; then
    echo "hosts:"; local h host
    for h in "${FLEET_HOSTS[@]}"; do host="${h#*:}"
      if tailscale ssh -o ConnectTimeout=5 "$FLEET_SSH_USER@$host" true 2>/dev/null; then echo "  $ok ${h%%:*} ($host)"
      else echo "  $bad ${h%%:*} ($host) — unreachable (tailscale up? 'tailscale set --ssh' there?)"; fi
    done
  fi
}

# fleet run [--repo <owner/repo>] <task...> — ephemeral one-shot agent: run the task
# headless (claude -p) in a throwaway workspace with the fleet defaults, then tear down.
cmd_run() {
  local repo="" args=()
  while [[ $# -gt 0 ]]; do case "$1" in --repo) repo="${2:-}"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
  local task="${args[*]}"
  [[ -n "$task" ]] || die "usage: fleet run [--repo <owner/repo>] <task>"
  command -v "$CLAUDE" >/dev/null || die "claude not found: $CLAUDE"
  local base dir cleanup rc
  base="$(mktemp -d)"; cleanup="$base"
  if [[ -n "$repo" ]]; then
    dir="$base/${repo##*/}"
    echo "run: cloning ${repo}…" >&2
    git clone --depth 1 "${FLEET_GIT_BASE:-git@github.com:}$repo.git" "$dir" >&2 || die "clone failed"
  else dir="$base"; fi
  echo "run: \"$task\"  (model=$_DEF_MODEL, permission=$_DEF_PMODE)" >&2
  ( cd "$dir" && "$CLAUDE" -p "$task" --model "$_DEF_MODEL" --permission-mode "$_DEF_PMODE" ); rc=$?
  rm -rf "$cleanup"
  return $rc
}

# fleet help — the full command reference, grouped so it's actually readable.
cmd_help() {
  cat <<'HELP'
fleet — an orchestrator and operator for Claude Code and Codex agents, local and remote.

LAUNCH & LIFECYCLE
  fleet start [--fresh]              launch all agents (resumes convos; --fresh = cold)
  fleet stop                        kill the session (the only thing that stops agents)
  fleet restart [--restart-fresh] <agent>   restart one agent in place (resumes)
  fleet respawn [host]              revive dead agents + start any missing (local or a host)
  fleet boot {enable [--xvfb]|disable}   start on boot before login (Linux); --xvfb runs --chrome agents headless
  fleet caffeinate [--prevent-screen-lock] / decaffeinate   keep the machine awake (macOS + Linux)

DRIVE AGENTS  (no need to attach)
  fleet send <agent> <text>         type text into an agent, then Enter
  fleet broadcast <text>            send text to every running agent
  fleet key <agent> <key>...        send keystrokes (Enter, Escape, 1, …)
  fleet log <agent> [n]             recent output from an agent (default 40 lines)
  fleet run [--repo o/r] <task>     one-shot ephemeral agent (claude -p), torn down after

WATCH
  fleet                             overview: local agents + remote machines (= status/ls)
  fleet attach [agent]              attach the tmux session (jump to an agent's pane)
  fleet grid / fleet spread         tile the live panes into a dashboard / undo
  fleet tray {start|stop|status|enable-autostart}    the menubar app
  fleet doctor                      health check: tools, config, auth, hosts

CONFIG  (~/.config/fleet/fleet.json — schema in the README)
  fleet init [server|client] [location] [--reset]   provision (server) + wire fleet in one; --reset redoes clean
  fleet setup <owner>/<repo> [count]   clone repo agents + add them to the config
  fleet config {path|edit|validate|push [--restart] [host]}
  fleet hosts {ls|add <short> [host]|rm <short>|scan [--add]}

REMOTE  (over Tailscale SSH)
  fleet remote [ls | <host>]        list hosts / attach a machine's running fleet
  fleet remote-ssh <host> [cmd]     a plain shell (or one command) on a remote
  fleet remote-install [--copy] <host> [loc]   provision fleet on a fresh machine
  fleet update [--no-clis] [host]   pull latest + upgrade CLIs (local, or a remote)
  fleet keys {forward [on|off]|setup <host>|check <host>}   let remote git use your keys

MODES  (per-machine, in "mode" — never pushed by `config push`)
  server    runs its own agents + autostarts on login (desktops / VMs)
  client    only watches & drives remotes — no local agents, no autostart (a laptop)
            switch with: fleet config edit   →   "mode": "server" | "client"

CONFIG KEYS  (~/.config/fleet/fleet.json — full schema in the README)
  mode / location            server|client · short tag in agent names: <owner>-<loc>-<name>
  general.count              how many scratch agents (agent-A, agent-B, … in empty dirs)
  general.chrome / .remoteControl   defaults every agent inherits
  agents.<name>              repo · model (opus) · permissionMode (bypassPermissions)
                             harness (claude|codex) · chrome · remoteControl   (no repo = scratch)
  hosts.<short>              tailnet hostname for `fleet remote` + the tray
  install.deps / .clis       what `remote-install` / `update` provision on a box
HELP
  echo "Docs: $FLEET_HOME/README.md   ·   config: $FLEET_JSON   ·   this machine: mode=${MODE:-server}"
}

# Allow tests to source this file for its helper functions without dispatching.
[[ -n "${FLEET_SOURCE_ONLY:-}" ]] && return 0 2>/dev/null || true

case "${1:-start}" in
  setup)   shift; cmd_setup "$@" ;;      # clone the repo N times + save the roster
  init)      shift; cmd_init "$@" ;;     # provision + wire fleet, in one (bootstrap then install)
  install-hooks) cmd_install_hooks ;;    # wire Claude hooks (server machines)
  hook)    shift; exec "$FLEET_HOME/hooks/fleet-hook.sh" "$@" ;;  # Claude hook event -> state file
  start)   shift; cmd_start "$@" ;;      # resume by default; --fresh for a cold start
  up)      FLEET_RESUME=1 cmd_start ;;   # explicit resume (login/boot auto-start; now == start)
  remote)  shift; cmd_remote "$@" ;;     # attach another machine's fleet over tailscale
  remote-ssh) shift; cmd_remote_ssh "$@" ;;  # a plain shell (or command) on a remote
  rdp-reset) shift; cmd_rdp_reset "$@" ;;    # clear hung RDP graphical sessions ([host])
  keys)    shift; cmd_keys "$@" ;;       # remote git auth: agent forwarding + per-host keys
  remote-install) shift; cmd_remote_install "$@" ;;  # clone + install fleet on a remote
  tray)    shift; cmd_tray "$@" ;;       # menubar monitor (start/stop/status/…)
  boot)    shift; cmd_boot "$@" ;;       # start on boot before login (Linux/systemd)
  caffeinate)   shift; cmd_caffeinate "$@" ;;  # keep the machine awake (mac + linux)
  decaffeinate) cmd_decaffeinate ;;            # let it sleep again
  hosts)   shift; cmd_hosts "$@" ;;      # list/add/rm remote hosts (or --json for the tray)
  config)  shift; cmd_config "$@" ;;     # fleet.json: path | edit | push [host]
  send)    shift; cmd_send "$@" ;;       # type text into a running agent's pane
  key)     shift; cmd_key "$@" ;;        # send a tmux key (Enter/Escape/…) to an agent
  broadcast) shift; cmd_broadcast "$@" ;; # send text to every running agent
  log)     shift; cmd_log "$@" ;;        # recent output from an agent's pane
  doctor)  cmd_doctor ;;                 # health check (tools/config/hooks/hosts)
  run)     shift; cmd_run "$@" ;;        # ephemeral one-shot agent (claude -p)
  update)  shift; cmd_update "$@" ;;     # pull latest + re-wire (optionally a remote host)
  grid)    cmd_grid ;;
  spread)  cmd_spread ;;
  attach)  shift; cmd_attach "$@" ;;
  status)  shift; if [[ "${1:-}" == --json ]]; then cmd_status_json; else cmd_ls; fi ;;
  ls)      cmd_ls ;;                     # overview: local agents + remote machines
  stop)    tmux kill-session -t "$SESSION" 2>/dev/null && echo "fleet stopped" || echo "fleet not running" ;;
  restart) shift; cmd_restart "$@" ;;
  respawn) shift; cmd_respawn "$@" ;;    # revive dead agents + start missing (local or host)
  version|--version|-v) echo "fleet ${FLEET_VERSION:-dev}" ;;
  help|-h|--help) cmd_help ;;            # the full command reference
  *)       die "unknown command '${1}' — run 'fleet help'" ;;
esac
