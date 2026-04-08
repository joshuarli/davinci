# davinci

A self-hosting Linux distribution built with the Kominka package manager
(`pm.ysh`). Builds itself from source using only its own packages — no
external toolchain, no Debian, no host compiler.

## Core Principle: Minimal Software

Always reach for the most minimal implementation. Every dependency is a
liability — a longer bootstrap chain, a larger image, more attack surface.
Before adding a dependency, ask: can we solve this with 50 lines of C?

- samurai (1 C file) instead of ninja (needs python)
- zig (1 binary) instead of gcc + binutils + ld (3 complex packages)
- Custom nm.c (50 lines) instead of binutils (massive dep chain)
- opendoas (700 LOC) instead of sudo (200k LOC)
- busybox over GNU coreutils (1 binary, ~300 applets)
- runit over systemd (PID 1 is ~600 lines of C)

## Repository Structure

```
Dockerfile                  # Multi-target: kominka:core + kominka:build
Dockerfile.linux            # Kernel build (tinyconfig + kernel.config)
Dockerfile.iso              # Installer disk image (FROM kominka:core)
pm.ysh                      # Package manager (YSH, ~2200 lines)
build_iso.sh                # Installer image assembly (busybox tools only)
install.sh                  # Interactive installer (busybox fdisk, MBR)
kernel.config               # Kernel config fragment
Makefile                    # Build orchestration (core, build, kernel, iso)
YSH.md                      # YSH language reference
tests/
  test_pm_cheap.py          # 41 fast pm tests (no Docker, no builds)
  test_docker.py            # 6 Docker integration tests
  fixtures/repo/            # 30 package definitions
```

## Make Targets

```sh
make core       # kominka:core — 57MB base image (9 packages)
make kernel     # ARM64 kernel Image
make iso        # 161MB bootable installer disk image
make test       # Run all tests
make boot       # Boot installer in vfkit VM
```

## Packages (24 on R2)

**core** (metapackage → 9 runtime deps):
baselayout, glibc, busybox, baseinit, runit, boringssl, curl, opendoas, ysh

**build-essential** (metapackage → 13 runtime deps):
core + zig, make, samurai, cmake, zlib, linux-headers, bzip2, xz,
pkgconf, git, m4, bison

**liveiso** (metapackage): core + e2fsprogs, dosfstools

All packages compiled with `zig cc`. ysh is statically linked against musl
(zero runtime deps). All other binaries dynamically link against glibc.

## How pm Works

YSH port of KISS package manager (v5.5.28). Key features:
- `pm i <pkg>` — install from R2 binary, auto-resolves runtime deps
- `pm b <pkg>` — build from source, auto-resolves build+runtime deps
- `pm i <metapackage>` — installs all deps, registers metapackage
- Parallel downloads with progress display
- `MAKEFLAGS=-j<nproc>` set automatically for all builds
- wget fallback when curl unavailable (`KOMINKA_INSECURE=1` for no-cert envs)
- Build-only deps tagged with `make` suffix in depends files

## Bootstrap

```
FROM busybox:latest (4MB static musl)
  └── wget ysh from R2 (static musl binary, runs anywhere)
  └── pm i core → downloads 9 packages from R2
FROM scratch
```

No Debian anywhere. Only external dep: Docker Hub's busybox:latest for
the initial wget+tar.

## Known Issues

- **flex**: stage1flex crashes with SIGPIPE when built with zig cc
- **strip**: zig objcopy can't --strip-all shared libs; wrapper backs up
  and restores on failure
- **CA certificates**: not packaged; KOMINKA_INSECURE=1 used in builds
- **PATH ordering**: Kominka binaries MUST come AFTER host binaries on
  PATH in hybrid builds, or dynamically-linked binaries spin at 100% CPU
- **ysh build**: oils passes -std=c++11 to CC on .c files; build script
  replaces system cc/c++ with musl-targeting wrappers

## Build Fixes (zig cc compatibility)

- busybox: CONFIG_TC disabled, clang UB patch, lld flags stripped,
  SKIP_STRIP=y (zig objcopy limitation)
- runit: -D_GNU_SOURCE, -Wno-implicit-function-declaration
- m4/make: gnulib K&R prototypes patched
- boringssl: GitHub release tarball (Googlesource rejects partial clones)
- zlib: fossils mirror, -O2 required (zig UBSan at -O0)
- curl: ld must be zig ld.lld (not wrapper) for libtool shared lib creation
