#!/usr/bin/env bash
# Interactive selection helpers — gum when present, plain-bash fallback otherwise.
# Menus are only used in interactive mode; the scriptable path uses bootstrap.sh
# --config instead.

# confirm "Question" — return 0 for yes. Non-interactive answers yes.
confirm() {
  local q="$1" a
  is_interactive || return 0
  if have gum; then gum confirm "$q"; return $?; fi
  read -r -p "$q [y/N]: " a
  [[ "$a" =~ ^[Yy] ]]
}

# menu_choose "Header" opt1 opt2 ... — echo the chosen option to stdout.
# Returns non-zero if nothing was chosen (e.g. EOF / cancel).
menu_choose() {
  local header="$1"; shift
  [[ $# -gt 0 ]] || return 1
  if have gum; then
    printf '%s\n' "$@" | gum choose --header "$header"
    return
  fi
  local opt PS3="$header (enter number): "
  select opt in "$@"; do
    if [[ -n "$opt" ]]; then printf '%s' "$opt"; return 0; fi
  done
  return 1
}
