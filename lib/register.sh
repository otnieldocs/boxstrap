#!/usr/bin/env bash
# Host provisioning (run once) + the interactive service-registration wizard.

# ensure_host_provisioned — run host setup a single time. Skips if the marker
# exists, or if the box already looks hardened (so an existing server can be
# adopted without re-running hardening).
ensure_host_provisioned() {
  if host_provisioned; then
    log_ok "Host already provisioned — skipping host setup."
    return 0
  fi
  local user="${BOXSTRAP_DEPLOY_USER:-deploy}"
  if have docker && id "$user" >/dev/null 2>&1 \
     && [[ -f /etc/ssh/sshd_config.d/99-boxstrap.conf ]]; then
    log_ok "Host already looks provisioned (docker + '$user' + sshd drop-in) — adopting."
    mark_host_provisioned "adopted"
    return 0
  fi
  log_step "Provisioning host (one-time: base packages, swap, hardening, docker)"
  bs_system
  bs_swap
  bs_hardening
  bs_docker
  mark_host_provisioned "boxstrap"
  log_ok "Host provisioned."
}

# bs_register_flow — interactive wizard: collect a service's details, write its
# stack config, then optionally deploy it. Detects an existing checkout and
# offers to adopt it (register without re-cloning/redeploying).
bs_register_flow() {
  local name repo dir compose registry domain upstream gen prompts adopt=false

  prompt name "Service name (e.g. contena-crawler)" ""
  [[ -n "$name" ]] || { log_warn "a name is required"; return 1; }
  if reg_exists "$name"; then log_warn "'$name' is already registered."; return 1; fi

  prompt repo "Git repo URL (the repo holding the compose file)" ""
  prompt dir  "App directory on this host" "/opt/$name"

  if [[ -d "$dir/.git" ]]; then
    if confirm "$dir already exists — adopt it (register without re-cloning or redeploying)?"; then
      adopt=true
    fi
  fi

  prompt compose  "Compose file(s), space-separated" "docker-compose.prod.yml"
  prompt registry "Container registry host" "registry.gitlab.com"
  prompt domain   "Public domain for TLS (blank = no TLS front)" ""
  prompt upstream "TLS upstream (compose service:port)" "api:8000"
  prompt gen      "Secrets to auto-generate (VAR:hex:N, space-sep, blank = none)" ""
  prompt prompts  "Secrets to prompt for (VAR names, space-sep, blank = none)" ""

  local -a lines=(
    "BOXSTRAP_APP_NAME=$name"
    "BOXSTRAP_APP_REPO=\"$repo\""
    "BOXSTRAP_APP_DIR=\"$dir\""
    "BOXSTRAP_COMPOSE_FILES=\"$compose\""
    "BOXSTRAP_REGISTRY_HOST=\"$registry\""
  )
  if [[ -n "$domain" ]]; then
    lines+=(
      "BOXSTRAP_TLS_PROVIDER=caddy"
      "BOXSTRAP_DOMAIN=\"$domain\""
      "BOXSTRAP_TLS_UPSTREAM=\"$upstream\""
      "BOXSTRAP_HEALTH_URL=\"https://$domain/healthz\""
      "BOXSTRAP_HEALTH_EXPECT='\"status\":\"ok\"'"
    )
  fi
  [[ -n "$gen" ]]     && lines+=("BOXSTRAP_SECRETS_GENERATE=\"$gen\"")
  [[ -n "$prompts" ]] && lines+=("BOXSTRAP_SECRETS_PROMPT=\"$prompts\"")

  reg_save "$name" "${lines[@]}"
  log_ok "Registered '$name' -> $(reg_path "$name")"

  if [[ "$adopt" == "true" ]]; then
    log_info "Adopted the existing deployment — not redeploying. Manage it from the menu (Slice B)."
    return 0
  fi
  if confirm "Deploy '$name' now?"; then
    bs_deploy_stack "$name"
  else
    log_info "Registered but not deployed. Run boxstrap again to deploy it."
  fi
}
