#!/usr/bin/env bash
# Service lifecycle actions. Slice A ships `deploy`; the manage menu
# (update/restart/status/logs/stop/remove) lands in Slice B.

# bs_deploy_stack NAME — load a registered stack's config and run the service
# phases (fetch code, detect stack, host-tune, pull+up, health-gate).
bs_deploy_stack() {
  local name="$1"
  reg_load "$name" || return 1
  log_step "Deploy: $name"
  bs_app_fetch
  bs_detect
  bs_kernel_tuning
  bs_app_up
  bs_verify
}
