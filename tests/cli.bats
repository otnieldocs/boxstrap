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

# ── --only must work for phases that read preflight's detected facts ────────
#
# BS_VIRT is set by bs_preflight and read by bs_swap and bs_kernel_tuning.
# `--only <phase>` skips preflight, so under `set -u` both aborted with
# "BS_VIRT: unbound variable" — including `--only kernel-tuning`, which is the
# example the README gives for re-running a single phase.

@test "bs_virt_detect sets BS_VIRT when it is unset" {
  # ⚠️ `set -euo pipefail` is load-bearing. Without it an undefined function is
  # non-fatal, and bats folds stderr into $output — so "bs_virt_detect: command
  # not found" made [ -n "$output" ] true and the test passed against code that
  # did not have the function at all.
  run bash -c "
    set -euo pipefail
    source '$BOXSTRAP_ROOT/lib/util.sh'
    source '$BOXSTRAP_ROOT/lib/00-preflight.sh'
    unset BS_VIRT
    bs_virt_detect
    printf '%s' \"\$BS_VIRT\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "bs_virt_detect does not clobber an already-detected value" {
  run bash -c "
    source '$BOXSTRAP_ROOT/lib/util.sh'
    source '$BOXSTRAP_ROOT/lib/00-preflight.sh'
    BS_VIRT=kvm
    bs_virt_detect
    printf '%s' \"\$BS_VIRT\""
  [ "$output" = "kvm" ]
}

@test "bs_swap survives set -u without preflight having run" {
  run bash -c "
    set -euo pipefail
    source '$BOXSTRAP_ROOT/lib/util.sh'
    source '$BOXSTRAP_ROOT/lib/00-preflight.sh'
    source '$BOXSTRAP_ROOT/lib/20-swap.sh'
    unset BS_VIRT
    BOXSTRAP_DRY_RUN=true bs_swap >/dev/null 2>&1"
  [ "$status" -eq 0 ]
}

@test "bs_kernel_tuning survives set -u without preflight having run" {
  run bash -c "
    set -euo pipefail
    source '$BOXSTRAP_ROOT/lib/util.sh'
    source '$BOXSTRAP_ROOT/lib/00-preflight.sh'
    source '$BOXSTRAP_ROOT/lib/60-kernel-tuning.sh'
    unset BS_VIRT
    # Must be true, or the function returns before it ever reads BS_VIRT and the
    # test passes without exercising anything.
    BS_NEEDS_REDIS_TUNING=true
    BOXSTRAP_DRY_RUN=true bs_kernel_tuning >/dev/null 2>&1"
  [ "$status" -eq 0 ]
}
