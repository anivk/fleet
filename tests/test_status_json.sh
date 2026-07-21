#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }

TDIR=$(mktemp -d); export XDG_CONFIG_HOME="$TDIR/cfg"
mkdir -p "$XDG_CONFIG_HOME/fleet/state"
S=fleet_test_$$; export FLEET_TMUX_SESSION="$S" FLEET_OWNER=my FLEET_LOCATION=nyc
# fleet pins its tmux socket; build the test session on that same socket so status
# scrapes it. Exported so the fleet.sh subprocess reads the same socket.
export FLEET_TMUX_SOCK="/tmp/fleet_test_$$.sock"
tmux(){ command tmux -S "$FLEET_TMUX_SOCK" "$@"; }
cleanup(){ tmux kill-session -t "$S" 2>/dev/null; rm -rf "$TDIR"; }; trap cleanup EXIT

# Two panes, tagged like real agents; both just sleep.
tmux new-session -d -s "$S" -n my-nyc-space-1 'sleep 60'
tmux set-option -p -t "$S:my-nyc-space-1" @agent my-nyc-space-1
tmux new-window  -d -t "$S" -n my-nyc-space-2 'sleep 60'
tmux set-option -p -t "$S:my-nyc-space-2" @agent my-nyc-space-2

# Fresh state file for space-2 (waiting/alert), from "hook".
cat > "$XDG_CONFIG_HOME/fleet/state/my-nyc-space-2" <<EOF
status=waiting
alert=1
since=1721430000
summary=Proceed with db migration?
EOF

# Third window: dies immediately but stays visible (remain-on-exit), with a
# FRESH state file claiming waiting/alert=1 — dead must still win.
# Set remain-on-exit GLOBALLY so the new window inherits it (a per-window set only
# affects the current window; on Linux the dead pane would otherwise be removed).
tmux set-option -g remain-on-exit on
tmux new-window -d -t "$S" -n my-nyc-space-3 'exit 0'
tmux set-option -p -t "$S:my-nyc-space-3" @agent my-nyc-space-3
cat > "$XDG_CONFIG_HOME/fleet/state/my-nyc-space-3" <<EOF
status=waiting
alert=1
since=1721430000
summary=should be overridden
EOF
sleep 0.5   # let the pane die

# Fourth window: FRESH state file with a garbage `since` value — must sanitize to 0.
tmux new-window -d -t "$S" -n my-nyc-space-4 'sleep 60'
tmux set-option -p -t "$S:my-nyc-space-4" @agent my-nyc-space-4
cat > "$XDG_CONFIG_HOME/fleet/state/my-nyc-space-4" <<EOF
status=idle
alert=0
since=N/A
summary=bad since value
EOF

out="$(FLEET_MODE=server bin/fleet.sh status --json)"
contains "has host"            "$out" '"host":"my-nyc"'
contains "space-1 present"     "$out" '"short":"space-1"'
contains "space-2 waiting"     "$out" '"status":"waiting"'
contains "space-2 alert true"  "$out" '"alert":true'
contains "space-2 summary"     "$out" 'Proceed with db migration?'
contains "space-2 from hook"   "$out" '"source":"hook"'
contains "space-1 scraped"     "$out" '"source":"scrape"'
contains "space-3 dead status"  "$out" '"status":"dead"'
contains "dead not alerting"    "$out" '"agent":"my-nyc-space-3","short":"space-3","alive":false,"status":"dead","alert":false'
contains "space-4 since sanitized" "$out" '"since":0'
# Valid JSON if python is available:
if command -v python3 >/dev/null; then
  echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' && contains "valid json" ok ok
fi
summary
