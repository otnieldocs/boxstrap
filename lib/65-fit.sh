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
#
# ⚠️ It reads `${VAR:-512m}` as 512m, and it DEDUPLICATES per service across
# files, with later files winning. Both matter for the overlay pattern —
# `-f docker-compose.yml -f docker-compose.staging.yml` — and the old version
# got both wrong in the same silent direction:
#
#   * The value pattern required a DIGIT (`[0-9]+[gGmMkK]?`), so every
#     `mem_limit: ${STAGING_API_MEM:-1024m}` simply did not match. Measured on
#     a real staging box: all ten overlay caps were skipped, the phase summed
#     the base file alone, and reported PRODUCTION's 9600MB for a stack whose
#     actual declared caps are 6080MB — overstating by 3520MB while printing a
#     confident "Fits in RAM". The verdict was right by luck, not measurement.
#   * Without dedupe, an overlay that overrides a cap with a LITERAL is counted
#     twice — base + override — inflating the total by the base value.
#
# A skipped value is now reported as unverifiable rather than dropped. Silence
# is the one thing this phase must never do: its whole purpose is to catch what
# Compose will not complain about.
bs__fit_memory() {
  local dir="$1" files="${BOXSTRAP_COMPOSE_FILES:-docker-compose.yml}"
  local total=0 count=0 f line svc val mb i found

  # bash 3.2 (macOS) has no associative arrays — parallel arrays + a linear
  # scan. Service counts are small; this is not the hot path.
  local -a names=() mbs=() unverifiable=()

  for f in $files; do
    [[ -f "$dir/$f" ]] || continue
    svc=""
    while IFS= read -r line; do
      # A service header is exactly two spaces, a name, a colon, end of line.
      if [[ "$line" =~ ^\ \ ([a-zA-Z0-9._-]+):[[:space:]]*$ ]]; then
        svc="${BASH_REMATCH[1]}"
        continue
      fi
      [[ "$line" =~ ^[[:space:]]*mem_limit:[[:space:]]*(.+)$ ]] || continue
      val="${BASH_REMATCH[1]}"
      val="${val%%#*}"                                  # trailing comment
      val="$(printf '%s' "$val" | tr -d '"'"'"'[:space:]')"

      if [[ "$val" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}$ ]]; then
        val="${BASH_REMATCH[1]}"                        # ${VAR:-512m} -> 512m
      elif [[ "$val" == \$* ]]; then
        # ${VAR} with no default: the value lives in .env, which this check does
        # not read. Name it rather than dropping it.
        unverifiable+=("${svc:-<unknown>}")
        continue
      fi

      mb="$(bs__fit_mb "$val")"
      [[ -n "$mb" ]] || { unverifiable+=("${svc:-<unknown>}"); continue; }

      # Upsert: a later file overriding the same service replaces its cap,
      # exactly as `docker compose -f a -f b` resolves it.
      found=""
      for (( i = 0; i < ${#names[@]}; i++ )); do
        if [[ "${names[$i]}" == "${svc:-<unknown>}" ]]; then
          mbs[$i]="$mb"; found=yes; break
        fi
      done
      [[ -n "$found" ]] || { names+=("${svc:-<unknown>}"); mbs+=("$mb"); }
    done < "$dir/$f"
  done

  count="${#names[@]}"
  for (( i = 0; i < count; i++ )); do total=$(( total + ${mbs[$i]} )); done

  if [[ ${#unverifiable[@]} -gt 0 ]]; then
    log_warn "mem_limit not statically readable for: ${unverifiable[*]}
  These interpolate a variable with no default, so the real cap lives in .env
  and is NOT included in the total below. Reported rather than skipped."
  fi

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
