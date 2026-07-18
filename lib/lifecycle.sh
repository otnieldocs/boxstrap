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
  bs_edge_phase          # sync the shared proxy if this stack is edge-mode
  bs_verify
}

# bs_svc_update NAME — pull the newest image and recreate. This is the
# "rebuild when a new image is published" action. Relies on the registry login
# established at deploy time (persisted in root's docker config).
bs_svc_update() {
  _svc_prep "$1" || return 1
  # A failed refresh must ABORT — never pull a new image against stale manifests.
  if [[ "${BS_REFRESH:-false}" == "true" ]]; then
    _svc_refresh_files "$1" || return 1
  fi
  log_step "Update: $1 (pull new image + recreate)"
  _compose pull || { log_err "pull failed — the registry login may have expired; re-deploy to re-authenticate."; return 1; }
  _compose up -d
  _svc_health "$1"
  log_ok "$1 updated."
}

# _svc_refresh_files NAME — refresh the deploy manifests before an update (used by
# `update --refresh`): git-pull the app repo (as its owner, to avoid git's
# dubious-ownership guard and keep the tree owned consistently) and regenerate the
# Caddyfile from the stack config. A plain `update` only pulls the image, so this is
# how a changed docker-compose file or TLS setting reaches the box.
_svc_refresh_files() {
  local dir="$BOXSTRAP_APP_DIR" owner
  if [[ -d "$dir/.git" ]]; then
    owner="$(stat -c '%U' "$dir" 2>/dev/null || echo root)"
    log_info "Refreshing $1: git pull ($dir, as $owner)"
    # boxstrap owns the generated Caddyfile and writes it INTO the repo tree, so
    # discard any local change to it first — otherwise a dirty working tree blocks
    # the fast-forward pull. It is regenerated below anyway.
    local pull_cmd="cd '$dir' && { git checkout -- Caddyfile 2>/dev/null || true; } && git pull --ff-only"
    local rc=0
    if is_dry; then
      log "[dry-run] git pull --ff-only in $dir (as $owner)"
    elif [[ "$(id -un)" == "$owner" ]]; then
      # Already the owner (also lets this run in tests) — no su needed.
      bash -c "$pull_cmd" || rc=$?
    else
      su - "$owner" -c "$pull_cmd" || rc=$?
    fi
    # ABORT on a failed pull — deploying stale manifests silently is the bug this
    # replaces (a failed pull used to only warn, then continue with old files).
    if [[ $rc -ne 0 ]]; then
      log_err "git pull failed in $dir — refusing to deploy stale manifests."
      log_err "Resolve it (git -C '$dir' status; discard boxstrap-owned files with git -C '$dir' checkout -- .), then retry."
      return 1
    fi
  fi
  bs_write_caddyfile "$dir"
  bs_edge_phase   # edge-mode: re-render the aggregate proxy config + reload
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

# bs__rewrite_stack_domain NAME OLD NEW — replace the old host with the new one
# everywhere in the registered config (BOXSTRAP_DOMAIN plus any HEALTH/PROTECTED
# URL that embeds it), preserving comments and the file's 600 perms/inode.
bs__rewrite_stack_domain() {
  local name="$1" old="$2" new="$3" p; p="$(reg_path "$name")"
  if is_dry; then
    log "[dry-run] rewrite $p: $old -> $new (BOXSTRAP_DOMAIN + embedded URLs)"
    return 0
  fi
  local tmp line; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Quoted pattern => literal replacement (a domain has no glob metachars).
    printf '%s\n' "${line//"$old"/"$new"}"
  done < "$p" > "$tmp"
  cat "$tmp" > "$p"   # overwrite content, keep the file's perms/inode
  rm -f "$tmp"
}

# bs__reload_embedded_caddy NAME — regenerate the app's own Caddyfile from the
# updated config and reload its Caddy so the new domain (and cert) take effect.
bs__reload_embedded_caddy() {
  local name="$1"
  _svc_prep "$name" || return 1
  bs_write_caddyfile "$BOXSTRAP_APP_DIR"
  if is_dry; then
    log "[dry-run] (cd $BOXSTRAP_APP_DIR && docker compose ${BS_COMPOSE_ARGS[*]} exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile)"
    return 0
  fi
  if _compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
    log_ok "Reloaded embedded Caddy for $name"
  else
    log_warn "Couldn't reload the 'caddy' service — recreating the stack to apply the new domain"
    _compose up -d --force-recreate
  fi
}

# bs_set_domain NAME NEW — change the public domain of a registered stack and
# apply it live. Updates the config, warns about DNS, then reloads whichever
# proxy fronts the stack (shared edge or the app's own Caddy).
bs_set_domain() {
  local name="$1" new="${2:-}"
  [[ -n "$name" && -n "$new" ]] || { log_err "usage: boxstrap set-domain <name> <new-domain>"; return 1; }
  reg_load "$name" || return 1
  local old="${BOXSTRAP_DOMAIN:-}"
  [[ -n "$old" ]] || { log_err "$name has no BOXSTRAP_DOMAIN — it isn't a TLS-fronted stack."; return 1; }
  if [[ "$old" == "$new" ]]; then log_ok "$name already serves $new — nothing to change."; return 0; fi

  log_step "Change domain: $name ($old -> $new)"
  bs__rewrite_stack_domain "$name" "$old" "$new" || return 1
  log_ok "Config updated: $(reg_path "$name")"
  log_warn "DNS: point an A-record for $new at this box BEFORE it can get a cert (Caddy uses an HTTP-01 challenge on :80)."

  reg_load "$name"   # re-source with the new values
  case "${BOXSTRAP_TLS_PROVIDER:-}" in
    edge)  bs_edge_sync ;;
    caddy) bs__reload_embedded_caddy "$name" ;;
    *)     log_warn "$name TLS provider is '${BOXSTRAP_TLS_PROVIDER:-none}' — config changed, but no proxy was reloaded." ;;
  esac
  log_ok "$name now serves $new. Update any dependent config yourself (e.g. callback URLs, an app's upstream base URL)."
}

# bs_svc_set_domain NAME — interactive wrapper: prompt for the new domain.
bs_svc_set_domain() {
  local name="$1" new=""
  reg_load "$name" 2>/dev/null
  prompt new "New domain for $name (current: ${BOXSTRAP_DOMAIN:-none})" "${BOXSTRAP_DOMAIN:-}"
  [[ -n "$new" ]] || { log_info "Cancelled."; return 0; }
  bs_set_domain "$name" "$new"
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
  local name="$1" was_edge=false
  if reg_load "$name" 2>/dev/null; then
    [[ "${BOXSTRAP_TLS_PROVIDER:-}" == "edge" ]] && was_edge=true
    if [[ -n "${BOXSTRAP_APP_DIR:-}" && -d "${BOXSTRAP_APP_DIR}" ]]; then
      local files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}" f
      BS_COMPOSE_ARGS=()
      for f in $files; do BS_COMPOSE_ARGS+=(-f "$f"); done
      if confirm "Also stop & remove '$name' containers now (named data volumes are kept)?"; then
        _compose down || true
      fi
    fi
  fi
  reg_remove "$name"
  # Drop this stack's site from the shared proxy now that it is gone from the
  # registry (bs_edge_sync re-renders from the remaining edge-mode stacks).
  [[ "$was_edge" == "true" ]] && bs_edge_sync
  log_ok "$name unregistered from boxstrap."
}
