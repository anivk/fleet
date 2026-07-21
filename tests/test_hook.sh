#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TDIR=$(mktemp -d); export XDG_CONFIG_HOME="$TDIR/cfg" FLEET_AGENT=my-nyc-space-9
trap 'rm -rf "$TDIR"' EXIT
SF="$XDG_CONFIG_HOME/fleet/state/$FLEET_AGENT"

echo '{"hook_event_name":"UserPromptSubmit"}' | hooks/fleet-hook.sh working
contains "working written" "$(cat "$SF")" 'status=working'
contains "working not alert" "$(cat "$SF")" 'alert=0'

echo '{"hook_event_name":"Notification"}' | hooks/fleet-hook.sh waiting
contains "waiting written" "$(cat "$SF")" 'status=waiting'
contains "waiting alerts"  "$(cat "$SF")" 'alert=1'

# Stop: build a fixture transcript, expect summary = last assistant text (one line).
TR="$TDIR/t.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' > "$TR"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done: fixed 3 failing tests\nand more"}]}}' >> "$TR"
echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}" | hooks/fleet-hook.sh stop
contains "stop idle"    "$(cat "$SF")" 'status=idle'
contains "stop summary" "$(cat "$SF")" 'summary=Done: fixed 3 failing tests'

# Parity: jq path vs jq-absent path must agree, even with embedded \" quotes.
# Build a PATH that genuinely lacks jq: symlink only the coreutils the hook
# needs (sed/grep/head/cut/tr) into a scratch dir, skipping jq itself, since
# on some machines jq lives in the same directory as those tools (e.g.
# /usr/bin) and a coarse PATH=/usr/bin:/bin trim wouldn't hide it.
NOJQ="$TDIR/nojq"
mkdir -p "$NOJQ"
for b in sed grep head cut tr tail; do
  src="$(command -v "$b")"
  ln -s "$src" "$NOJQ/$b"
done
NOJQ_PATH="$NOJQ:/bin"
if [ -n "$(PATH="$NOJQ_PATH" command -v jq 2>/dev/null)" ]; then
  echo "SKIP parity test: could not hide jq on this machine's PATH" >&2
else
  TR2="$TDIR/t2.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"He said \"go\" now\nsecond line"}]}}' > "$TR2"
  payload="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR2\"}"

  echo "$payload" | hooks/fleet-hook.sh stop
  with_jq="$(sed -n 's/^summary=//p' "$SF")"

  echo "$payload" | PATH="$NOJQ_PATH" hooks/fleet-hook.sh stop
  without_jq="$(sed -n 's/^summary=//p' "$SF")"

  check   "jq/no-jq parity"      "$without_jq" "$with_jq"
  # Both paths pick only the first line of a multi-line assistant message
  # (head -1 runs before the final newline->space collapse), so the second
  # line never appears here -- the point of this fixture is the preserved
  # embedded quote, not multi-line collapsing.
  check   "parity exact summary" "$with_jq" 'He said "go" now'
fi

summary
