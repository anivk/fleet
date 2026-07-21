#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
# Load helpers from fleet.sh without running its dispatch:
export FLEET_SOURCE_ONLY=1
. bin/fleet.sh
set +e  # fleet.sh sets -e; the harness must not inherit it

check "plain"        "$(json_str 'hello')"            '"hello"'
check "quote"        "$(json_str 'say "hi"')"         '"say \"hi\""'
check "backslash"    "$(json_str 'a\b')"              '"a\\b"'
check "tab"          "$(json_str "$(printf 'a\tb')")" '"a\tb"'
check "newline-strip" "$(json_str "$(printf 'a\nb')")" '"a\nb"'
# Note: "$(printf 'a\n')" as the argument would have its trailing newline
# stripped by THAT command substitution before json_str ever sees it — so the
# input must be built without going through $(...). ANSI-C quoting does that.
_trailing_nl=$'a\n'
check "trailing-newline" "$(json_str "$_trailing_nl")" '"a\n"'

out="$(cmd_hosts --json)"
contains "hosts json is array" "$out" '['
contains "hosts json has short key" "$out" '"short"'
summary
