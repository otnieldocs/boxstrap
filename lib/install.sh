#!/usr/bin/env bash
# CLI installer — put a `boxstrap` launcher on PATH so it runs from any directory
# (and through sudo's secure PATH). A launcher script, NOT a symlink: boxstrap finds
# its lib/ relative to its own path, and a symlink would resolve BOXSTRAP_ROOT to
# /usr/local/bin and break sourcing. The launcher execs the real script at its real
# path, so lib/ resolves correctly.

bs_install_cli() {
  local target="/usr/local/bin/boxstrap"
  local real="$BOXSTRAP_ROOT/boxstrap"
  if is_dry; then
    log "[dry-run] install launcher $target -> $real"
    return 0
  fi
  printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$target"
  chmod +x "$target"
  log_ok "Installed 'boxstrap' -> $target (execs $real)"
  log_info "You can now run 'sudo boxstrap ...' from any directory."
}
