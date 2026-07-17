#!/usr/bin/env bash
# boxstrap/lib/util.sh — shared helpers. Sourced by bootstrap.sh; defines
# functions only, no side effects. Every mutating helper honours BOXSTRAP_DRY_RUN.

# Colors (disabled when stdout is not a tty).
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BOLD=''
fi

log()      { printf '%s\n' "$*"; }
log_step() { printf '\n%s==>%s %s%s\n' "${C_BLU}${C_BOLD}" "${C_RESET}${C_BOLD}" "$*" "$C_RESET"; }
log_info() { printf '%s-%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
log_ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[err]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

# have CMD — true if CMD is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# is_dry — true when running in --dry-run mode.
is_dry() { [[ "${BOXSTRAP_DRY_RUN:-false}" == "true" ]]; }

# bs_run CMD [ARGS...] — execute, or print in dry-run mode. Use for simple commands
# with no shell operators (pipes/redirection); use bs_run_sh for those.
bs_run() {
  if is_dry; then
    printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

# bs_run_sh 'snippet' — run a shell snippet (pipes/redirects allowed), or print it.
bs_run_sh() {
  if is_dry; then
    printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$1"
    return 0
  fi
  bash -c "$1"
}

# require_root — abort unless effective uid 0 (skipped in dry-run).
require_root() {
  is_dry && return 0
  [[ "$(id -u)" -eq 0 ]] || die "boxstrap must run as root. Try: sudo $0 --config <file>"
}

# append_once FILE LINE — append LINE to FILE only if that exact line is absent.
append_once() {
  local file="$1" line="$2"
  if is_dry; then
    printf '%s[dry-run]%s append to %s: %s\n' "$C_DIM" "$C_RESET" "$file" "$line"
    return 0
  fi
  grep -qxF -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

# write_file FILE CONTENT — write CONTENT to FILE (creating parents). Idempotent:
# skips the write when the file already holds identical content.
write_file() {
  local file="$1" content="$2" dir
  if is_dry; then
    printf '%s[dry-run]%s write %s\n' "$C_DIM" "$C_RESET" "$file"
    return 0
  fi
  dir="$(dirname -- "$file")"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  if [[ -f "$file" && "$(cat -- "$file")" == "$content" ]]; then
    return 0
  fi
  printf '%s' "$content" > "$file"
}

# env_set FILE VAR VALUE — set VAR=VALUE in an env file (replace the line if
# present, else append), preserving the file's permissions. VALUE may contain
# any characters (no sed interpolation, so passwords with / & | are safe).
env_set() {
  local file="$1" var="$2" val="$3" tmp
  tmp="$(mktemp)"
  grep -v "^${var}=" "$file" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$var" "$val" >> "$tmp"
  cat "$tmp" > "$file"   # overwrite content, keep the original file's perms/inode
  rm -f "$tmp"
}

# is_interactive — true unless --non-interactive was passed.
is_interactive() { [[ "${BOXSTRAP_NONINTERACTIVE:-false}" != "true" ]]; }

# prompt VARNAME "Question" ["default"] — read a value into VARNAME. Uses gum when
# available, else plain read. In non-interactive mode, uses the default silently.
prompt() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if ! is_interactive; then
    printf -v "$__var" '%s' "$__def"; return 0
  fi
  if have gum; then
    __ans="$(gum input --prompt "$__q " --value "$__def")"
  else
    read -r -p "$__q [$__def]: " __ans
    [[ -z "$__ans" ]] && __ans="$__def"
  fi
  printf -v "$__var" '%s' "$__ans"
}

# prompt_secret VARNAME "Question" — like prompt but never echoes input. In
# non-interactive mode, keeps whatever VARNAME already holds (e.g. from env).
prompt_secret() {
  local __var="$1" __q="$2" __ans=""
  if ! is_interactive; then
    printf -v "$__var" '%s' "${!__var:-}"; return 0
  fi
  if have gum; then
    __ans="$(gum input --password --prompt "$__q ")"
  else
    read -r -s -p "$__q: " __ans; printf '\n'
  fi
  printf -v "$__var" '%s' "$__ans"
}
