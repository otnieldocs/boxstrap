#!/usr/bin/env bash
# Phase: kernel-tuning — host settings a container cannot set for itself. Applied
# only when the detect phase flags Redis. On container-virtualized hosts the
# kernel is not ours to change, so we skip and say so.

bs_kernel_tuning() {
  if [[ "${BS_NEEDS_REDIS_TUNING:-false}" != "true" ]]; then
    log_info "No Redis detected — skipping kernel tuning."
    return 0
  fi
  if [[ "$BS_VIRT" == "openvz" || "$BS_VIRT" == "lxc" || "$BS_VIRT" == "lxc-libvirt" ]]; then
    log_warn "Container-virt host ($BS_VIRT): cannot set kernel sysctls/THP. Apply Redis tuning on the hypervisor."
    return 0
  fi

  # 1. Overcommit — so Redis fork() (RDB/AOF save) does not fail under memory load.
  bs_run sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
  write_file /etc/sysctl.d/99-boxstrap-redis.conf $'vm.overcommit_memory=1\n'

  # 2. Disable Transparent Huge Pages — not a sysctl, so a oneshot boot unit.
  write_file /etc/systemd/system/disable-thp.service '[Unit]
Description=Disable Transparent Huge Pages (Redis best practice)
After=sysinit.target local-fs.target
Before=docker.service redis-server.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=basic.target
'
  bs_run systemctl daemon-reload
  bs_run systemctl enable --now disable-thp.service 2>/dev/null || true
  log_ok "Redis kernel tuning applied (overcommit=1, THP disabled)"
}
