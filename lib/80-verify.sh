#!/usr/bin/env bash
# Phase: verify — the health gate. boxstrap stops here on purpose: wiring the
# caller, canary, and cutover are deliberate human decisions, not automation.

bs_verify() {
  local url="${BOXSTRAP_HEALTH_URL:-}"
  local expect="${BOXSTRAP_HEALTH_EXPECT:-}"
  local prot="${BOXSTRAP_PROTECTED_URL:-}"

  if [[ -z "$url" ]]; then
    log_warn "No BOXSTRAP_HEALTH_URL set — skipping verify."
    return 0
  fi
  if is_dry; then
    log "[dry-run] curl $url (expect substring: ${expect:-<any 2xx>})"
    return 0
  fi

  log_info "Waiting for health at $url"
  local body ok=false
  for _ in $(seq 1 30); do
    body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    if [[ -n "$body" ]] && { [[ -z "$expect" ]] || [[ "$body" == *"$expect"* ]]; }; then
      ok=true
      log_ok "Health OK: $body"
      break
    fi
    sleep 3
  done
  [[ "$ok" == "true" ]] || { log_err "Health check failed after ~90s at $url"; return 1; }

  # Auth must be enforced — a keyless request should be rejected.
  if [[ -n "$prot" ]]; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$prot" \
      -H 'content-type: application/json' -d '{}' 2>/dev/null || echo 000)"
    if [[ "$code" == "401" ]]; then
      log_ok "Auth enforced (keyless request -> 401)"
    else
      log_warn "Expected 401 from $prot without a key, got $code — verify service-key auth."
    fi
  fi

  log_ok "Verify passed. Next (manual): wire the caller + canary per the stack runbook."
}
