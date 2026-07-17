#!/usr/bin/env bash
# Phase: preflight — verify we can run here and detect the environment. The
# detected facts (OS, virt type, cgroup version) drive later phases.

bs_preflight() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release — unsupported OS"
  # shellcheck disable=SC1091
  source /etc/os-release
  export BS_OS_ID="${ID:-unknown}" BS_OS_VER="${VERSION_ID:-unknown}"

  if [[ "$BS_OS_ID" != "ubuntu" ]]; then
    log_warn "boxstrap targets Ubuntu; detected '$BS_OS_ID $BS_OS_VER'. Hardening is Ubuntu-tuned."
  fi
  case "$BS_OS_VER" in
    22.04|24.04) log_ok "Ubuntu $BS_OS_VER (supported)" ;;
    *)           log_warn "Ubuntu '$BS_OS_VER' is untested (supported: 22.04, 24.04)." ;;
  esac

  # Virtualization decides whether kernel-level tweaks are even possible.
  if have systemd-detect-virt; then
    BS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  else
    BS_VIRT="unknown"
  fi
  export BS_VIRT
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
