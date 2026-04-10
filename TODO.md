# TODO

## CI: x86_64 curl Build

`rebuild-world.yml` curl job still failing. The Debian bootstrap uses gcc but linking against kominka's boringssl at `/kominka-root/usr/` — need to verify LDFLAGS pass `-L/kominka-root/usr/lib` correctly.

## Packaging

- openssh (remote access)
- ncurses + vim (text editing)
- zstd (compression)

## Infrastructure

- Replace R2 wrangler uploads with direct R2 API
- Bump cache key version in `build.yml` when R2 packages are updated (currently needs manual `v2` bump)

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- linux-headers could be rolled into the kernel package
