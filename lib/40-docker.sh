#!/usr/bin/env bash
# Phase: docker — Docker Engine + compose plugin, log rotation, and a scheduled
# prune. Unbounded json-file logs and orphaned image layers are the two most
# common ways a self-hosted box silently fills its disk. A box that also runs CI
# fills it fastest: every pipeline leaves build cache and superseded image layers
# behind, and nothing reclaims them on its own.

# bs__prune_service_unit — print the oneshot unit that reclaims Docker garbage.
# Pure/echo-only so it is unit-testable (mirrors bs__tls_lines in register.sh).
bs__prune_service_unit() {
  cat <<'UNIT'
[Unit]
Description=Reclaim unused Docker images, containers, networks and build cache
Documentation=https://docs.docker.com/reference/cli/docker/system/prune/

[Service]
Type=oneshot
# NOTE the two deliberate omissions, both of which destroy data if added:
#   --volumes  would delete named volumes. A volume is "unused" while its stack
#              is down for a redeploy, so this would eventually eat a database.
#   until=...  is what keeps this safe next to a CI runner. Anything younger than
#              7 days is untouched, so an image pulled for a job that has not
#              started yet can never be removed out from under it.
ExecStart=/usr/bin/docker system prune -af --filter until=168h
UNIT
}

# bs__prune_timer_unit — print the timer that drives the prune. Pure/echo-only.
bs__prune_timer_unit() {
  cat <<'UNIT'
[Unit]
Description=Daily Docker prune

[Timer]
OnCalendar=daily
# A box that was off at 03:00 still prunes on the next boot rather than waiting
# a full day — the disk does not care why the run was missed.
Persistent=true
# Stagger, so several boxes sharing a registry do not all re-pull at once.
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
}

bs_docker() {
  local user="${BOXSTRAP_DEPLOY_USER:-deploy}"

  if have docker; then
    log_ok "Docker already installed ($(docker --version 2>/dev/null || echo present))"
  else
    log_info "Installing Docker Engine via the official convenience script"
    bs_run_sh "curl -fsSL https://get.docker.com | sh"
  fi
  bs_run usermod -aG docker "$user"

  # Log rotation. Respect a pre-existing daemon.json that a human tuned.
  local daemon=/etc/docker/daemon.json
  if [[ -f "$daemon" ]] && ! grep -q '"max-size"' "$daemon" 2>/dev/null; then
    log_warn "$daemon exists without log rotation — leaving it untouched. Add log-opts max-size/max-file manually."
  else
    write_file "$daemon" '{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
'
    bs_run systemctl restart docker 2>/dev/null || true
    log_ok "Docker log rotation set (10m x 3)"
  fi
  bs_run systemctl enable docker 2>/dev/null || true

  # Scheduled prune. write_file is idempotent, so re-running the phase is a no-op
  # unless the unit content actually changed.
  write_file /etc/systemd/system/docker-prune.service "$(bs__prune_service_unit)"
  write_file /etc/systemd/system/docker-prune.timer "$(bs__prune_timer_unit)"
  bs_run systemctl daemon-reload 2>/dev/null || true
  bs_run systemctl enable --now docker-prune.timer 2>/dev/null || true
  log_ok "Docker prune scheduled (daily, keeps anything younger than 7d, never volumes)"
}
