#!/usr/bin/env bats
# Unit tests for the lifecycle helpers that don't require Docker. The actual
# compose actions are exercised with `--dry-run` (they only print).

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/registry.sh
  source "$BOXSTRAP_ROOT/lib/registry.sh"
  # shellcheck source=../lib/lifecycle.sh
  source "$BOXSTRAP_ROOT/lib/lifecycle.sh"
}

@test "_svc_prep builds compose -f args from the config" {
  local appdir="$BATS_TEST_TMPDIR/app"; mkdir -p "$appdir"
  reg_save svc "BOXSTRAP_APP_DIR=\"$appdir\"" 'BOXSTRAP_COMPOSE_FILES="a.yml b.yml"'
  _svc_prep svc
  [ "${BS_COMPOSE_ARGS[*]}" = "-f a.yml -f b.yml" ]
}

@test "_svc_prep fails when the app dir is missing" {
  reg_save svc 'BOXSTRAP_APP_DIR="/nope/does/not/exist"' 'BOXSTRAP_COMPOSE_FILES="x.yml"'
  run _svc_prep svc
  [ "$status" -ne 0 ]
}

@test "update in dry-run prints pull + up without executing" {
  local appdir="$BATS_TEST_TMPDIR/app"; mkdir -p "$appdir"
  reg_save svc "BOXSTRAP_APP_DIR=\"$appdir\"" 'BOXSTRAP_COMPOSE_FILES="docker-compose.prod.yml"'
  export BOXSTRAP_DRY_RUN=true
  run bs_svc_update svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker compose -f docker-compose.prod.yml pull"* ]]
  [[ "$output" == *"docker compose -f docker-compose.prod.yml up -d"* ]]
}

@test "update --refresh ABORTS when git pull fails (no stale deploy)" {
  local appdir="$BATS_TEST_TMPDIR/app"; mkdir -p "$appdir"
  # A git repo with no upstream -> `git pull --ff-only` fails.
  ( cd "$appdir" && git init -q && git config user.email t@t.co \
      && git config user.name t && git commit -q --allow-empty -m init )
  reg_save svc "BOXSTRAP_APP_DIR=\"$appdir\"" 'BOXSTRAP_COMPOSE_FILES="dc.yml"' \
    'BOXSTRAP_TLS_PROVIDER=caddy' 'BOXSTRAP_DOMAIN="x.example.com"'
  export BS_REFRESH=true
  run bs_svc_update svc
  # Non-zero exit + explicit reason, and it never reached the image pull/up.
  [ "$status" -ne 0 ]
  [[ "$output" == *"git pull failed"* ]]
  [[ "$output" == *"stale manifests"* ]]
}

@test "restart in dry-run prints restart" {
  local appdir="$BATS_TEST_TMPDIR/app"; mkdir -p "$appdir"
  reg_save svc "BOXSTRAP_APP_DIR=\"$appdir\"" 'BOXSTRAP_COMPOSE_FILES="docker-compose.prod.yml"'
  export BOXSTRAP_DRY_RUN=true
  run bs_svc_restart svc
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker compose -f docker-compose.prod.yml restart"* ]]
}
