#!/usr/bin/env bats
# Unit tests for lib/tui.sh.
#
# bats runs without a controlling terminal, so tui_choose itself cannot be
# exercised here — it is verified interactively under a pty. What IS tested is
# everything that decides WHETHER it engages, because that is where a TUI does
# real damage: engaging in CI, in a pipe, or under --non-interactive would hang
# a deploy waiting for a keypress nobody is there to press.

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_DRY_RUN=false
  export BOXSTRAP_NONINTERACTIVE=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/tui.sh
  source "$BOXSTRAP_ROOT/lib/tui.sh"
  # shellcheck source=../lib/menu.sh
  source "$BOXSTRAP_ROOT/lib/menu.sh"
}

@test "tui_supported is false without a terminal (bats, CI, pipes)" {
  run tui_supported
  [ "$status" -ne 0 ]
}

@test "tui_supported is false under --non-interactive" {
  BOXSTRAP_NONINTERACTIVE=true run tui_supported
  [ "$status" -ne 0 ]
}

@test "BOXSTRAP_NO_TUI=1 is an unconditional opt-out" {
  BOXSTRAP_NO_TUI=1 run tui_supported
  [ "$status" -ne 0 ]
}

@test "the escape timeout is an INTEGER on bash 3.x" {
  # Fractional read -t is bash 4+. On 3.2 it does not degrade, it errors:
  # "invalid timeout specification" — which aborts the escape read and turns
  # every arrow key into a cancel.
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    [ "$_TUI_ESC_TIMEOUT" = "0.05" ]
  else
    [ "$_TUI_ESC_TIMEOUT" = "1" ]
    # and it must be accepted by this bash
    run bash -c "read -rsn1 -t $_TUI_ESC_TIMEOUT x < /dev/null; true"
    [ "$status" -eq 0 ]
  fi
}

@test "drawing helpers write to the tty, never to stdout" {
  # The contract the whole file depends on: tui_choose's return value travels on
  # stdout, so any frame leaking there lands inside the caller's variable.
  run tui_banner "some subtitle"
  [ -z "$output" ]
  run tui_rule "Section"
  [ -z "$output" ]
}

@test "menu_choose falls back to select when no TUI and no gum" {
  # Feeding '1' to bash's select must still pick the first option.
  run bash -c "
    source '$BOXSTRAP_ROOT/lib/util.sh'
    source '$BOXSTRAP_ROOT/lib/tui.sh'
    source '$BOXSTRAP_ROOT/lib/menu.sh'
    have() { return 1; }          # pretend gum is absent
    echo 1 | menu_choose 'Pick' alpha beta"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
}

@test "confirm is non-blocking and yes under --non-interactive" {
  BOXSTRAP_NONINTERACTIVE=true run confirm "Proceed?"
  [ "$status" -eq 0 ]
}

@test "a menu label keeps name and state separable even at 24+ chars" {
  # The main menu renders "name<pad>state" and recovers the name with %% *.
  run bash -c 'printf -v p "%-24s " "a-very-long-service-name-here"; c="${p}3/3 up"; printf "%s" "${c%% *}"'
  [ "$output" = "a-very-long-service-name-here" ]
}
