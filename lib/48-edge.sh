#!/usr/bin/env bash
# Shared edge reverse-proxy — lets MULTIPLE stacks share one box behind a single
# Caddy on :80/:443. The default `caddy` TLS mode embeds a Caddy in each app's
# compose, so only one such stack can own the host ports. A stack that sets
# `BOXSTRAP_TLS_PROVIDER=edge` instead registers its domain -> upstream with this
# shared proxy and runs NO Caddy of its own.
#
# boxstrap OWNS the edge stack end to end (a generated compose + an aggregate
# Caddyfile under BOXSTRAP_EDGE_DIR); it is regenerated on every stack
# deploy/update/remove so the proxy always reflects the registered edge stacks.
#
# Contract for an edge-mode app's compose: attach the fronted service to the
# external `BOXSTRAP_EDGE_NET` network with a stable alias, and set
# BOXSTRAP_TLS_UPSTREAM="<alias>:<port>" so Caddy can resolve it across projects.

BOXSTRAP_EDGE_DIR="${BOXSTRAP_EDGE_DIR:-/opt/boxstrap-edge}"
BOXSTRAP_EDGE_NET="${BOXSTRAP_EDGE_NET:-boxstrap-edge}"

# bs_write_edge_compose — (re)generate the edge proxy's compose file. Idempotent.
bs_write_edge_compose() {
  local content
  content="$(cat <<YAML
# boxstrap edge proxy — GENERATED, do not edit by hand.
# One shared Caddy fronting every edge-mode stack on this box (TLS + routing).
# boxstrap regenerates this on each stack deploy/update/remove.
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - ${BOXSTRAP_EDGE_NET}

networks:
  ${BOXSTRAP_EDGE_NET}:
    external: true

volumes:
  caddy-data:
  caddy-config:
YAML
)"
  write_file "$BOXSTRAP_EDGE_DIR/docker-compose.yml" "${content}"$'\n'
}

# bs_write_edge_caddyfile — render the aggregate Caddyfile as one site block per
# registered edge-mode stack. Each stack is read in a subshell so sourcing its
# config never clobbers the caller's environment. Idempotent (via write_file).
bs_write_edge_caddyfile() {
  local content="" name block
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    block="$(
      unset BOXSTRAP_TLS_PROVIDER BOXSTRAP_DOMAIN BOXSTRAP_TLS_UPSTREAM
      reg_load "$name" >/dev/null 2>&1 || exit 0
      [[ "${BOXSTRAP_TLS_PROVIDER:-}" == "edge" \
         && -n "${BOXSTRAP_DOMAIN:-}" && -n "${BOXSTRAP_TLS_UPSTREAM:-}" ]] || exit 0
      printf '%s {\n\treverse_proxy %s\n\tencode gzip\n}\n' \
        "$BOXSTRAP_DOMAIN" "$BOXSTRAP_TLS_UPSTREAM"
    )"
    [[ -n "$block" ]] && content+="$block"$'\n'
  done < <(reg_list)

  local header='# boxstrap edge proxy — GENERATED aggregate of every edge-mode stack. Do not edit.'
  write_file "$BOXSTRAP_EDGE_DIR/Caddyfile" "${header}"$'\n'"${content}"
  log_ok "Edge Caddyfile rendered ($BOXSTRAP_EDGE_DIR/Caddyfile)"
}

# bs_edge_ensure — make sure the shared network + proxy exist and are current:
# write the compose + aggregate Caddyfile, create the network once, start/refresh
# the proxy. (Applying a changed Caddyfile to a RUNNING Caddy is bs_edge_reload.)
bs_edge_ensure() {
  local dir="$BOXSTRAP_EDGE_DIR"
  bs_write_edge_compose
  bs_write_edge_caddyfile
  # External network shared across compose projects — create once.
  bs_run_sh "docker network inspect ${BOXSTRAP_EDGE_NET} >/dev/null 2>&1 || docker network create ${BOXSTRAP_EDGE_NET}"
  if is_dry; then
    log "[dry-run] (cd $dir && docker compose up -d)"
    return 0
  fi
  ( cd "$dir" && docker compose up -d ) \
    || { log_err "edge proxy failed to start — inspect: (cd $dir && docker compose logs)"; return 1; }
}

# bs_edge_reload — apply the freshly rendered Caddyfile to the running proxy with
# a zero-downtime reload; fall back to a recreate if the admin reload fails.
bs_edge_reload() {
  local dir="$BOXSTRAP_EDGE_DIR"
  if is_dry; then
    log "[dry-run] (cd $dir && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile)"
    return 0
  fi
  if ( cd "$dir" && docker compose exec -T caddy caddy reload \
        --config /etc/caddy/Caddyfile --adapter caddyfile ); then
    log_ok "Edge proxy reloaded"
  else
    log_warn "Graceful reload failed — recreating the edge proxy"
    ( cd "$dir" && docker compose up -d --force-recreate )
  fi
}

# bs_edge_sync — full reconcile of the shared proxy against the current registry.
# Safe to call any time (e.g. `boxstrap edge`); used after deploy/refresh/remove.
bs_edge_sync() {
  bs_edge_ensure || return 1
  bs_edge_reload
  log_ok "Edge proxy synced"
}

# bs_edge_phase — post-app-up hook. No-op unless the CURRENTLY LOADED stack uses
# the edge proxy, so it is safe to run unconditionally in the deploy pipeline.
bs_edge_phase() {
  [[ "${BOXSTRAP_TLS_PROVIDER:-}" == "edge" ]] || return 0
  log_step "Phase: edge (sync shared reverse proxy)"
  bs_edge_sync
}
