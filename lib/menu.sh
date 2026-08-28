#!/usr/bin/env bash
# Interactive selection helpers — gum when present, plain-bash fallback otherwise.
# Menus are only used in interactive mode; the scriptable path uses bootstrap.sh
# --config instead.

# Three tiers, in order: gum if the operator installed it (best tested, and not
# changing behaviour for anyone who already has it), then boxstrap's own pure-Bash
# TUI (lib/tui.sh), then plain read/select for pipes, CI and dumb terminals.
#
# The third tier is the one that used to be the ONLY fallback, and on a fresh VPS
# — where gum is never already installed — it was what everybody actually saw.

# confirm "Question" — return 0 for yes. Non-interactive answers yes.
confirm() {
  local q="$1" a
  is_interactive || return 0
  if have gum; then gum confirm "$q"; return $?; fi
  if tui_supported; then tui_confirm "$q"; return $?; fi
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
  if tui_supported; then
    tui_choose "$header" "$@"
    return
  fi
  local opt PS3="$header (enter number): "
  select opt in "$@"; do
    if [[ -n "$opt" ]]; then printf '%s' "$opt"; return 0; fi
  done
  return 1
}
