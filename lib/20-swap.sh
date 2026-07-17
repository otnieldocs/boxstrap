#!/usr/bin/env bash
# Phase: swap — virt-aware HOST swap. Deliberately does NOT set per-container swap
# limits (memswap_limit): we want the browser worker to overflow into host swap
# rather than be OOM-killed. On cgroup v1 Docker may warn about "no swap limit
# capabilities" — that is expected and harmless; mem_limit still caps memory.

bs_swap() {
  local gb="${BOXSTRAP_SWAP_GB:-4}"

  if [[ "$BS_VIRT" == "openvz" || "$BS_VIRT" == "lxc" || "$BS_VIRT" == "lxc-libvirt" ]]; then
    log_warn "Container-virtualized host ($BS_VIRT): swap is hypervisor-managed. Skipping swap file."
  elif [[ -f /swapfile ]] || swapon --show 2>/dev/null | grep -q .; then
    log_ok "Swap already present — leaving it unchanged."
  else
    log_info "Creating ${gb}G swap file at /swapfile"
    bs_run fallocate -l "${gb}G" /swapfile \
      || bs_run dd if=/dev/zero of=/swapfile bs=1M count=$((gb * 1024))
    bs_run chmod 600 /swapfile
    bs_run mkswap /swapfile
    bs_run swapon /swapfile
    append_once /etc/fstab '/swapfile none swap sw 0 0'
    log_ok "${gb}G swap active"
  fi

  # Prefer RAM; use swap as overflow only.
  bs_run sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  write_file /etc/sysctl.d/99-boxstrap-swap.conf $'vm.swappiness=10\n'

  printf '%sNote: boxstrap does not cap container swap (memswap_limit) by design —\n' "$C_DIM"
  printf '  the browser worker overflows to host swap instead of OOM-killing.%s\n' "$C_RESET"
}
