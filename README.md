# boxstrap

Harden a fresh Ubuntu VPS **and** deploy a docker-compose app in one idempotent,
transparent run. No daemon left behind, no lock-in — just readable Bash.

boxstrap sits in the gap between "OS hardening scripts" (which leave you a secure
*empty* box) and "self-hosted PaaS" (which take over the box with a persistent
UI/daemon). It detects your stack from its dependency manifests, applies the
**host-level** settings containers can't set for themselves, and brings the app up
behind TLS — stopping at a health gate. Wiring, canary, and cutover stay manual.

## What makes boxstrap different

Most tools either configure servers *or* deploy apps — and none of them look at
your app to decide what the **host** needs. boxstrap does two things nothing else does:

**App-aware host tuning (shipped).** It reads your dependency manifests, infers the
stack, and applies the kernel/daemon settings a container can't set for itself — then
explains *why*. Your `requirements.txt` has `redis`? It disables Transparent Huge
Pages and sets `vm.overcommit_memory=1`, and tells you those exist and what they
prevent. Ansible would happily run this setup too — but only if *you* already knew to
write it.

**App-aware capacity preflight (planned).** Before it deploys, boxstrap will
cross-reference your compose file's resource demands — replica counts, `mem_limit`s,
browser-worker concurrency — against the box's *actual* RAM, CPU, swap, and
cgroup/kernel capabilities, and warn you *before* something OOM-kills at 3 a.m.:

- *"Your compose runs 3 Chromium workers ≈ 3 GB, but this box has 2 GB — reduce
  concurrency or add swap."*
- *"You set `memswap_limit`, but this kernel has no swap-limit accounting — it
  won't apply."*

Every other tool deploys exactly what you tell it and lets the box fall over.
**Nothing else checks whether your app actually fits the server it's landing on.**

## Usage

```bash
# 1. Copy the template to a real config (real *.conf files are gitignored):
cp stacks/stack.conf.example stacks/my-app.conf
$EDITOR stacks/my-app.conf

# 2. Dry-run first — prints every action, changes nothing:
sudo ./bootstrap.sh --config stacks/my-app.conf --dry-run

# 3. Real run (interactive wizard for secrets):
sudo ./bootstrap.sh --config stacks/my-app.conf

# Non-interactive (secrets from env, e.g. in CI):
BOXSTRAP_REGISTRY_TOKEN=… sudo -E ./bootstrap.sh \
  --config stacks/my-app.conf --non-interactive

# Re-run a single phase:
sudo ./bootstrap.sh --config stacks/my-app.conf --only kernel-tuning
```

## Phases

Run in order; each is idempotent and re-runnable:

| Phase | Does |
|-------|------|
| `preflight` | Detect OS, virtualization type, and cgroup version |
| `system` | apt upgrade, base packages, chrony time sync, timezone |
| `swap` | Virt-aware host swap (deliberately **no** container swap limits) |
| `hardening` | Non-root user, key-only SSH (lockout-guarded), UFW, fail2ban, auto-updates |
| `docker` | Docker Engine + compose plugin, **log rotation** (unbounded logs fill disks) |
| `app-fetch` | Registry login, clone the compose repo, scaffold `.env` (chmod 600) |
| `detect` | Infer the stack from manifests → print host implications (the teaching step) |
| `kernel-tuning` | Redis-only: `vm.overcommit_memory=1` + disable Transparent Huge Pages |
| `app-up` | `docker compose pull && up -d` as the deploy user (registry-pull, no on-box build) |
| `edge` | Edge-mode stacks only: sync the shared reverse proxy (re-render + reload) |
| `verify` | Poll the health URL; confirm auth returns 401 without a key |

## Why some things are on the host, not in the image

With Docker, your app's **runtime** deps live in the image. But a container
inherits a few kernel/OS settings from the host that it **cannot** change itself:

- **Redis** reads the host's `vm.overcommit_memory` and Transparent Huge Pages
  setting — wrong values cause fork/save failures and latency spikes.
- **Chromium** needs a larger `/dev/shm` and `ipc:host`; the 64 MB default crashes it.
- **Swap**, **time sync**, and **Docker log rotation** are host concerns full stop.

The `detect` phase prints exactly which of these apply to your stack and why.

## Sharing a box: the edge proxy

By default (`BOXSTRAP_TLS_PROVIDER=caddy`) each stack runs its **own** Caddy on
`:80/:443`, so only one TLS-fronted app fits per box. To run **several** apps on
one box behind a single front door, set `BOXSTRAP_TLS_PROVIDER=edge` on each and
boxstrap manages a shared **edge proxy**:

- One boxstrap-owned Caddy (a generated compose + aggregate Caddyfile under
  `/opt/boxstrap-edge`) terminates TLS and routes every edge stack's domain.
- The aggregate is re-rendered and hot-reloaded on every stack deploy / `update
  --refresh` / remove — no downtime, no hand-edited Caddyfile.
- Each app runs **no** Caddy. Its compose attaches the fronted service to the
  external `boxstrap-edge` network with a stable alias, and the stack sets
  `BOXSTRAP_TLS_UPSTREAM="<alias>:<port>"` so Caddy can reach it across projects.

```bash
sudo boxstrap edge      # manually re-render + reload the shared proxy
```

Mixing modes on one box isn't supported — the embedded-Caddy stack and the edge
proxy would both claim `:80/:443`. Pick `edge` for every fronted stack on a
shared box, or `caddy` for a single-app box.

## Config

A stack is a plain `KEY=value` file in `stacks/` — copy
[`stacks/stack.conf.example`](stacks/stack.conf.example) to `stacks/<your-app>.conf`
and adjust the values. Real `*.conf` files are gitignored (they describe your
infrastructure); only the `.example` template is tracked. Secrets are never stored
there — they are prompted or read from the environment and written only to the
app's `.env`.

## Development

```bash
shellcheck bootstrap.sh lib/*.sh   # lint
bats tests/                        # unit tests for the pure helpers
```

The system-mutating phases are validated with `--dry-run`, which prints every
action without touching the machine.
