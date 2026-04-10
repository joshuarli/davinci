# TODO

## Packaging

- tmux: replace `SKIP` checksum with real sha256 after first successful download
- dropbear (SSH server/client) ← next
- ncurses + vim (text editing)
- zstd (compression)
- git: R2 binary not yet uploaded (links against boringssl, needs careful dep handling)

## Infrastructure

- Replace R2 wrangler uploads with direct R2 API (remove wrangler dep)
- Content-addressed binary cache (see REPOSITORY.md)
- Upload remaining build-essential deps to R2: cmake, m4, make, bison, pkgconf
- Atomic installs: stage to a temp path, rename into place — prevents half-installed packages on crash

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- linux-headers could be rolled into the kernel package
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?
- DNS: /etc/resolv.conf is ephemeral (udhcpc overwrites) — consider persisting nameservers
  across reboots via a hook or static fallback
- Kernel hardening: enable CONFIG_SECURITY, CONFIG_STRICT_KERNEL_RWX, CONFIG_RANDOMIZE_BASE
  (KASLR), CONFIG_STACKPROTECTOR_STRONG for the production kernel config
- Log rotation: syslogd rotates to /var/log/messages — no rotation configured; add logrotate
  or busybox syslogd `-s` size cap

## pm.ysh

- `_nproc` discovery: currently `nproc` — falls back gracefully but could be smarter
- `pkg_find_and_load` convenience proc to replace the `pkg_find` + `pkg_load` pair
  that appears everywhere
- `pm info <pkg>`: show name, version, description, deps, install status — currently no
  human-readable package summary command
- Package age / security updates: no mechanism to know if an installed package is outdated
  relative to upstream; could track upstream version separately or integrate a check command
