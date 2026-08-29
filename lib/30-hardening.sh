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
  #
  # ⚠️ THE FILENAME IS LOAD-BEARING. sshd takes the FIRST occurrence of a
  # keyword and ignores every later one — the opposite of almost every other
  # drop-in system, where the last file wins. Ubuntu cloud images ship
  # /etc/ssh/sshd_config.d/50-cloud-init.conf containing
  # `PasswordAuthentication yes`, so a file named 99-boxstrap.conf sorted AFTER
  # it and its `PasswordAuthentication no` was dead text. Verified on a fresh
  # Ubuntu 24.04 box: the drop-in said no, `sshd -T` said yes.
  #
  # Nothing failed and nothing warned. Hardening reported success while leaving
  # password auth enabled — the exact silent-success shape this tool exists to
  # avoid. Hence 01-, which sorts before anything the image ships.
  local pw_line="# PasswordAuthentication left unchanged by boxstrap"
  [[ "$disable_pw" == "true" ]] && pw_line="PasswordAuthentication no"
  write_file /etc/ssh/sshd_config.d/01-boxstrap.conf "\
# Managed by boxstrap — do not edit by hand.
# Named 01- deliberately: sshd honours the FIRST occurrence of a keyword, and
# the cloud-init drop-in (50-) would otherwise win.
PermitRootLogin no
PubkeyAuthentication yes
${pw_line}
"
  # Remove the old, ineffective 99- file from boxes provisioned before this fix.
  if [[ -f /etc/ssh/sshd_config.d/99-boxstrap.conf ]]; then
    log_info "Removing the superseded 99-boxstrap.conf (it sorted after cloud-init and never applied)"
    bs_run rm -f /etc/ssh/sshd_config.d/99-boxstrap.conf
  fi
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
  # ⚠️ These two settings interact badly for the person running boxstrap: root
  # login was just disabled, and the natural next move is to check that it was.
  # Every such check is a failed auth, ssh offers EVERY key in your agent, and
  # each rejected offer is counted separately — so two or three probes with a
  # couple of keys loaded crosses the default maxretry of 5 and bans you. The
  # ban is a REJECT, so it looks exactly like a dead sshd: "Connection refused"
  # while ICMP still answers. It cost a real debugging session.
  log_warn "Root SSH is now closed and fail2ban is live. Do NOT test it by running
  'ssh root@<host>' — each attempt offers every key in your agent, each rejected
  offer counts toward maxretry (default 5), and you will ban yourself for
  ~10 minutes. A ban REJECTs, so it looks like a dead daemon, not a ban.
  Connect as '${user}' instead; if you are already locked out, wait out
  bantime or clear it from the console with: fail2ban-client unban --all"

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
