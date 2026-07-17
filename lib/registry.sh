#!/usr/bin/env bash
# Service registry + host-provision marker. State lives OUTSIDE the git repo
# (default /etc/boxstrap) so re-cloning boxstrap never loses your registered
# services. Override the location with BOXSTRAP_STATE_DIR (used by tests).

BOXSTRAP_STATE_DIR="${BOXSTRAP_STATE_DIR:-/etc/boxstrap}"
BOXSTRAP_REG_DIR="$BOXSTRAP_STATE_DIR/stacks"
BOXSTRAP_HOST_MARKER="$BOXSTRAP_STATE_DIR/.provisioned"

reg_path()   { printf '%s/%s.conf' "$BOXSTRAP_REG_DIR" "$1"; }
reg_exists() { [[ -f "$(reg_path "$1")" ]]; }

# reg_list — print one registered service name per line (none => no output).
reg_list() {
  [[ -d "$BOXSTRAP_REG_DIR" ]] || return 0
  local f
  for f in "$BOXSTRAP_REG_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    basename "$f" .conf
  done
}

# reg_load NAME — source a stack's config into the environment.
reg_load() {
  local p; p="$(reg_path "$1")"
  [[ -f "$p" ]] || { log_err "no such service: $1"; return 1; }
  # shellcheck disable=SC1090
  source "$p"
}

# reg_save NAME LINE... — write a stack config atomically (chmod 600). Each LINE
# is a literal `KEY=value` string.
reg_save() {
  local name="$1"; shift
  local p; p="$(reg_path "$name")"
  if is_dry; then
    printf '%s[dry-run]%s write stack config %s\n' "$C_DIM" "$C_RESET" "$p"
    return 0
  fi
  mkdir -p "$BOXSTRAP_REG_DIR"
  {
    printf '# boxstrap stack — %s (managed by boxstrap)\n' "$name"
    printf '%s\n' "$@"
  } > "$p"
  chmod 600 "$p"
}

# reg_remove NAME — delete a stack's registration (does not touch its containers).
reg_remove() {
  local p; p="$(reg_path "$1")"
  is_dry && { printf '%s[dry-run]%s rm %s\n' "$C_DIM" "$C_RESET" "$p"; return 0; }
  rm -f "$p"
}

host_provisioned() { [[ -f "$BOXSTRAP_HOST_MARKER" ]]; }

# mark_host_provisioned [SOURCE] — record that host setup is done.
mark_host_provisioned() {
  is_dry && return 0
  mkdir -p "$BOXSTRAP_STATE_DIR"
  printf 'provisioned by boxstrap (%s) at %s\n' \
    "${1:-boxstrap}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$BOXSTRAP_HOST_MARKER"
}
