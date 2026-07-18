#!/usr/bin/env bats
# Unit tests for `set-domain` — the config-rewrite logic is pure (no Docker);
# the proxy reload is only exercised in --dry-run (prints).

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export BOXSTRAP_EDGE_DIR="$BATS_TEST_TMPDIR/edge"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/registry.sh
  source "$BOXSTRAP_ROOT/lib/registry.sh"
  # shellcheck source=../lib/48-edge.sh
  source "$BOXSTRAP_ROOT/lib/48-edge.sh"
  # shellcheck source=../lib/50-app-fetch.sh
  source "$BOXSTRAP_ROOT/lib/50-app-fetch.sh"
  # shellcheck source=../lib/lifecycle.sh
  source "$BOXSTRAP_ROOT/lib/lifecycle.sh"
}

@test "bs__rewrite_stack_domain rewrites the domain across every field" {
  reg_save svc 'BOXSTRAP_TLS_PROVIDER=caddy' 'BOXSTRAP_DOMAIN="old.example.com"' \
    'BOXSTRAP_HEALTH_URL="https://old.example.com/healthz"' \
    'BOXSTRAP_PROTECTED_URL="https://old.example.com/v1/x"'
  bs__rewrite_stack_domain svc old.example.com new.example.com
  reg_load svc
  [ "$BOXSTRAP_DOMAIN" = "new.example.com" ]
  [ "$BOXSTRAP_HEALTH_URL" = "https://new.example.com/healthz" ]
  [ "$BOXSTRAP_PROTECTED_URL" = "https://new.example.com/v1/x" ]
}

@test "set-domain is a no-op when the domain is unchanged" {
  reg_save svc 'BOXSTRAP_TLS_PROVIDER=edge' 'BOXSTRAP_DOMAIN="same.example.com"' \
    'BOXSTRAP_TLS_UPSTREAM="svc:3000"'
  run bs_set_domain svc same.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"already serves"* ]]
}

@test "set-domain fails on a stack that has no domain" {
  reg_save svc 'BOXSTRAP_TLS_PROVIDER=caddy' 'BOXSTRAP_APP_DIR="/opt/svc"'
  run bs_set_domain svc new.example.com
  [ "$status" -ne 0 ]
}

@test "set-domain (edge, dry-run) rewrites config, warns about DNS, and syncs the proxy" {
  reg_save svc 'BOXSTRAP_TLS_PROVIDER=edge' 'BOXSTRAP_DOMAIN="old.example.com"' \
    'BOXSTRAP_TLS_UPSTREAM="svc:3000"'
  export BOXSTRAP_DRY_RUN=true
  run bs_set_domain svc new.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"old.example.com -> new.example.com"* ]]
  [[ "$output" == *"DNS"* ]]
  [[ "$output" == *"Edge proxy synced"* ]]
}

@test "set-domain (caddy, dry-run) regenerates the app Caddyfile + reloads" {
  local appdir="$BATS_TEST_TMPDIR/app"; mkdir -p "$appdir"
  reg_save svc 'BOXSTRAP_TLS_PROVIDER=caddy' 'BOXSTRAP_DOMAIN="old.example.com"' \
    "BOXSTRAP_APP_DIR=\"$appdir\"" 'BOXSTRAP_COMPOSE_FILES="docker-compose.prod.yml"' \
    'BOXSTRAP_TLS_UPSTREAM="api:8000"'
  export BOXSTRAP_DRY_RUN=true
  run bs_set_domain svc new.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"old.example.com -> new.example.com"* ]]
  [[ "$output" == *"caddy reload"* ]]
}
