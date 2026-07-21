#!/usr/bin/env bash
# Locks in the fleet.json config system: roster loading, per-agent launch flags
# (model / permission-mode / remote-control / chrome / scratch), and validation.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fleet"
cat > "$T/fleet/fleet.json" <<'JSON'
{ "mode": "server", "location": "nyc",
  "general": { "count": 2, "chrome": true, "remoteControl": false },
  "agents": {
    "space-1": { "repo": "org/space", "remoteControl": true },
    "space-2": { "repo": "org/space", "chrome": false, "model": "sonnet" },
    "codex-1": { "repo": "org/space", "harness": "codex" },
    "scratch": {} },
  "hosts": { "nyc": "my-box" } }
JSON

# --- load the roster and per-agent launch commands ---
out="$(XDG_CONFIG_HOME="$T" FLEET_OWNER=my FLEET_SOURCE_ONLY=1 bash -c '
  . bin/fleet.sh
  echo "AGENTS=${AGENTS[*]}"
  echo "HOSTS=${FLEET_HOSTS[*]}"
  echo "A=$(agent_cmd agent-A)"
  echo "S1=$(agent_cmd space-1)"
  echo "S2=$(agent_cmd space-2)"
  echo "SC=$(agent_cmd scratch)"
  echo "CX=$(agent_cmd codex-1)"
')"
contains "roster: 2 general + 4 named" "$out" "AGENTS=agent-A agent-B space-1 space-2 codex-1 scratch"
contains "codex harness cmd" "$out" "CX=FLEET_AGENT=my-nyc-codex-1 codex --model gpt-5-codex --dangerously-bypass-approvals-and-sandbox"
contains "hosts loaded"                "$out" "HOSTS=nyc:my-box"
contains "default model opus"          "$out" "A=FLEET_AGENT=my-nyc-agent-A claude --model opus --permission-mode bypassPermissions -n my-nyc-agent-A --chrome"
contains "space-1 remote-control"      "$out" "S1=FLEET_AGENT=my-nyc-space-1 claude --remote-control my-nyc-space-1 --model opus"
contains "space-2 model override"      "$out" "--model sonnet"

# space-2 has chrome:false -> no --chrome; scratch (no repo) -> default chrome
s2="$(printf '%s\n' "$out" | sed -n 's/^S2=//p')"
case "$s2" in *--chrome*) check "space-2 no --chrome" HAS none ;; *) check "space-2 no --chrome" none none ;; esac
contains "scratch gets --chrome" "$out" "SC=FLEET_AGENT=my-nyc-scratch claude --model opus --permission-mode bypassPermissions -n my-nyc-scratch --chrome"

# --- validation ---
if XDG_CONFIG_HOME="$T" FLEET_JSON="$T/fleet/fleet.json" bash bin/fleet.sh config validate >/dev/null 2>&1; then
  check "validate: good config passes" ok ok; else check "validate: good config passes" FAIL ok; fi

cat > "$T/fleet/bad.json" <<'JSON'
{ "mode": "weird",
  "agents": { "x": { "repo": "a/b", "remoteContol": true, "permissionMode": "yolo" } } }
JSON
if XDG_CONFIG_HOME="$T" FLEET_JSON="$T/fleet/bad.json" bash bin/fleet.sh config validate >/dev/null 2>&1; then
  check "validate: bad config fails" FAIL nonzero; else check "validate: bad config fails" nonzero nonzero; fi
# and that it names the problems
bad_out="$(XDG_CONFIG_HOME="$T" FLEET_JSON="$T/fleet/bad.json" bash bin/fleet.sh config validate 2>&1 || true)"
contains "flags unknown key (typo)"  "$bad_out" "unknown key"
contains "flags bad permissionMode"  "$bad_out" "permissionMode"
contains "flags bad mode"            "$bad_out" "mode must be"

summary
