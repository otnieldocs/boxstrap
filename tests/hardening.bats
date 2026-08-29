#!/usr/bin/env bats
# Unit tests for lib/30-hardening.sh.
#
# ⚠️ The bug these pin produced NO error. boxstrap wrote
# `PasswordAuthentication no` into a file named 99-boxstrap.conf, logged
# "SSH hardened", and left password auth ON — because sshd honours the FIRST
# occurrence of a keyword and Ubuntu's cloud image ships 50-cloud-init.conf
# saying yes. Verified on a real box: drop-in said no, `sshd -T` said yes.

setup() {
  BOXSTRAP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BOXSTRAP_DRY_RUN=true
  export BOXSTRAP_NONINTERACTIVE=true
  source "$BOXSTRAP_ROOT/lib/util.sh"
  source "$BOXSTRAP_ROOT/lib/30-hardening.sh"
}

@test "the sshd drop-in sorts BEFORE anything the cloud image ships" {
  # Ubuntu ships 50-cloud-init.conf and 60-cloudimg-settings.conf. Ours must
  # sort ahead of both, or its directives are dead text.
  run grep -o 'sshd_config\.d/[0-9]*-boxstrap\.conf' "$BOXSTRAP_ROOT/lib/30-hardening.sh"
  [ "$status" -eq 0 ]
  local prefix
  prefix="$(printf '%s\n' "$output" | head -1 | sed -E 's|.*/([0-9]+)-boxstrap\.conf|\1|')"
  [ "$prefix" -lt 50 ]
}

@test "the superseded 99- drop-in is removed on re-run" {
  run grep -c 'rm -f /etc/ssh/sshd_config.d/99-boxstrap.conf' "$BOXSTRAP_ROOT/lib/30-hardening.sh"
  [ "$output" -ge 1 ]
}

@test "hardening warns that probing root@ will self-ban via fail2ban" {
  # The interaction cost a real debugging session: root login is disabled and
  # fail2ban enabled in the same phase, so verifying the former trips the latter.
  run grep -c "ban yourself" "$BOXSTRAP_ROOT/lib/30-hardening.sh"
  [ "$output" -ge 1 ]
}

@test "the drop-in still turns root login off and keys on" {
  run grep -A6 'write_file /etc/ssh/sshd_config.d/01-boxstrap.conf' "$BOXSTRAP_ROOT/lib/30-hardening.sh"
  [[ "$output" == *"PermitRootLogin no"* ]]
  [[ "$output" == *"PubkeyAuthentication yes"* ]]
}

@test "password auth is left UNCHANGED when the lockout guard trips" {
  # No key for the deploy user => boxstrap must not disable passwords.
  run grep -c 'disable_pw="unchanged"' "$BOXSTRAP_ROOT/lib/30-hardening.sh"
  [ "$output" -ge 1 ]
}
