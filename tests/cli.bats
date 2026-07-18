#!/usr/bin/env bats
# Caddyfile generation + CLI install launcher (pure/dry-run — no OS mutation).

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_DRY_RUN=false
  # shellcheck source=../lib/util.sh
  source "$BOXSTRAP_ROOT/lib/util.sh"
  # shellcheck source=../lib/50-app-fetch.sh
  source "$BOXSTRAP_ROOT/lib/50-app-fetch.sh"
  # shellcheck source=../lib/install.sh
  source "$BOXSTRAP_ROOT/lib/install.sh"
}

@test "bs_write_caddyfile writes reverse_proxy config from stack settings" {
  export BOXSTRAP_TLS_PROVIDER=caddy BOXSTRAP_DOMAIN=app.example.com BOXSTRAP_TLS_UPSTREAM=api:8000
  local dir="$BATS_TEST_TMPDIR/app"
  mkdir -p "$dir"
  bs_write_caddyfile "$dir"
  grep -q "^app.example.com {" "$dir/Caddyfile"
  grep -q "reverse_proxy api:8000" "$dir/Caddyfile"
}

@test "bs_write_caddyfile is a no-op without a domain" {
  export BOXSTRAP_TLS_PROVIDER=caddy BOXSTRAP_DOMAIN=""
  local dir="$BATS_TEST_TMPDIR/app2"
  mkdir -p "$dir"
  bs_write_caddyfile "$dir"
  [ ! -f "$dir/Caddyfile" ]
}

@test "bs_write_caddyfile honors a custom upstream" {
  export BOXSTRAP_TLS_PROVIDER=caddy BOXSTRAP_DOMAIN=x.example.com BOXSTRAP_TLS_UPSTREAM=web:3000
  local dir="$BATS_TEST_TMPDIR/app3"
  mkdir -p "$dir"
  bs_write_caddyfile "$dir"
  grep -q "reverse_proxy web:3000" "$dir/Caddyfile"
}

@test "bs_install_cli (dry-run) reports the launcher target and real path" {
  export BOXSTRAP_DRY_RUN=true
  BOXSTRAP_ROOT="/opt/boxstrap"
  run bs_install_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/local/bin/boxstrap"* ]]
  [[ "$output" == *"/opt/boxstrap/boxstrap"* ]]
}
