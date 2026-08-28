#!/usr/bin/env bash
# boxstrap/lib/tui.sh — terminal UI primitives in pure Bash.
#
# WHY NOT JUST REQUIRE gum: boxstrap's pitch is "no daemon left behind, no
# lock-in — just readable Bash". Making a Go binary mandatory to see a usable
# menu contradicts that, and on a fresh VPS gum is never already there. So gum
# stays PREFERRED when present (lib/menu.sh checks first) and this is what
# everyone else gets — which, before this file existed, was bash `select`: a
# numbered prompt from 1983.
#
# ⚠️ EVERYTHING HERE DRAWS TO /dev/tty, NEVER STDOUT.
# These helpers are called as `choice="$(tui_choose ...)"`, so stdout is the
# return channel. A single stray `echo` of a menu frame ends up inside the
# caller's variable, and the bug looks like "the menu picked the wrong thing"
# rather than "the menu printed to the wrong stream".

# tui_supported — true only when we can actually drive a terminal.
# Guards CI, pipes, and `--non-interactive`; BOXSTRAP_NO_TUI=1 forces the plain
# path for anyone whose terminal misbehaves.
tui_supported() {
  [[ "${BOXSTRAP_NO_TUI:-0}" != "1" ]] || return 1
  is_interactive || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  return 0
}

# ── drawing ────────────────────────────────────────────────────────────────
_tui()          { printf '%b' "$*" > /dev/tty; }
_tui_hide()     { _tui '\033[?25l'; }
_tui_show()     { _tui '\033[?25h'; }
_tui_up()       { _tui "\033[${1}A"; }
_tui_clearln()  { _tui '\033[2K\r'; }

# tui_banner — the one place boxstrap says its own name.
tui_banner() {
  tui_supported || return 0
  local sub="${1:-}"
  _tui "\n${C_BLU}${C_BOLD}  ┌─ boxstrap ${C_RESET}${C_DIM}────────────────────────────────────${C_RESET}\n"
  [[ -n "$sub" ]] && _tui "${C_BLU}${C_BOLD}  │${C_RESET} ${sub}\n"
  _tui "${C_BLU}${C_BOLD}  └${C_RESET}${C_DIM}────────────────────────────────────────────${C_RESET}\n\n"
}

# tui_rule ["label"] — a section divider.
tui_rule() {
  tui_supported || return 0
  if [[ -n "${1:-}" ]]; then
    _tui "${C_DIM}── ${C_RESET}${C_BOLD}$1${C_RESET} ${C_DIM}$(printf '─%.0s' $(seq 1 30))${C_RESET}\n"
  else
    _tui "${C_DIM}$(printf '─%.0s' $(seq 1 46))${C_RESET}\n"
  fi
}

# ⚠️ Bash 3.2 (still what macOS ships) rejects a FRACTIONAL `read -t`:
#   read: 0.05: invalid timeout specification
# and the failure is not cosmetic — the escape-sequence read below aborts, so
# every arrow key is misread as a cancel and the menu becomes unusable. Ubuntu
# has bash 5, so this would only ever have broken for someone developing on a
# Mac, which is exactly the person who would have to debug it.
if [[ "${BASH_VERSINFO[0]:-3}" -ge 4 ]]; then
  _TUI_ESC_TIMEOUT=0.05      # imperceptible
else
  _TUI_ESC_TIMEOUT=1         # integer-only; bare Esc lags, `q` still quits fast
fi

# _tui_key — read one keypress, normalising escape sequences to a word:
# up down enter quit or the literal character.
_tui_key() {
  local k rest
  IFS= read -rsn1 k < /dev/tty || { printf 'quit'; return; }
  case "$k" in
    '')   printf 'enter'; return ;;
    $'\033')
      # Arrow keys arrive as ESC [ A. A BARE Esc also arrives as ESC with
      # nothing following, so the read must time out rather than block.
      IFS= read -rsn2 -t "$_TUI_ESC_TIMEOUT" rest < /dev/tty || rest=""
      case "$rest" in
        '[A') printf 'up' ;;
        '[B') printf 'down' ;;
        '')   printf 'quit' ;;
        *)    printf 'other' ;;
      esac
      return ;;
    k) printf 'up' ;;
    j) printf 'down' ;;
    q) printf 'quit' ;;
    *) printf '%s' "$k" ;;
  esac
}

