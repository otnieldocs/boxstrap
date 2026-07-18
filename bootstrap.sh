#!/usr/bin/env bash
# boxstrap — provision + harden a fresh Ubuntu VPS and deploy a docker-compose app.
#
# Usage:
#   sudo ./bootstrap.sh --config stacks/contena-crawler.conf [--dry-run]
#                       [--non-interactive] [--only PHASE]
#
# boxstrap automates a repeatable, idempotent bring-up: OS hardening, Docker,
# stack-aware host tuning, and a registry-pull deploy — stopping at a health gate.
# App wiring / canary / cutover stay deliberately manual.
set -euo pipefail

BOXSTRAP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export BOXSTRAP_ROOT

# shellcheck source=lib/util.sh
source "$BOXSTRAP_ROOT/lib/util.sh"

CONFIG=""
ONLY=""
export BOXSTRAP_DRY_RUN=false
export BOXSTRAP_NONINTERACTIVE=false

usage() {
  cat <<'EOF'
boxstrap — harden a fresh Ubuntu VPS and deploy a docker-compose app.

Usage:
  sudo ./bootstrap.sh --config <file> [options]

Options:
  --config FILE        Stack config to load (see stacks/*.conf). Required.
  --dry-run            Print every action without changing the system.
  --non-interactive    Never prompt; use config values / env only.
  --only PHASE         Run a single phase. One of:
                       preflight system swap hardening docker
                       app-fetch detect kernel-tuning app-up edge verify
  -h, --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)          CONFIG="${2:-}"; shift 2 ;;
    --dry-run)         BOXSTRAP_DRY_RUN=true; shift ;;
    --non-interactive) BOXSTRAP_NONINTERACTIVE=true; shift ;;
    --only)            ONLY="${2:-}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage; die "unknown argument: $1" ;;
  esac
done

[[ -n "$CONFIG" ]] || { usage; die "--config is required"; }
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"

# Load every phase library (util.sh is already sourced above). Files define
# functions only, so source order is irrelevant.
for _f in "$BOXSTRAP_ROOT"/lib/[0-9]*.sh; do
  # shellcheck disable=SC1090
  source "$_f"
done
unset _f

# Ordered pipeline: display-name -> function.
PHASES=(
  "preflight:bs_preflight"
  "system:bs_system"
  "swap:bs_swap"
  "hardening:bs_hardening"
  "docker:bs_docker"
  "app-fetch:bs_app_fetch"
  "detect:bs_detect"
  "kernel-tuning:bs_kernel_tuning"
  "app-up:bs_app_up"
  "edge:bs_edge_phase"
  "verify:bs_verify"
)

main() {
  require_root
  local tag=""
  [[ "$BOXSTRAP_DRY_RUN" == "true" ]] && tag=" (dry-run)"
  log_step "boxstrap$tag — stack: ${BOXSTRAP_APP_NAME:-unknown}"

  local entry name fn ran=false
  for entry in "${PHASES[@]}"; do
    name="${entry%%:*}"; fn="${entry##*:}"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
    ran=true
    log_step "Phase: $name"
    "$fn"
  done

  [[ "$ran" == "true" ]] || die "unknown --only phase: $ONLY"
  log_ok "boxstrap finished."
}

main "$@"
