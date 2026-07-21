# Minimal test harness for fleet's bash. Source it; call check/expect; run summary.
#
# Hermetic first: fleet.sh lets FLEET_* env vars OVERRIDE fleet.json (e.g. line 80,
# LOCATION="${FLEET_LOCATION:-…}"). On a dev machine that is itself a fleet node those
# are exported by install.sh into the shell rc, so they'd silently shadow every fixture
# and fail assertions that have nothing to do with the change under test. Clear them —
# tests that want an override set it explicitly on the invocation. FLEET_HOME is left
# alone: it legitimately points at the repo under test.
unset FLEET_LOCATION FLEET_MODE FLEET_MODEL FLEET_PERMISSION_MODE FLEET_HARNESS \
      FLEET_JSON FLEET_OWNER FLEET_TMUX_SESSION FLEET_TMUX_SOCK FLEET_REMOTE_CONTROL
_T_PASS=0; _T_FAIL=0
check() { # check <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "$1"
  else _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"; fi
}
contains() { # contains <desc> <haystack> <needle>
  case "$2" in *"$3"*) _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "$1";;
  *) _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n       %s\n       not in output\n' "$1" "$3";; esac
}
summary() { printf '\n%d passed, %d failed\n' "$_T_PASS" "$_T_FAIL"; [ "$_T_FAIL" -eq 0 ]; }
