#!/usr/bin/env bash
# Phase: system — base packages, time sync, timezone. Clock skew silently breaks
# TLS handshakes, JWT validation, and cron, so chrony is not optional.

bs_system() {
  export DEBIAN_FRONTEND=noninteractive
  log_info "Updating apt and installing base packages"
  bs_run apt-get update -y
  bs_run apt-get upgrade -y
  bs_run apt-get install -y ca-certificates curl gnupg lsb-release chrony

  # chrony's unit is 'chrony' on Ubuntu; fall back to 'chronyd' elsewhere.
  bs_run systemctl enable --now chrony 2>/dev/null \
    || bs_run systemctl enable --now chronyd 2>/dev/null \
    || log_warn "could not enable chrony — verify time sync manually"

  local tz="${BOXSTRAP_TIMEZONE:-UTC}"
  bs_run timedatectl set-timezone "$tz"
  log_ok "Base packages installed; timezone=$tz; time sync active"
}
