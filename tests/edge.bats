#!/usr/bin/env bats
# Unit tests for the shared edge proxy — the pure file logic (aggregate Caddyfile
# + compose generation). Docker actions are only exercised in --dry-run (print).

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
}

edge_stack() { # NAME DOMAIN UPSTREAM
  reg_save "$1" 'BOXSTRAP_TLS_PROVIDER=edge' \
    "BOXSTRAP_DOMAIN=\"$2\"" "BOXSTRAP_TLS_UPSTREAM=\"$3\""
}

@test "aggregate Caddyfile has only the header when no edge stacks exist" {
  bs_write_edge_caddyfile
  local f="$BOXSTRAP_EDGE_DIR/Caddyfile"
  [ -f "$f" ]
  grep -q 'GENERATED aggregate' "$f"
  run grep -c 'reverse_proxy' "$f"
  [ "$output" -eq 0 ]
}

@test "aggregate contains a site block per edge stack, with its upstream" {
  edge_stack dash dashboard.contena.app crawler-web:3000
  edge_stack api  crawler.contena.app  crawler-api:8000
  bs_write_edge_caddyfile
  local f="$BOXSTRAP_EDGE_DIR/Caddyfile"
  grep -q 'dashboard.contena.app {' "$f"
  grep -q 'reverse_proxy crawler-web:3000' "$f"
  grep -q 'crawler.contena.app {' "$f"
  grep -q 'reverse_proxy crawler-api:8000' "$f"
}

@test "caddy-mode (embedded) stacks are NOT added to the shared proxy" {
  edge_stack dash dashboard.contena.app crawler-web:3000
  reg_save legacy 'BOXSTRAP_TLS_PROVIDER=caddy' \
    'BOXSTRAP_DOMAIN="legacy.contena.app"' 'BOXSTRAP_TLS_UPSTREAM="api:8000"'
  bs_write_edge_caddyfile
  local f="$BOXSTRAP_EDGE_DIR/Caddyfile"
  grep -q 'dashboard.contena.app' "$f"
  ! grep -q 'legacy.contena.app' "$f"
}

@test "an edge stack missing domain/upstream is skipped, not emitted broken" {
  reg_save broken 'BOXSTRAP_TLS_PROVIDER=edge' 'BOXSTRAP_DOMAIN="broken.example.com"'
  bs_write_edge_caddyfile
  local f="$BOXSTRAP_EDGE_DIR/Caddyfile"
  ! grep -q 'broken.example.com' "$f"
  run grep -c 'reverse_proxy' "$f"
  [ "$output" -eq 0 ]
}

@test "removing a stack drops its site on the next render" {
  edge_stack dash dashboard.contena.app crawler-web:3000
  edge_stack api  crawler.contena.app  crawler-api:8000
  bs_write_edge_caddyfile
  reg_remove api
  bs_write_edge_caddyfile
  local f="$BOXSTRAP_EDGE_DIR/Caddyfile"
  grep -q 'dashboard.contena.app' "$f"
  ! grep -q 'crawler.contena.app' "$f"
}

@test "reading edge stacks does not clobber the caller's environment" {
  edge_stack dash dashboard.contena.app crawler-web:3000
  BOXSTRAP_DOMAIN="caller-value"
  BOXSTRAP_TLS_UPSTREAM="caller-upstream"
  bs_write_edge_caddyfile
  # The subshell-per-stack read must not leak the last stack's values out.
  [ "$BOXSTRAP_DOMAIN" = "caller-value" ]
  [ "$BOXSTRAP_TLS_UPSTREAM" = "caller-upstream" ]
}

@test "generated edge compose references the shared external network" {
  bs_write_edge_compose
  local f="$BOXSTRAP_EDGE_DIR/docker-compose.yml"
  grep -q 'image: caddy:2' "$f"
  grep -q '"80:80"' "$f"
  grep -q '"443:443"' "$f"
  grep -q 'boxstrap-edge:' "$f"
  grep -q 'external: true' "$f"
}

@test "bs_edge_ensure in dry-run prints network + compose actions, runs nothing" {
  export BOXSTRAP_DRY_RUN=true
  run bs_edge_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker network"*"boxstrap-edge"* ]]
  [[ "$output" == *"docker compose up -d"* ]]
}

@test "bs_edge_phase is a no-op unless the loaded stack is edge-mode" {
  export BOXSTRAP_DRY_RUN=true
  BOXSTRAP_TLS_PROVIDER=caddy
  run bs_edge_phase
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
