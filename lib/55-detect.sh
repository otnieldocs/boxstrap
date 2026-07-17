#!/usr/bin/env bash
# Phase: detect — infer the stack from dependency manifests and print the host
# implications in plain English. This is the teaching step: it explains WHY the
# kernel/compose settings that follow are needed. It also sets the flags the
# kernel-tuning phase reads. Config may force flags (detection cannot see a repo
# that has not been cloned yet in single-phase runs).

bs_detect() {
  local dir="${BOXSTRAP_APP_DIR:-}"
  export BS_NEEDS_REDIS_TUNING=false BS_NEEDS_BROWSER=false

  local -a found=()
  local blob=""
  [[ -f "$dir/requirements.txt" ]] && blob+=" $(tr '[:upper:]' '[:lower:]' < "$dir/requirements.txt")" && found+=("Python")
  [[ -f "$dir/pyproject.toml" ]]   && blob+=" $(tr '[:upper:]' '[:lower:]' < "$dir/pyproject.toml")"
  [[ -f "$dir/package.json" ]]     && blob+=" $(tr '[:upper:]' '[:lower:]' < "$dir/package.json")" && found+=("Node.js")
  [[ -f "$dir/go.mod" ]]           && found+=("Go")

  printf '%s' "$blob" | grep -qE 'fastapi|uvicorn'          && found+=("FastAPI (ASGI)")
  printf '%s' "$blob" | grep -qE 'django|flask|gunicorn'    && found+=("WSGI web")
  printf '%s' "$blob" | grep -qE '(^| )celery'              && found+=("Celery workers")
  printf '%s' "$blob" | grep -qE 'psycopg|asyncpg'          && found+=("Postgres client")
  if printf '%s' "$blob" | grep -qE '(^| )redis'; then
    found+=("Redis"); BS_NEEDS_REDIS_TUNING=true
  fi
  if printf '%s' "$blob" | grep -qE 'playwright|selenium|puppeteer'; then
    found+=("Headless browser"); BS_NEEDS_BROWSER=true
  fi

  # Config can force flags for pre-clone / single-phase runs.
  [[ "${BOXSTRAP_FORCE_REDIS_TUNING:-}" == "true" ]] && BS_NEEDS_REDIS_TUNING=true
  [[ "${BOXSTRAP_FORCE_BROWSER:-}" == "true" ]]      && BS_NEEDS_BROWSER=true

  if [[ ${#found[@]} -eq 0 && "$BS_NEEDS_REDIS_TUNING" != "true" && "$BS_NEEDS_BROWSER" != "true" ]]; then
    log_warn "No known dependency manifest found in '$dir' — skipping stack detection."
    return 0
  fi

  [[ ${#found[@]} -gt 0 ]] && log_info "Detected stack: ${found[*]}"
  printf '%sHost implications:%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$BS_NEEDS_REDIS_TUNING" == "true" ]]; then
    printf '  - Redis   -> set vm.overcommit_memory=1 and disable Transparent Huge Pages\n'
    printf '              (prevents fork/save failures and persistence latency spikes).\n'
  fi
  if [[ "$BS_NEEDS_BROWSER" == "true" ]]; then
    printf '  - Browser -> compose sets shm_size, ipc:host, init:true, non-root, ~1GB RAM/context\n'
    printf '              (Chromium crashes on the 64MB default /dev/shm).\n'
  fi
  printf '  - Everything else (runtime, libraries, browser binary) ships in the image, not the host.\n'
}
