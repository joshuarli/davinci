# davinci — Kominka Linux

A self-hosting minimal Linux distribution built with the Kominka package manager (`pm.ysh`). Targets aarch64 and x86_64. No Debian, no host compiler in the final image — everything built from source with zig.

## Core Principle: Minimal Software

Always reach for the most minimal implementation. Every dependency is a liability — longer bootstrap, larger image, more attack surface.

- samurai (1 C file) instead of ninja
- zig (1 binary) instead of gcc + binutils + ld
- Custom nm.c (50 lines) — libtool compatibility
- busybox over GNU coreutils
- runit over systemd

## Repository Structure

```
Dockerfile                  # kominka:core (FROM busybox → FROM scratch, ~57MB)
Dockerfile.linux            # Kernel build (aarch64 + x86_64)
Dockerfile.iso              # Installer image (FROM kominka:core)
pm.ysh                      # Package manager (~2400 lines YSH)
install.sh                  # Interactive installer
kernel.config               # ARM64 kernel config fragment
kernel-x86_64.config        # x86_64 kernel config fragment
Makefile                    # Build orchestration
tests/
  test_pm_cheap.py          # 44 fast pm tests (no Docker)
  fixtures/repo/            # Package definitions
.github/workflows/
  build.yml                 # Build any package (amd64 + arm64, workflow_dispatch)
  bootstrap-glibc.yml       # Bootstrap glibc from Debian (one-off)
  rebuild-world.yml         # Rebuild broken x86_64 packages (one-off)
```

## Package Definitions

Every package lives in `tests/fixtures/repo/<name>/` with these files:

- `version` — `<ver> <rel>` (e.g. `1.2.3 1`)
- `sources` — URLs and local files, one per line. Supports VERSION/ARCH/GOARCH substitution.
- `checksums` — sha256 per source, or `checksums.aarch64` / `checksums.x86_64` for arch-specific
- `depends` — runtime deps (one per line). Append `make` for build-only deps.
- `build.ysh` — YSH build script. `$ARGV[0]` is the staging dest dir. Always use `build.ysh`; `build` (sh) was removed.
- `nostrip` — (optional) skip binary stripping

## Package Manager Quick Reference

```sh
pm i <pkg>          # install binary from R2 mirror
pm b <pkg>          # build from source (auto-resolves make+runtime deps)
pm r <pkg>          # remove
pm l                # list installed
pm c <pkg>          # generate checksums
pm d <pkg>          # download sources only
pm p <tarball>      # upload tarball to R2 (needs KOMINKA_ARCH, KOMINKA_BUCKET)
```

Key env vars: `KOMINKA_ROOT`, `KOMINKA_PATH`, `KOMINKA_BIN_MIRROR`, `KOMINKA_MIRROR`, `KOMINKA_COMPRESS=gz`, `KOMINKA_FORCE=1`, `KOMINKA_GET=/usr/bin/wget` (when curl is broken/missing).

## Build System

Zig is the system C/C++ compiler. All packages build with `zig cc` / `zig c++` / `zig ld.lld`. ysh is statically linked against musl.

**Important**: Always use `build.ysh`, never `build` (sh). pm prefers `build.ysh` — if both exist, `build` is silently ignored.

## Architectures

Both aarch64 and x86_64 are supported. Binary packages live on R2 at:
```
https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev/<arch>/<pkg>/<ver>-<rel>.tar.gz
```
where `<arch>` is `aarch64-linux-gnu` or `x86_64-linux-gnu`.

## CI/CD

- `build.yml` — `workflow_dispatch` with `package` input. Builds for both arches using native GitHub ARM/AMD runners. Caches `kominka:core` Docker image.
- `bootstrap-glibc.yml` — one-off Debian-based workflow to build glibc from source.
- `rebuild-world.yml` — one-off workflow to rebuild x86_64 packages that had hardcoded `/kominka-root/` paths from the old bootstrap environment.

## Common Pitfalls

- **PATH ordering**: In hybrid builds (Kominka + host), Kominka binaries MUST come AFTER host binaries. Dynamically-linked Kominka binaries spin at 100% CPU if the host linker can't find their libs.
- **lld version scripts**: lld is stricter than GNU ld — errors on undefined symbols in version scripts. Fix: use wildcard patterns (`pam_sm_*`) in the version script.
- **zig cc target**: When building on Ampere Altra (GitHub ARM runners), default zig cc may emit instructions not supported on Apple Silicon. Pass `-mcpu=generic` for portable builds.
- **KOMINKA_ROOT=/ caveat**: Installing packages to `/` on a Debian host clobbers system headers. Use `/kominka-root` and pass `-I/-L` flags explicitly.
- **build.ysh vs build**: pm uses `build.ysh` exclusively. Never create `build` (sh) files.
- **Local testing on Apple Silicon**: The rebuilt aarch64 packages on R2 were built on Ampere Altra and may crash with "Illegal instruction". Use `KOMINKA_GET=/usr/bin/wget` (curl crashes) and `pm b samurai` from source before using it.
