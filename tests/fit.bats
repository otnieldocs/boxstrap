#!/usr/bin/env bats
# Unit tests for the `fit` phase — the last cheap "no" before containers start.
#
# Both checks it makes fail SILENTLY in production if they are wrong, so the
# tests care as much about the false-negative direction as the false-positive
# one. A capacity check that reports "no mem_limit set" for a compose declaring
# nine of them is worse than no check at all — that exact bug shipped during
# development here, because ${v,,} is bash 4+ and macOS ships bash 3.2.

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/65-fit.sh
  source "$BOXSTRAP_ROOT/lib/65-fit.sh"
  APP="$BATS_TEST_TMPDIR/app"; mkdir -p "$APP"
  export BOXSTRAP_COMPOSE_FILES="docker-compose.yml"
  MEM="$BATS_TEST_TMPDIR/meminfo"
}

_meminfo() {  # _meminfo RAM_MB SWAP_MB
  printf 'MemTotal:       %s kB\nSwapTotal:       %s kB\n' "$(( $1 * 1024 ))" "$(( $2 * 1024 ))" > "$MEM"
  export BOXSTRAP_MEMINFO="$MEM"
}

# ── unit conversion ─────────────────────────────────────────────────────────

@test "bs__fit_mb converts g/m/k and rejects junk" {
  [ "$(bs__fit_mb 2g)"    = "2048" ]
  [ "$(bs__fit_mb 512m)"  = "512"  ]
  [ "$(bs__fit_mb 1536M)" = "1536" ]   # uppercase must work (bash 3.2 safe)
  [ "$(bs__fit_mb 2G)"    = "2048" ]
  [ "$(bs__fit_mb 1024k)" = "1"    ]
  [ -z "$(bs__fit_mb nonsense)" ]
  [ -z "$(bs__fit_mb '')" ]
}

# ── capacity ────────────────────────────────────────────────────────────────

@test "capacity: sums every mem_limit rather than stopping at the first" {
  printf 'services:\n  a:\n    mem_limit: 2g\n  b:\n    mem_limit: 512m\n  c:\n    mem_limit: 1536m\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ]
  # 2048 + 512 + 1536 = 4096 across 3 services
  [[ "$output" == *"4096MB across 3 service(s)"* ]]
}

@test "capacity: reports a comfortable fit" {
  printf 'services:\n  a:\n    mem_limit: 1g\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fits in RAM"* ]]
}

@test "capacity: warns but does NOT fail when caps exceed RAM" {
  # Overcommitting mem_limit is a legitimate, deliberate choice — contena's own
  # production declares 9344MB on a 7847MB box. Failing here would block a
  # working deploy.
  printf 'services:\n  a:\n    mem_limit: 9g\n' > "$APP/docker-compose.yml"
  _meminfo 8000 2000
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exceed RAM"* ]]
}

@test "capacity: says so when swap cannot absorb the peak either" {
  printf 'services:\n  a:\n    mem_limit: 9g\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  [[ "$output" == *"exceeds RAM + swap"* ]]
}

@test "capacity: BOXSTRAP_FIT_STRICT makes an over-commit fatal" {
  printf 'services:\n  a:\n    mem_limit: 9g\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  BOXSTRAP_FIT_STRICT=true run bs__fit_memory "$APP"
  [ "$status" -ne 0 ]
}

@test "capacity: reads \${VAR:-512m} as 512m instead of skipping it" {
  # ⚠️ The regression this guards: the old value pattern required a digit, so an
  # interpolated cap did not match and was dropped SILENTLY. On a real staging
  # box all ten overlay caps vanished and the phase reported the base file's
  # numbers while printing "Fits in RAM".
  printf 'services:\n  a:\n    mem_limit: ${A_MEM:-512m}\n  b:\n    mem_limit: ${B_MEM:-2g}\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ] && [[ "$output" == *"2560MB across 2 service(s)"* ]]
}

@test "capacity: an overlay overriding a cap is counted ONCE, at the override" {
  # `-f base -f overlay` resolves to the overlay's value; summing both
  # double-counts the base.
  printf 'services:\n  a:\n    mem_limit: 2g\n  b:\n    mem_limit: 1g\n' > "$APP/docker-compose.yml"
  printf 'services:\n  a:\n    mem_limit: 512m\n' > "$APP/overlay.yml"
  BOXSTRAP_COMPOSE_FILES="docker-compose.yml overlay.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  # a=512 (overridden, not 2048+512) + b=1024
  [ "$status" -eq 0 ] && [[ "$output" == *"1536MB across 2 service(s)"* ]]
}

