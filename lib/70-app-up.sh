#!/usr/bin/env bash
# Phase: app-up — pull the pre-built image(s) and start the stack. Registry-pull
# only: the image is built in CI, never on this box (which may be shared with
# other workloads). Runs compose as the non-root deploy user.

bs_app_up() {
  local dir="${BOXSTRAP_APP_DIR:?BOXSTRAP_APP_DIR required}"
  local files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}"

  local -a args=()
  local f
  for f in $files; do args+=(-f "$f"); done

  log_info "Pulling images and starting the stack"
  if is_dry; then
    log "[dry-run] (cd $dir && docker compose ${args[*]} pull && docker compose ${args[*]} up -d)"
    return 0
  fi

  # Run as root (boxstrap's own context) so the registry login done in app-fetch
  # is the same credential store used for the pull. Containers still run as their
  # image's non-root user.
  ( cd "$dir" && docker compose "${args[@]}" pull && docker compose "${args[@]}" up -d ) \
    || die "compose up failed — inspect: (cd $dir && docker compose ${args[*]} logs)"
  log_ok "Stack is up"
}