# tui_choose "Header" opt1 opt2 ... — arrow-key picker.
# Echoes the chosen option to STDOUT; returns 1 if cancelled.
tui_choose() {
  local header="$1"; shift
  [[ $# -gt 0 ]] || return 1
  local -a opts=("$@")
  local n=${#opts[@]} cur=0 i key

  # ⚠️ Echo goes off BEFORE the first character is drawn, not after. Anything
  # printed first is a window in which an early keypress echoes raw — and an
  # impatient user pressing down-arrow while the menu is still painting is the
  # normal case, not an edge case.
  #
  # Echo must also stay off for the WHOLE menu, not just during each read.
  # `read -s` only suppresses echo while it is blocking; between the redraw and
  # the next read there is a window in which a keypress is echoed raw — you see
  # ^[[B smeared across the menu. Holding echo off for the duration closes it.
  local _stty_saved=""
  _stty_saved="$(stty -g < /dev/tty 2>/dev/null || true)"
  [[ -n "$_stty_saved" ]] && stty -echo < /dev/tty 2>/dev/null || true

  _tui "${C_BOLD}${header}${C_RESET}\n"
  _tui "${C_DIM}  ↑/↓ or j/k to move · enter to select · q to cancel${C_RESET}\n"
  _tui_hide

  # Restore the terminal on ANY exit, Ctrl-C included. An invisible cursor and a
  # no-echo shell is a genuinely hostile thing to leave someone in — they cannot
  # even see what they type to fix it.
  _tui_restore() {
    _tui_show
    [[ -n "$_stty_saved" ]] && stty "$_stty_saved" < /dev/tty 2>/dev/null || true
  }
  trap '_tui_restore; trap - INT; return 1' INT

  while true; do
    for i in $(seq 0 $(( n - 1 ))); do
      if [[ "$i" -eq "$cur" ]]; then
        _tui "${C_GRN}${C_BOLD}  ❯ ${opts[$i]}${C_RESET}\033[K\n"
      else
        _tui "    ${C_DIM}${opts[$i]}${C_RESET}\033[K\n"
      fi
    done

    key="$(_tui_key)"
    case "$key" in
      up)    cur=$(( (cur - 1 + n) % n )) ;;
      down)  cur=$(( (cur + 1) % n )) ;;
      enter) break ;;
      quit)  _tui_restore; trap - INT; _tui '\n'; return 1 ;;
      [1-9]) # direct pick by number, for anyone who prefers typing
             if [[ "$key" -le "$n" ]]; then cur=$(( key - 1 )); break; fi ;;
    esac
    _tui_up "$n"
  done

  _tui_restore; trap - INT
  # Collapse the menu to a single line recording what was chosen, so a long
  # session does not leave screens of dead menus behind.
  _tui_up "$n"
  for i in $(seq 1 "$n"); do _tui_clearln; _tui '\033[1B'; done
  _tui_up "$n"
  _tui "${C_GRN}  ❯${C_RESET} ${opts[$cur]}\033[K\n"

  printf '%s' "${opts[$cur]}"
}

# tui_confirm "Question" [default-yes] — y/n with a highlighted default.
tui_confirm() {
  local q="$1" defyes="${2:-false}" key hint
  if [[ "$defyes" == "true" ]]; then hint="${C_GRN}Y${C_RESET}/n"; else hint="y/${C_GRN}N${C_RESET}"; fi
  _tui "${C_BOLD}${q}${C_RESET} [${hint}] "
  key="$(_tui_key)"
  case "$key" in
    y|Y)   _tui "${C_GRN}yes${C_RESET}\n"; return 0 ;;
    n|N)   _tui "${C_YEL}no${C_RESET}\n";  return 1 ;;
    enter) if [[ "$defyes" == "true" ]]; then _tui "${C_GRN}yes${C_RESET}\n"; return 0
           else _tui "${C_YEL}no${C_RESET}\n"; return 1; fi ;;
    *)     _tui "${C_YEL}no${C_RESET}\n"; return 1 ;;
  esac
}
