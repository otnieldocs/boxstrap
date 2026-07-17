#!/usr/bin/env bash
# Phase: app-fetch — registry login, clone the compose repo, scaffold secrets.
# Registry token and secrets are read via prompt/env and never passed on argv
# (which would leak in `ps`); the rendered .env is chmod 600.

bs_app_fetch() {
  local dir="${BOXSTRAP_APP_DIR:?BOXSTRAP_APP_DIR required}"
  local repo="${BOXSTRAP_APP_REPO:?BOXSTRAP_APP_REPO required}"
  local user="${BOXSTRAP_DEPLOY_USER:-deploy}"

  bs_run apt-get install -y git

  # 1. Registry login (read-only token) so `compose pull` can fetch private images.
  local reg="${BOXSTRAP_REGISTRY_HOST:-registry.gitlab.com}"
  local reg_user="${BOXSTRAP_REGISTRY_USER:-}"
  local reg_token="${BOXSTRAP_REGISTRY_TOKEN:-}"
  [[ -z "$reg_user" ]] && prompt reg_user "Registry username for $reg" "$reg_user"
  [[ -z "$reg_token" ]] && prompt_secret reg_token "Registry token for $reg (needs read_registry)"
  if [[ -n "$reg_token" ]]; then
    if is_dry; then
      log "[dry-run] docker login $reg -u $reg_user --password-stdin"
    elif printf '%s' "$reg_token" | docker login "$reg" -u "$reg_user" --password-stdin; then
      log_ok "Logged in to $reg"
    else
      log_warn "docker login to $reg failed — check the username/token"
    fi
  else
    log_warn "No registry token provided — 'docker compose pull' may fail for private images."
  fi

  # 2. Clone or fast-forward the compose repo.
  if [[ -d "$dir/.git" ]]; then
    log_info "Repo present at $dir — pulling latest"
    bs_run_sh "cd '$dir' && git pull --ff-only"
  else
    log_info "Cloning $repo -> $dir"
    bs_run git clone "$repo" "$dir"
  fi

  # 3. Scaffold .env (secrets generated where configured; chmod 600).
  bs__scaffold_env "$dir"

  # 4. Generate the Caddy config from the stack settings. boxstrap owns this, so
  #    a missing/uncommitted Caddyfile in the app repo can never break the deploy.
  if [[ "${BOXSTRAP_TLS_PROVIDER:-}" == "caddy" && -n "${BOXSTRAP_DOMAIN:-}" ]]; then
    local upstream="${BOXSTRAP_TLS_UPSTREAM:-api:8000}"
    write_file "$dir/Caddyfile" \
      "$(printf '%s {\n\treverse_proxy %s\n\tencode gzip\n}\n' "$BOXSTRAP_DOMAIN" "$upstream")"
    log_ok "Generated Caddyfile (${BOXSTRAP_DOMAIN} -> ${upstream})"
  fi

  # Own everything as the deploy user LAST — including the .env created above —
  # so the app can read it regardless of which user ends up running compose.
  bs_run chown -R "$user:$user" "$dir"
}

# bs__scaffold_env DIR — create DIR/.env from .env.example and fill generated
# secrets declared in BOXSTRAP_SECRETS_GENERATE ("VAR:hex:N" entries, space-sep).
bs__scaffold_env() {
  local dir="$1" envf="$1/.env"
  if [[ -f "$envf" ]]; then
    log_ok ".env already present — not overwriting"
    bs_run chmod 600 "$envf"
    return 0
  fi
  if [[ ! -f "$dir/.env.example" ]]; then
    log_warn "no .env.example in repo — skipping .env scaffold"
    return 0
  fi
  log_info "Creating .env from .env.example"
  bs_run cp "$dir/.env.example" "$envf"
  bs_run chmod 600 "$envf"

  local spec var kind n val
  for spec in ${BOXSTRAP_SECRETS_GENERATE:-}; do
    var="${spec%%:*}"
    kind="$(printf '%s' "$spec" | cut -d: -f2)"
    n="$(printf '%s' "$spec" | cut -d: -f3)"
    case "$kind" in
      hex) val="$(openssl rand -hex "${n:-32}" 2>/dev/null || true)" ;;
      *)   val="" ;;
    esac
    [[ -z "$val" ]] && continue
    if is_dry; then
      log "[dry-run] set generated secret $var in .env"
    else
      env_set "$envf" "$var" "$val"
      log_ok "Generated $var (set the same value on the caller side if it is shared)"
    fi
  done

  # Prompt for app-supplied secrets (proxy creds, etc.) declared by the stack.
  local pvar pval
  for pvar in ${BOXSTRAP_SECRETS_PROMPT:-}; do
    pval=""
    prompt_secret pval "Value for $pvar (blank = fill in later)"
    [[ -z "$pval" ]] && continue
    if is_dry; then
      log "[dry-run] set prompted secret $pvar in .env"
    else
      env_set "$envf" "$pvar" "$pval"
      log_ok "Set $pvar"
    fi
  done
}
