#!/usr/bin/env bash
# Phase: hardening — non-root sudo user, key-only SSH (with a lockout guard),
# firewall, brute-force protection, and automatic security updates.

bs_hardening() {
  local user="${BOXSTRAP_DEPLOY_USER:-deploy}"

  # 1. Non-root sudo user.
  if id "$user" >/dev/null 2>&1; then
    log_ok "User '$user' exists"
  else
    log_info "Creating non-root sudo user '$user'"
    bs_run adduser --disabled-password --gecos "" "$user"
  fi
  bs_run usermod -aG sudo "$user"

  # Passwordless sudo: the account has no password (--disabled-password) and
  # password SSH is disabled, so a sudo password would be unusable. NOPASSWD is
  # the standard key-only-admin pattern (you're already authenticated by SSH key).
  bs__install_sudoers "$user"

  # 2. Seed the user's SSH key from root BEFORE we disable password auth.
  if [[ -f /root/.ssh/authorized_keys ]]; then
    bs_run install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
    bs_run install -m 600 -o "$user" -g "$user" \
      /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"
  fi

  # 3. Lockout guard — never turn off passwords without a usable key in place.
  local have_key=false
  if is_dry; then
    have_key=true
  elif [[ -s "/home/$user/.ssh/authorized_keys" ]]; then
    have_key=true
  fi

  local disable_pw="${BOXSTRAP_SSH_DISABLE_PASSWORD:-true}"
  if [[ "$disable_pw" == "true" && "$have_key" != "true" ]]; then
    log_warn "No SSH key for '$user' — refusing to disable password auth (would lock you out)."
    log_warn "Add your key to /home/$user/.ssh/authorized_keys and re-run, or set BOXSTRAP_SSH_DISABLE_PASSWORD=false."
    disable_pw="unchanged"
  fi

  # 4. sshd drop-in (idempotent; we never sed the distro's main config).
  local pw_line="# PasswordAuthentication left unchanged by boxstrap"
  [[ "$disable_pw" == "true" ]] && pw_line="PasswordAuthentication no"
  write_file /etc/ssh/sshd_config.d/99-boxstrap.conf "\
# Managed by boxstrap — do not edit by hand.
PermitRootLogin no
PubkeyAuthentication yes
${pw_line}
"
  bs_run systemctl reload ssh 2>/dev/null \
    || bs_run systemctl reload sshd 2>/dev/null \
    || log_warn "could not reload ssh — apply the change manually"
  log_ok "SSH hardened (root login off; password auth: $disable_pw)"

  # 5. Firewall — allow only the configured ports.
  local ports="${BOXSTRAP_UFW_ALLOW:-22,80,443}" p
  bs_run apt-get install -y ufw
  local _ufw
  IFS=',' read -ra _ufw <<< "$ports"
  for p in "${_ufw[@]}"; do
    p="${p// /}"
    [[ -n "$p" ]] && bs_run ufw allow "$p"
  done
  bs_run ufw --force enable
  log_ok "UFW active, allowing: $ports"

  # 6. Brute-force protection (default sshd jail).
  bs_run apt-get install -y fail2ban
  bs_run systemctl enable --now fail2ban
  log_ok "fail2ban running"

  # 7. Automatic security updates.
  bs_run apt-get install -y unattended-upgrades
  bs_run systemctl enable --now unattended-upgrades 2>/dev/null || true
  log_ok "unattended-upgrades enabled"
}

# bs__install_sudoers USER — install a NOPASSWD sudoers drop-in, validated with
# visudo BEFORE it goes live so a malformed file can never break sudo.
bs__install_sudoers() {
  local user="$1"
  local f="/etc/sudoers.d/90-boxstrap-${user}"
  if is_dry; then
    printf '%s[dry-run]%s install NOPASSWD sudoers for %s -> %s\n' \
      "$C_DIM" "$C_RESET" "$user" "$f"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 440 -o root -g root "$tmp" "$f"
    log_ok "Passwordless sudo enabled for '$user'"
  else
    log_err "generated sudoers failed validation — not installing (sudo left unchanged)"
  fi
  rm -f "$tmp"
}
