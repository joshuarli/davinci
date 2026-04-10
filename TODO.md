# TODO

## Current Work: sudo-rs

Replacing opendoas with sudo-rs (memory-safe Rust implementation). Status:

### Done
- `cargo` package: prebuilt Rust toolchain from rust-lang.org, bundled `libgcc_s.so.1` from Debian bookworm
- `muon` package: C meson implementation (no Python dep), bootstraps from single `src/amalgam.c`
- `linux-pam 1.7.0` package: authentication library, built with muon+samurai
- `sudo-rs 0.2.13` package: build script ready
- glibc rebuilt with `--enable-crypt` (provides `libcrypt.so`) + compat symlinks (libdl.so, libpthread.so, librt.so)
- All `build` (sh) scripts removed — only `build.ysh` exists now

### Blocked: linux-pam link errors
lld is stricter than GNU ld on version scripts. PAM's `modules.map` lists all 6 `pam_sm_*` symbols as required exports, but individual modules only implement a subset.

**Fix in progress**: patch `modules.map` to use `pam_sm_*` wildcard (lld supports wildcards). The patched file is at `tests/fixtures/repo/linux-pam/files/modules.map` and is copied over the source file before `muon setup`.

Also: zig's bundled `/lib64/libcrypt.so` is being picked up instead of our `/usr/lib/libcrypt.so`. Need to investigate linker search path ordering.

### Next
1. Fix linux-pam build → package it
2. Build sudo-rs on top of linux-pam
3. Add sudo-rs to `core` metapackage, remove opendoas

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
