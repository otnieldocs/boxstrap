#!/usr/bin/env bash
# Phase: fit — does this stack actually RUN on this box, with this config?
#
# Everything before this phase prepares the host. This phase is the last chance
# to say "no" while the answer is still cheap. Two questions, both of which
# otherwise surface hours later as something that reads like a different bug:
#
#   1. Does the declared memory fit the machine?      -> bs__fit_memory
#   2. Is every required variable actually set?       -> bs__fit_env
#
# The second is the one that bites hardest, because Docker Compose does not
# treat a missing variable as an error. It substitutes an EMPTY STRING, prints a
# warning nobody reads, and starts the stack. The app then boots "successfully"
# with no API key, no database password, no webhook secret — and fails on first
# use, far from the cause.

bs_fit() {
  local dir="${BOXSTRAP_APP_DIR:?BOXSTRAP_APP_DIR required}"
  bs__fit_memory "$dir"
  bs__fit_env "$dir"
}

# bs__fit_mb VALUE — normalise a compose memory value (2g / 512m / 1536M) to MB.
# Echoes nothing when the value is not parseable, so callers can skip it.
# ⚠️ tr, not ${1,,} — that lowercase expansion is bash 4+, and macOS still ships
# bash 3.2. The failure was not an error either: the substitution aborted the
# function, every value was skipped, and the caller cheerfully reported "no
# mem_limit set on any service" for a compose declaring nine of them.
bs__fit_mb() {
  local v n
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  n="${v%[gmk]}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  case "$v" in
    *g) printf '%s' "$(( n * 1024 ))" ;;
    *m) printf '%s' "$n" ;;
    *k) printf '%s' "$(( n / 1024 ))" ;;
    *)  printf '%s' "$(( n / 1024 / 1024 ))" ;;   # bare bytes
  esac
}

# bs__fit_memory DIR — sum every mem_limit in the compose file(s) and compare it
# against the box.
#
# ⚠️ This WARNS; it does not fail (unless BOXSTRAP_FIT_STRICT=true). mem_limit is
# a ceiling, not a reservation, so declaring more than you have is a normal and
# often deliberate way to run a stack whose services never peak together. The
# useful signal is not "this is illegal" but "you have no headroom if they do".
bs__fit_memory() {
  local dir="$1" files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}"
  local total=0 count=0 f raw mb

  for f in $files; do
    [[ -f "$dir/$f" ]] || continue
    while read -r raw; do
      mb="$(bs__fit_mb "$raw")"
      [[ -n "$mb" ]] || continue
      total=$(( total + mb )); count=$(( count + 1 ))
    done < <(grep -hoE '^[[:space:]]*mem_limit:[[:space:]]*[0-9]+[gGmMkK]?' "$dir/$f" 2>/dev/null \
             | sed -E 's/^[[:space:]]*mem_limit:[[:space:]]*//')
  done

  if [[ "$count" -eq 0 ]]; then
    log_warn "No mem_limit set on any service — one runaway container can take the box down.
  Docker's default is unlimited. Consider capping at least the workers."
    return 0
  fi

  # Overridable only so the comparison below is testable off-Linux; production
  # always reads the real /proc/meminfo.
  local meminfo="${BOXSTRAP_MEMINFO:-/proc/meminfo}"
  if [[ ! -r "$meminfo" ]]; then
    log_info "Declared memory caps: ${total}MB across ${count} service(s) (host totals unreadable here)."
    return 0
  fi

  local ram swap
  ram=$(( $(awk '/^MemTotal:/{print $2}' "$meminfo") / 1024 ))
  swap=$(( $(awk '/^SwapTotal:/{print $2}' "$meminfo") / 1024 ))

  log_info "Declared memory caps: ${total}MB across ${count} service(s); host has ${ram}MB RAM + ${swap}MB swap."

  if [[ "$total" -le "$ram" ]]; then
    log_ok "Fits in RAM with $(( ram - total ))MB to spare."
    return 0
  fi

  local over=$(( total - ram ))
  local msg="Declared caps exceed RAM by ${over}MB (${total}MB vs ${ram}MB).
  mem_limit is a ceiling, not a reservation — this is survivable while the
  services do not peak together, and is a common deliberate choice. But there is
  no headroom left if they do: the kernel OOM-kills the largest cgroup, which is
  usually a worker mid-task, and a container OOM is invisible to both Sentry and
  an app-level health check."
  if [[ "$total" -gt $(( ram + swap )) ]]; then
    msg="$msg
  It also exceeds RAM + swap ($(( ram + swap ))MB), so swap cannot absorb a peak."
  fi

  if [[ "${BOXSTRAP_FIT_STRICT:-false}" == "true" ]]; then
    die "$msg
  BOXSTRAP_FIT_STRICT=true — refusing to deploy. Lower the caps or size up."
  fi
  log_warn "$msg
  Set BOXSTRAP_FIT_STRICT=true in the stack config to make this fatal."
}

# bs__fit_env DIR — every variable the compose interpolates with NO default must
# be set and non-empty in the app's .env.
#
# `${VAR:-fallback}` is fine by construction: the author supplied a value for the
# missing case. A bare `${VAR}` is a REQUIREMENT the author wrote down, and
# Compose will happily satisfy it with "".
bs__fit_env() {
  local dir="$1" files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}"
  local envf="$dir/.env" f

  local -a required=()
  for f in $files; do
    [[ -f "$dir/$f" ]] || continue
    # shellcheck disable=SC2016  # literal ${} is the point — tr strips the syntax
    while read -r v; do required+=("$v"); done < <(
      grep -hoE '\$\{[A-Z][A-Z0-9_]*\}' "$dir/$f" 2>/dev/null \
        | tr -d '${}' | sort -u
    )
  done
  [[ ${#required[@]} -gt 0 ]] || { log_info "No required (no-default) variables in the compose."; return 0; }

  # Deduplicate across files.
  local -a req=()
  while read -r v; do req+=("$v"); done < <(printf '%s\n' "${required[@]}" | sort -u)

  if [[ ! -f "$envf" ]]; then
    if is_dry; then
      log "[dry-run] would check ${#req[@]} required variables against $envf"
      return 0
    fi
    die "No $envf, but the compose requires ${#req[@]} variable(s) with no default.
  Every one of them would reach the containers as an empty string, with no error."
  fi

  local -a missing=() placeholder=()
  local name val allow=" ${BOXSTRAP_FIT_ALLOW_EMPTY:-} "
  for name in "${req[@]}"; do
    [[ "$allow" == *" $name "* ]] && continue
    val="$(sed -n "s/^${name}=//p" "$envf" | head -n1)"
    if [[ -z "$val" ]]; then
      missing+=("$name")
    elif printf '%s' "$val" | grep -qiE 'your[-_]|^your|xxxx|changeme|change_me|placeholder|^<.*>$'; then
      placeholder+=("$name")
    fi
  done

  if [[ ${#placeholder[@]} -gt 0 ]]; then
    log_warn "These still hold a template placeholder from .env.example:
  ${placeholder[*]}
  They are set, so nothing will fail at boot — the feature fails on first use."
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "$envf is missing ${#missing[@]} required variable(s):
  ${missing[*]}
  The compose interpolates each with no default, so Compose substitutes an EMPTY
  STRING and starts the stack anyway. Nothing fails at boot; the feature fails on
  first use, far from the cause. Fill them in and re-run.
  Genuinely-optional ones can be listed in BOXSTRAP_FIT_ALLOW_EMPTY."
  fi

  log_ok "All ${#req[@]} required variable(s) are set in .env."
}
