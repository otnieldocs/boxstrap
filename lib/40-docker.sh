#!/usr/bin/env bash
# Phase: docker — Docker Engine + compose plugin, plus log rotation. Unbounded
# json-file logs are the most common way a self-hosted box silently fills its disk.

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
}
