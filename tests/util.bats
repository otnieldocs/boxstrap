#!/usr/bin/env bats
# Unit tests for the pure helpers in lib/util.sh. These avoid any OS mutation —
# the system-changing phases are exercised with `bootstrap.sh --dry-run` instead.
#
# Run with: bats tests/

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
}

@test "have: true for a real command, false for a fake one" {
  run have bash
  [ "$status" -eq 0 ]
  run have definitely-not-a-real-command-xyz
  [ "$status" -ne 0 ]
}

@test "bs_run: dry-run prints the command and does not execute it" {
  export BOXSTRAP_DRY_RUN=true
  local marker="$BATS_TEST_TMPDIR/should-not-exist"
  run bs_run touch "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -e "$marker" ]
}

@test "bs_run: real mode executes the command" {
  export BOXSTRAP_DRY_RUN=false
  local marker="$BATS_TEST_TMPDIR/created"
  run bs_run touch "$marker"
  [ "$status" -eq 0 ]
  [ -e "$marker" ]
}

@test "append_once: adds a line once, not twice" {
  export BOXSTRAP_DRY_RUN=false
  local f="$BATS_TEST_TMPDIR/f"
  : > "$f"
  append_once "$f" "hello world"
  append_once "$f" "hello world"
  run grep -c "hello world" "$f"
  [ "$output" -eq 1 ]
}

@test "write_file: writes content and is idempotent" {
  export BOXSTRAP_DRY_RUN=false
  local f="$BATS_TEST_TMPDIR/w"
  write_file "$f" $'line1\nline2\n'
  [ "$(cat "$f")" = $'line1\nline2' ]
  # second identical write leaves it unchanged
  write_file "$f" $'line1\nline2\n'
  [ "$(cat "$f")" = $'line1\nline2' ]
}

@test "prompt: non-interactive uses the default" {
  export BOXSTRAP_NONINTERACTIVE=true
  local out=""
  prompt out "irrelevant question" "the-default"
  [ "$out" = "the-default" ]
}
