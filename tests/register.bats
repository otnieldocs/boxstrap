#!/usr/bin/env bats
# Unit tests for the registration wizard's pure config-line assembly. The
# interactive prompts themselves aren't unit-tested (they only glue prompts to
# bs__tls_lines); this covers the part that decides what lands in the config.

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/register.sh
  source "$BOXSTRAP_ROOT/lib/register.sh"
}

@test "bs__tls_lines writes an edge-mode block" {
  run bs__tls_lines edge dash.example.com crawler-web:3000
  [ "$status" -eq 0 ]
  [[ "$output" == *"BOXSTRAP_TLS_PROVIDER=edge"* ]]
  [[ "$output" == *'BOXSTRAP_DOMAIN="dash.example.com"'* ]]
  [[ "$output" == *'BOXSTRAP_TLS_UPSTREAM="crawler-web:3000"'* ]]
  [[ "$output" == *'BOXSTRAP_HEALTH_URL="https://dash.example.com/healthz"'* ]]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "bs__tls_lines writes a caddy-mode block" {
  run bs__tls_lines caddy api.example.com api:8000
  [ "$status" -eq 0 ]
  [[ "$output" == *"BOXSTRAP_TLS_PROVIDER=caddy"* ]]
  [[ "$output" == *'BOXSTRAP_DOMAIN="api.example.com"'* ]]
}

@test "bs__tls_lines writes nothing when no domain is given" {
  run bs__tls_lines edge "" crawler-web:3000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bs__tls_lines output round-trips as sourceable config" {
  local f="$BATS_TEST_TMPDIR/tls.conf"
  bs__tls_lines edge dash.example.com crawler-web:3000 > "$f"
  # shellcheck disable=SC1090
  source "$f"
  [ "$BOXSTRAP_TLS_PROVIDER" = "edge" ]
  [ "$BOXSTRAP_DOMAIN" = "dash.example.com" ]
  [ "$BOXSTRAP_TLS_UPSTREAM" = "crawler-web:3000" ]
  [ "$BOXSTRAP_HEALTH_EXPECT" = '"status":"ok"' ]
}
