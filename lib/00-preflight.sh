#!/usr/bin/env bash
# Phase: preflight — verify we can run here and detect the environment. The
# detected facts (OS, virt type, cgroup version) drive later phases.

# bs_virt_detect — set BS_VIRT unless it is already set.
#
# ⚠️ Lives outside bs_preflight because two LATER phases read BS_VIRT
# (bs_swap, bs_kernel_tuning) and `--only <phase>` skips preflight. Under
# `set -u` that made `--only swap` and `--only kernel-tuning` abort with
# "BS_VIRT: unbound variable" — and `--only kernel-tuning` is the example the
# README gives for re-running a single phase. Detection is idempotent and
# cheap, so the readers call this themselves rather than depending on ordering.
bs_virt_detect() {
  [[ -n "${BS_VIRT:-}" ]] && return 0
  if have systemd-detect-virt; then
    BS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  [[ -n "${BS_VIRT:-}" ]] || BS_VIRT="unknown"
  export BS_VIRT
}

bs_preflight() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release — unsupported OS"
  # Read in subshells so os-release's own variables (NAME, VERSION, ID, ...) can
  # never leak into and clobber boxstrap globals (this once ate a service NAME).
  # shellcheck disable=SC1091
  BS_OS_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}")"
  # shellcheck disable=SC1091
  BS_OS_VER="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}")"
  export BS_OS_ID BS_OS_VER

  if [[ "$BS_OS_ID" != "ubuntu" ]]; then
    log_warn "boxstrap targets Ubuntu; detected '$BS_OS_ID $BS_OS_VER'. Hardening is Ubuntu-tuned."
  fi
  case "$BS_OS_VER" in
    22.04|24.04) log_ok "Ubuntu $BS_OS_VER (supported)" ;;
    *)           log_warn "Ubuntu '$BS_OS_VER' is untested (supported: 22.04, 24.04)." ;;
  esac

  # Virtualization decides whether kernel-level tweaks are even possible.
  bs_virt_detect
  case "$BS_VIRT" in
    kvm|qemu|none|"")     log_ok "Virtualization: ${BS_VIRT:-bare-metal} (full kernel control)" ;;
    openvz|lxc|lxc-libvirt)
      log_warn "Virtualization: $BS_VIRT — no kernel control. Swap file and kernel sysctls may be host-managed; boxstrap skips what it cannot do." ;;
    *)                    log_info "Virtualization: $BS_VIRT" ;;
  esac

  # cgroup version explains the Docker 'no swap limit capabilities' warning.
  if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)" == "cgroup2fs" ]]; then
    export BS_CGROUP=v2
    log_ok "cgroup v2 (the Docker swap-limit warning will not appear)"
  else
    export BS_CGROUP=v1
    log_info "cgroup v1 (Docker may warn 'no swap limit capabilities' — benign; explained in the swap phase)"
  fi
}
