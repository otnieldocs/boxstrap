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

# bs__tls_lines PROVIDER DOMAIN UPSTREAM — print the TLS-related stack config
# lines (nothing when DOMAIN is empty). Pure/echo-only so it is unit-testable.
# PROVIDER is 'caddy' (embedded per-app Caddy) or 'edge' (shared edge proxy).
bs__tls_lines() {
  local provider="$1" domain="$2" upstream="$3"
  [[ -n "$domain" ]] || return 0
  printf 'BOXSTRAP_TLS_PROVIDER=%s\n' "$provider"
  printf 'BOXSTRAP_DOMAIN="%s"\n' "$domain"
  printf 'BOXSTRAP_TLS_UPSTREAM="%s"\n' "$upstream"
  printf 'BOXSTRAP_HEALTH_URL="https://%s/healthz"\n' "$domain"
  printf 'BOXSTRAP_HEALTH_EXPECT=\x27"status":"ok"\x27\n'
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

  # TLS mode (only when a domain is set): 'edge' shares one box-wide Caddy across
  # stacks; 'caddy' embeds a Caddy in this app's own compose (needs :80/:443).
  local provider="caddy" up_hint="compose service:port"
  if [[ -n "$domain" ]]; then
    if confirm "Front '$name' through the shared edge proxy (many apps, one box)? No = its own Caddy on :80/:443."; then
      provider="edge"; up_hint="shared-network alias:port"
    fi
  fi
  prompt upstream "TLS upstream ($up_hint)" "api:8000"
  prompt gen      "Secrets to auto-generate (VAR:hex:N, space-sep, blank = none)" ""
  prompt prompts  "Secrets to prompt for (VAR names, space-sep, blank = none)" ""

  local -a lines=(
    "BOXSTRAP_APP_NAME=$name"
    "BOXSTRAP_APP_REPO=\"$repo\""
    "BOXSTRAP_APP_DIR=\"$dir\""
    "BOXSTRAP_COMPOSE_FILES=\"$compose\""
    "BOXSTRAP_REGISTRY_HOST=\"$registry\""
  )
  local tls_line
  while IFS= read -r tls_line; do lines+=("$tls_line"); done \
    < <(bs__tls_lines "$provider" "$domain" "$upstream")
  [[ -n "$gen" ]]     && lines+=("BOXSTRAP_SECRETS_GENERATE=\"$gen\"")
  [[ -n "$prompts" ]] && lines+=("BOXSTRAP_SECRETS_PROMPT=\"$prompts\"")

  reg_save "$name" "${lines[@]}"
  log_ok "Registered '$name' -> $(reg_path "$name")"
  [[ "$provider" == "edge" ]] && log_info \
    "Edge mode: attach $name's fronted service to the external 'boxstrap-edge' network with alias '${upstream%%:*}' (see stacks/stack.conf.example)."

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
