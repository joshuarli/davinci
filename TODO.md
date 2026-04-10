# TODO

## Packaging

- dropbear (SSH server/client) — PKGBUILD done, CI build pending for R2
- tailscale — PKGBUILD done, CI build pending for R2; first boot: `tailscale up` to join tailnet, then SSH via tailscale IP to dropbear
- zstd (compression)
- git: R2 binary not yet uploaded (links against boringssl, needs careful dep handling)

## Infrastructure

- Replace R2 wrangler uploads with direct R2 API (remove wrangler dep)
- Content-addressed binary cache (see REPOSITORY.md)
- Atomic installs: stage to a temp path, rename into place — prevents half-installed packages on crash

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- linux-headers could be rolled into the kernel package
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?
- DNS: /etc/resolv.conf is ephemeral (udhcpc overwrites) — consider persisting nameservers
  across reboots via a hook or static fallback
- Log rotation: syslogd rotates to /var/log/messages — no rotation configured; add logrotate
  or busybox syslogd `-s` size cap

