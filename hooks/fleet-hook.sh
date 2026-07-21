#!/usr/bin/env bash
# Fleet Claude-Code hook: writes ~/.config/fleet/state/$FLEET_AGENT so `fleet
# status --json` (and the tray) can show live status/alerts/summaries.
# Usage (wired in ~/.claude/settings.json):  fleet-hook.sh <working|waiting|stop>
set -uo pipefail
kind=${1:-}
agent=${FLEET_AGENT:-}
[ -n "$agent" ] || exit 0                      # untagged session: nothing to do
dir="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/state"
mkdir -p "$dir"
payload="$(cat 2>/dev/null || true)"           # Claude's hook JSON on stdin
now=$(date +%s)

status=unknown alert=0 summary=""  # safety default; unreachable in practice since the *) case below exits first
case "$kind" in
  working) status=working; alert=0 ;;
  waiting) status=waiting; alert=1 ;;
  stop)
    status=idle; alert=0
    tp="$(printf '%s' "$payload" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      if command -v jq >/dev/null 2>&1; then
        summary="$(grep '"type":"assistant"' "$tp" | tail -1 \
          | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null \
          | grep -v '^[[:space:]]*$' | head -1)"
      else
        # No jq: protect JSON \" escapes so the capture stops only at the REAL closing quote.
        line="$(grep '"type":"assistant"' "$tp" | tail -1)"
        line="${line//\\\"/$'\x01'}"                    # \" -> placeholder byte
        raw="$(printf '%s' "$line" \
          | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        # Restore the placeholder to a bare quote (not \") -- printf %b has no
        # \" escape, it would leave a literal backslash in the output, unlike jq.
        raw="${raw//$'\x01'/\"}"
        # printf %b interprets the remaining \n / \r / \t / \\ escapes the same
        # way jq -r would, so this fallback lands on the same first line jq would pick.
        summary="$(printf '%b\n' "$raw" | grep -v '^[[:space:]]*$' | head -1)"
      fi
    fi ;;
  *) exit 0 ;;
esac

# One line, trimmed to ~100 chars; strip newlines/CRs.
summary="$(printf '%s' "$summary" | tr '\r\n' '  ' | cut -c1-100 | sed 's/[[:space:]]*$//')"

tmp="$dir/.$agent.$$"                            # atomic write
{ printf 'status=%s\n' "$status"
  printf 'alert=%s\n'  "$alert"
  printf 'since=%s\n'  "$now"
  printf 'summary=%s\n' "$summary"
} > "$tmp" && mv -f "$tmp" "$dir/$agent"
