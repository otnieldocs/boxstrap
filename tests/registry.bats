#!/usr/bin/env bats
# Unit tests for the service registry (pure file logic — no OS mutation).
# Run with: bats tests/

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Redirect state into a temp dir so tests never touch /etc/boxstrap.
  export BOXSTRAP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/registry.sh
  source "$BOXSTRAP_ROOT/lib/registry.sh"
}

@test "reg_list: empty when nothing registered" {
  run reg_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reg_save then reg_list shows the service" {
  reg_save myapp 'BOXSTRAP_APP_NAME=myapp' 'BOXSTRAP_APP_DIR="/opt/myapp"'
  run reg_list
  [ "$output" = "myapp" ]
}

@test "reg_exists reflects registration" {
  ! reg_exists myapp
  reg_save myapp 'BOXSTRAP_APP_NAME=myapp'
  reg_exists myapp
}

@test "reg_load sources the config back" {
  reg_save myapp 'BOXSTRAP_APP_NAME=myapp' 'BOXSTRAP_APP_DIR="/opt/myapp"'
  reg_load myapp
  [ "$BOXSTRAP_APP_NAME" = "myapp" ]
  [ "$BOXSTRAP_APP_DIR" = "/opt/myapp" ]
}

@test "reg_save writes a 600-permission file" {
  reg_save myapp 'BOXSTRAP_APP_NAME=myapp'
  run stat -f '%Lp' "$(reg_path myapp)"   # BSD stat (macOS); Linux uses -c '%a'
  if [ "$status" -ne 0 ]; then
    run stat -c '%a' "$(reg_path myapp)"
  fi
  [ "$output" = "600" ]
}

@test "reg_remove unregisters" {
  reg_save myapp 'BOXSTRAP_APP_NAME=myapp'
  reg_exists myapp
  reg_remove myapp
  ! reg_exists myapp
}

@test "host_provisioned marker round-trips" {
  ! host_provisioned
  mark_host_provisioned test
  host_provisioned
}

@test "env_set replaces a line without touching others; handles special chars" {
  local f="$BATS_TEST_TMPDIR/env"
  printf 'A=1\nB=old\nC=3\n' > "$f"
  env_set "$f" B 'p@ss/w|rd&x'
  run grep '^B=' "$f"
  [ "$output" = "B=p@ss/w|rd&x" ]
  run grep -c '^A=1$' "$f"
  [ "$output" -eq 1 ]
  run grep -c '^C=3$' "$f"
  [ "$output" -eq 1 ]
}
