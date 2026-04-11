# TODO

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- linux-headers could be rolled into the kernel package
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?
- DNS: /etc/resolv.conf is ephemeral (udhcpc overwrites) — consider persisting nameservers
  across reboots via a hook or static fallback
- Log rotation: syslogd rotates to /var/log/messages — no rotation configured; add logrotate
  or busybox syslogd `-s` size cap

