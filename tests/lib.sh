# Minimal test harness for fleet's bash. Source it; call check/expect; run summary.
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