@test "capacity: a service only in the overlay is added, not ignored" {
  printf 'services:\n  a:\n    mem_limit: 1g\n' > "$APP/docker-compose.yml"
  printf 'services:\n  qa:\n    mem_limit: ${QA_MEM:-2g}\n' > "$APP/overlay.yml"
  BOXSTRAP_COMPOSE_FILES="docker-compose.yml overlay.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ] && [[ "$output" == *"3072MB across 2 service(s)"* ]]
}

@test "capacity: \${VAR} with no default is REPORTED, never silently dropped" {
  printf 'services:\n  a:\n    mem_limit: 1g\n  b:\n    mem_limit: ${B_MEM}\n' > "$APP/docker-compose.yml"
  _meminfo 8000 0
  run bs__fit_memory "$APP"
  # ⚠️ Chained with && on purpose: bats 1.13 fails a test only on the LAST
  # command, so a mid-test assertion that fails is INERT. Verified with a probe.
  # Written as separate lines, this test passed against the unfixed function.
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"1024MB across 1 service(s)"* ]] \
    && [[ "$output" == *"not statically readable"* ]] \
    && [[ "$output" == *"b"* ]]
}

@test "capacity: flags a compose with no mem_limit at all" {
  printf 'services:\n  a:\n    image: redis:7-alpine\n' > "$APP/docker-compose.yml"
  run bs__fit_memory "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No mem_limit"* ]]
}

# ── required environment ────────────────────────────────────────────────────

@test "env: passes when every required var is set" {
  printf 'services:\n  a:\n    environment:\n      K: ${SECRET_KEY}\n' > "$APP/docker-compose.yml"
  printf 'SECRET_KEY=abc123\n' > "$APP/.env"
  run bs__fit_env "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"required variable(s) are set"* ]]
}

@test "env: FAILS and names the variable when one is missing" {
  printf 'services:\n  a:\n    environment:\n      K: ${SECRET_KEY}\n      J: ${OTHER}\n' > "$APP/docker-compose.yml"
  printf 'SECRET_KEY=abc123\n' > "$APP/.env"
  run bs__fit_env "$APP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OTHER"* ]]
}

@test "env: an empty assignment counts as missing, not as set" {
  printf 'services:\n  a:\n    environment:\n      K: ${SECRET_KEY}\n' > "$APP/docker-compose.yml"
  printf 'SECRET_KEY=\n' > "$APP/.env"
  run bs__fit_env "$APP"
  [ "$status" -ne 0 ]
}

@test "env: \${VAR:-default} is NOT required — the author supplied the fallback" {
  printf 'services:\n  a:\n    environment:\n      K: ${TUNABLE:-30}\n' > "$APP/docker-compose.yml"
  printf 'UNRELATED=x\n' > "$APP/.env"
  run bs__fit_env "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No required"* || "$output" == *"are set"* ]]
}

@test "env: warns on an unreplaced .env.example placeholder without failing" {
  printf 'services:\n  a:\n    environment:\n      K: ${API_KEY}\n' > "$APP/docker-compose.yml"
  printf 'API_KEY=your-api-key\n' > "$APP/.env"
  run bs__fit_env "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"placeholder"* ]]
}

@test "env: BOXSTRAP_FIT_ALLOW_EMPTY exempts a genuinely-optional var" {
  printf 'services:\n  a:\n    environment:\n      K: ${OPTIONAL_THING}\n' > "$APP/docker-compose.yml"
  printf 'UNRELATED=x\n' > "$APP/.env"
  BOXSTRAP_FIT_ALLOW_EMPTY="OPTIONAL_THING" run bs__fit_env "$APP"
  [ "$status" -eq 0 ]
}

@test "env: a missing .env is fatal when the compose requires anything" {
  printf 'services:\n  a:\n    environment:\n      K: ${SECRET_KEY}\n' > "$APP/docker-compose.yml"
  run bs__fit_env "$APP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty string"* ]]
}

@test "env: dry-run reports what it would check instead of aborting" {
  printf 'services:\n  a:\n    environment:\n      K: ${SECRET_KEY}\n' > "$APP/docker-compose.yml"
  BOXSTRAP_DRY_RUN=true run bs__fit_env "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}
