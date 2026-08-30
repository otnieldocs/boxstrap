#!/usr/bin/env bats
# Docker phase: the prune units (pure/echo-only — no OS mutation).

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/40-docker.sh
  source "$BOXSTRAP_ROOT/lib/40-docker.sh"
}

@test "prune service NEVER passes --volumes" {
  # The whole point of the guard: --volumes deletes named volumes, and a volume
  # is 'unused' while its stack is down for a redeploy. That is a lost database.
  # Assert on the ExecStart LINE, not the whole unit — the unit's comments name
  # the flag on purpose to explain why it is absent, and matching those would
  # make this test pass or fail on prose rather than on the command that runs.
  run bs__prune_service_unit
  [ "$status" -eq 0 ]
  local exec_line
  exec_line="$(grep "^ExecStart=" <<<"$output")"
  [ -n "$exec_line" ]
  ! grep -q -- "--volumes" <<<"$exec_line"
}

@test "prune service keeps anything younger than 7 days" {
  # Without the age filter, a prune racing a CI job can remove an image that the
  # job has pulled but not yet started a container from.
  run bs__prune_service_unit
  grep -q -- "--filter until=168h" <<<"$output"
}

@test "prune service reclaims images AND build cache" {
  run bs__prune_service_unit
  grep -qE "^ExecStart=/usr/bin/docker system prune -af " <<<"$output"
}

@test "prune service is a oneshot" {
  run bs__prune_service_unit
  grep -q "^Type=oneshot" <<<"$output"
}

@test "prune timer runs daily and catches up after downtime" {
  run bs__prune_timer_unit
  [ "$status" -eq 0 ]
  grep -q "^OnCalendar=daily" <<<"$output"
  grep -q "^Persistent=true" <<<"$output"
}

@test "prune timer installs into timers.target" {
  run bs__prune_timer_unit
  grep -q "^WantedBy=timers.target" <<<"$output"
}

@test "bs_docker installs the prune timer" {
  # Guards the wiring, not just the content: a pure function nothing calls is dead code.
  grep -q "docker-prune.timer" "$BOXSTRAP_ROOT/lib/40-docker.sh"
  grep -q "systemctl enable --now docker-prune.timer" "$BOXSTRAP_ROOT/lib/40-docker.sh"
}
