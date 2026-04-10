# TODO

## Packaging

- tmux: replace `SKIP` checksum with real sha256 after first successful download
- openssh (remote access)
- ncurses + vim (text editing)
- zstd (compression)
- git: R2 binary not yet uploaded (links against boringssl, needs careful dep handling)

## Infrastructure

- Replace R2 wrangler uploads with direct R2 API (remove wrangler dep)
- Content-addressed binary cache (see REPOSITORY.md)
- Upload remaining build-essential deps to R2: cmake, m4, make, bison, pkgconf

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- linux-headers could be rolled into the kernel package
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?

## pm.ysh

- `_nproc` discovery: currently `nproc` — falls back gracefully but could be smarter
- `pkg_find_and_load` convenience proc to replace the `pkg_find` + `pkg_load` pair
  that appears everywhere
