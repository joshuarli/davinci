# TODO

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync on real hardware
- DNS: /etc/resolv.conf is ephemeral (udhcpc overwrites) — consider persisting
  nameservers across reboots via a hook or static fallback
- Log rotation: syslogd rotates to /var/log/messages — no rotation configured;
  add logrotate or busybox syslogd `-s` size cap
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?

---

- Deploy repository server publicly (VPS/fly.io) so build-package.yml
  can upload directly from CI instead of saving artifacts for manual upload.
  Once done: remove the `|| true` from pm p in build-package.yml and drop
  the artifact-save workaround.

- x86_64 kernel + ISO: make kernel-amd64 and make iso-amd64 never run.
  x86_64 packages are all in the server but the system can't boot yet.

- Self-hosting unverified: boot Kominka and confirm pm i + pm b work
  from within the running system.

- Package signing (v2): per REPOSITORY.md design.

