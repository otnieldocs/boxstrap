#!/usr/bin/env bash
# Service lifecycle actions. Each loads the registered stack's config, then runs
# docker compose in its app dir (as root — the same context as the registry
# login), so a registered service can be updated/restarted/inspected by name.

BS_COMPOSE_ARGS=()

# _svc_prep NAME — load the stack config, validate it, build the compose -f args
# into BS_COMPOSE_ARGS.
_svc_prep() {
  reg_load "$1" || return 1
  [[ -n "${BOXSTRAP_APP_DIR:-}" ]] || { log_err "$1: BOXSTRAP_APP_DIR not set in its config"; return 1; }
  [[ -d "$BOXSTRAP_APP_DIR" ]] || { log_err "$1: app dir '$BOXSTRAP_APP_DIR' does not exist"; return 1; }
  local files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}" f
  BS_COMPOSE_ARGS=()
  for f in $files; do BS_COMPOSE_ARGS+=(-f "$f"); done
  return 0
}

# _compose ARGS... — run docker compose in the loaded app dir.
_compose() {
  if is_dry; then
    log "[dry-run] (cd ${BOXSTRAP_APP_DIR} && docker compose ${BS_COMPOSE_ARGS[*]} $*)"
    return 0
  fi
  ( cd "$BOXSTRAP_APP_DIR" && docker compose "${BS_COMPOSE_ARGS[@]}" "$@" )
}

# _svc_health — curl the stack's health URL if one is configured.
_svc_health() {
  local url="${BOXSTRAP_HEALTH_URL:-}"
  [[ -n "$url" ]] || return 0
  if is_dry; then log "[dry-run] curl $url"; return 0; fi
  local body
  body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
  if [[ -n "$body" ]]; then
    log_ok "Health: $body"
  else
    log_warn "Health check ($url) did not respond yet — give it a moment after a restart."
  fi
}

# bs_deploy_stack NAME — full (re)deploy: fetch code, detect, host-tune, pull+up, verify.
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

# bs_svc_update NAME — pull the newest image and recreate. This is the
# "rebuild when a new image is published" action. Relies on the registry login
# established at deploy time (persisted in root's docker config).
bs_svc_update() {
  _svc_prep "$1" || return 1
  log_step "Update: $1 (pull new image + recreate)"
  _compose pull || { log_err "pull failed — the registry login may have expired; re-deploy to re-authenticate."; return 1; }
  _compose up -d
  _svc_health "$1"
  log_ok "$1 updated."
}

bs_svc_restart() {
  _svc_prep "$1" || return 1
  log_step "Restart: $1"
  _compose restart
  _svc_health "$1"
  log_ok "$1 restarted."
}

bs_svc_status() {
  _svc_prep "$1" || return 1
  log_step "Status: $1"
  _compose ps
  _svc_health "$1"
}

bs_svc_logs() {
  _svc_prep "$1" || return 1
  log_info "Tailing logs for $1 — press Ctrl-C to stop."
  _compose logs -f --tail=100 || true
}

bs_svc_stop() {
  _svc_prep "$1" || return 1
  confirm "Stop '$1'? It goes offline until restarted." || { log_info "Cancelled."; return 0; }
  _compose stop
  log_ok "$1 stopped — restart it from the menu to bring it back."
}

# bs_svc_remove NAME — unregister a service; optionally stop+remove its
# containers (named data volumes are preserved).
bs_svc_remove() {
  local name="$1"
  if reg_load "$name" 2>/dev/null && [[ -n "${BOXSTRAP_APP_DIR:-}" && -d "${BOXSTRAP_APP_DIR}" ]]; then
    local files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}" f
    BS_COMPOSE_ARGS=()
    for f in $files; do BS_COMPOSE_ARGS+=(-f "$f"); done
    if confirm "Also stop & remove '$name' containers now (named data volumes are kept)?"; then
      _compose down || true
    fi
  fi
  reg_remove "$name"
  log_ok "$name unregistered from boxstrap."
}
