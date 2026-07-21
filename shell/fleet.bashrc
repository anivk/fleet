# Fleet shell integration — works in bash and zsh. FLEET_HOME points at the repo
# root: from $FLEET_HOME, else ~/.config/fleet/home (written by install.sh), else
# the shared-box default.
: "${FLEET_HOME:=$(cat "$HOME/.config/fleet/home" 2>/dev/null || echo "$HOME/.fleet")}"
fleet() { "$FLEET_HOME/bin/fleet.sh" "${@:-status}"; }

# Tab-completion is bash-only (zsh's `complete` differs). The command works in both.
if [ -n "${BASH_VERSION:-}" ]; then
  _fleet_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local pfx="$(id -un)-${FLEET_LOCATION:-local}"
    # Agent + host names come from fleet.json (needs jq); general agents are agent-A..
    local fj="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/fleet.json" names="" hosts="ls" i
    local _L="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if command -v jq >/dev/null 2>&1 && [ -r "$fj" ]; then
      local gc; gc="$(jq -r '.general.count // 0' "$fj")"
      for ((i = 0; i < gc; i++)); do names+="agent-${_L:$i:1} "; done 2>/dev/null
      names+="$(jq -r '(.agents // {}) | keys[]' "$fj" 2>/dev/null | tr '\n' ' ')"
      hosts+=" $(jq -r '(.hosts // {}) | keys[]' "$fj" 2>/dev/null | tr '\n' ' ')"
    else
      names="agent-A agent-B agent-C agent-D"
    fi
    if [ "$COMP_CWORD" -eq 1 ]; then
      COMPREPLY=($(compgen -W "init setup start attach send broadcast log run doctor respawn boot caffeinate decaffeinate remote remote-ssh keys remote-install tray hosts config update grid spread status ls stop restart help" -- "$cur"))
    elif [[ "${COMP_WORDS[1]}" =~ ^(restart|attach|send|log|key)$ ]] && [ "$COMP_CWORD" -eq 2 ]; then
      local full=""; for n in $names; do full+="$pfx-$n $n "; done
      COMPREPLY=($(compgen -W "$full" -- "$cur"))
    elif [[ "${COMP_WORDS[1]}" =~ ^(remote|remote-ssh|update|remote-install|respawn)$ ]] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
    elif [ "" = init ] && [ "" -eq 2 ]; then
      COMPREPLY=($(compgen -W "server client" -- ""))
    elif [ "${COMP_WORDS[1]}" = boot ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "enable disable status" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = caffeinate ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "--prevent-screen-lock status" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = tray ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "start stop status enable-autostart disable-autostart" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = hosts ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "ls add rm scan --json" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = hosts ] && [ "${COMP_WORDS[2]}" = rm ] && [ "$COMP_CWORD" -eq 3 ]; then
      COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = config ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "path edit validate push" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = config ] && [ "${COMP_WORDS[2]}" = push ] && [ "$COMP_CWORD" -eq 3 ]; then
      COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = keys ] && [ "$COMP_CWORD" -eq 2 ]; then
      COMPREPLY=($(compgen -W "forward setup check status" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = keys ] && [[ "${COMP_WORDS[2]}" =~ ^(setup|check)$ ]] && [ "$COMP_CWORD" -eq 3 ]; then
      COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
    elif [ "${COMP_WORDS[1]}" = keys ] && [ "${COMP_WORDS[2]}" = forward ] && [ "$COMP_CWORD" -eq 3 ]; then
      COMPREPLY=($(compgen -W "on off" -- "$cur"))
    fi
  }
  complete -F _fleet_complete fleet
fi
