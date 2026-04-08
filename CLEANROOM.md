# Cleanroom Build Strategy

Goal: build every Kominka package using only Kominka packages.
Zero Debian. The only external dependency is Docker Hub's
`busybox:latest` (4MB static musl binary) for the initial
`wget | tar` bootstrap.

## Current state (2026-04-08)

### Phases 1–3: COMPLETE

All Docker images bootstrap from `busybox:latest`. No Debian.

| Image | Size | Packages | Description |
|-------|------|----------|-------------|
| `kominka:core` | 57MB | 9 | Minimal runtime (Dockerfile.base) |
| `kominka:build` | 1.2GB | 22 | Full toolchain, self-hosting (tests/Dockerfile.selfhost) |

`kominka:build` can build packages from source (`pm b zlib`,
`pm b boringssl`) using only its own tools.

### On R2 (aarch64 binaries, 24 packages)

Core (9):
- glibc, baselayout, busybox (with gzip/bzip2/xz/wget applets)
- baseinit, runit, boringssl, curl, opendoas
- ysh (static musl binary, no libstdc++ dep)

Toolchain (11):
- zig 0.15.2 (cc, c++, ld.lld, ar, ranlib, nm, objcopy, strip)
- make, samurai (ninja), cmake, go
- zlib, linux-headers, bzip2, xz, pkgconf, git

Other (4):
- bison, m4, dosfstools, e2fsprogs

### Known issues

- **flex**: stage1flex crashes with SIGPIPE when built with zig cc.
  Needs investigation. Not blocking any cleanroom build.
- **strip**: zig objcopy can't `--strip-all` shared libs or static
  musl binaries. Wrapper backs up and restores on failure. Binaries
  are larger than necessary.
- **busybox SKIP_STRIP**: busybox Makefile calls GNU strip with flags
  zig objcopy doesn't support. Pass `SKIP_STRIP=y` to make.
- **CA certificates**: not packaged yet. `KOMINKA_INSECURE=1` used
  for downloads in the selfhost chroot (curl -k).
- **ysh build**: oils passes `-std=c++11` to CC on `.c` files. Build
  script replaces system `cc`/`c++` with wrappers that force `-xc++`
  during compilation.
- ~~gcc, binutils~~ — deleted, zig replaces both

## Bootstrap sequence

### Dockerfile.base (kominka:core)

```
FROM busybox:latest                          # 4MB static musl
  └── wget --no-check-certificate | tar      # pull 9 packages from R2
        baselayout → glibc → busybox → baseinit → runit
        → boringssl → curl → opendoas → ysh
  └── COPY pm.ysh
FROM scratch
  └── COPY --from=bootstrap /kominka-root /
```

### Dockerfile.selfhost (kominka:build)

```
FROM busybox:latest
  └── wget | tar                             # pull 9 core packages
  └── chroot into kominka-root
        └── ysh pm i zig make zlib samurai cmake go
                     bzip2 xz pkgconf git m4 bison linux-headers
FROM scratch
  └── COPY --from=bootstrap /kominka-root /
```

Package order matters: **baselayout first** (creates /bin, /lib, /sbin
symlinks to /usr/bin, /usr/lib). Without these, chroot can't find
/bin/sh or the dynamic linker.

## Phases

### Phase 1: Build BoringSSL from source (DONE)

`tests/Dockerfile.toolchain` validates that BoringSSL builds using
only Kominka toolchain packages (zig, cmake, samurai, go, make).

### Phase 2: Build all packages from source (DONE)

bzip2, xz, pkgconf, git, boringssl all build from source with zero
host build tools. flex skipped (SIGPIPE issue).

### Phase 3: Self-hosting FROM scratch (DONE)

`kominka:build` (FROM scratch) can run `pm b` to build packages from
source. Tested: zlib, boringssl. Zero Debian in the final image.

Key changes made:
- ysh statically linked against musl (zig c++ -target aarch64-linux-musl)
- busybox: enabled wget, gzip, gunzip, bzip2, xz, lzma applets
- pm: wget fallback, KOMINKA_INSECURE for cert-less environments
- zig: strip wrapper with backup/restore, nm (50-line C ELF parser)

### Phase 4: Boot from own foundation (DONE)

`Dockerfile.iso` produces a bootable installer disk image using
only Kominka packages. `kominka:core` + `pm i liveiso` + kernel.
`build_iso.sh` uses busybox fdisk/losetup/mount/cpio + Kominka's
mkfs.ext4/mkfs.vfat. No Debian.

Pipeline: `make iso` → 161MB installer image.

Infrastructure consolidated to 3 Dockerfiles:
- `Dockerfile` — multi-target: `kominka:core` (57MB) + `kominka:build` (941MB)
- `Dockerfile.linux` — kernel build
- `Dockerfile.iso` — installer image (FROM kominka:core)

## Gaps and workarounds

### PATH ordering in hybrid builds (Dockerfile.toolchain)

When building on a Debian host with Kominka tools, Kominka binaries
MUST come AFTER Debian on PATH. Kominka's dynamically-linked binaries
(curl, git) **spin at 100% CPU** if they can't find their shared libs
via the host linker. Set CC/CXX explicitly instead:

```dockerfile
ENV PATH=$PATH:/kominka-root/usr/bin
    CC=/kominka-root/usr/bin/cc
```

This does NOT apply to FROM scratch images where everything is Kominka.

### BoringSSL source

GitHub release tarball instead of git. Googlesource rejects partial
clones (`--filter=blob:none`). The tarball is faster and reproducible.

### Shared library creation

`ld` wrapper exposes `zig ld.lld` directly. Libtool calls ld with
flags like `-shared`, `-soname` — lld handles these natively. The old
`zig cc -Wl,...` wrapper silently failed to create shared libraries.

### nm for libtool

50-line C ELF symbol parser (`zig/files/nm.c`) compiled with zig
during the zig package build. Libtool needs nm to extract export
symbols when creating shared libraries.

### Headers in packages

`pkg_clean_dev` preserves `/usr/include` and `/usr/lib/pkgconfig`.
Will move to `-dev` package splits later.

### MAKEFLAGS

pm sets `MAKEFLAGS=-j<nproc>` automatically for all builds.

## What "cleanroom" means

| Category | Provider |
|----------|----------|
| Bootstrap | busybox:latest (Docker Hub, 4MB static musl) |
| C/C++ compiler | zig cc / zig c++ (Kominka) |
| Linker | zig ld.lld (Kominka) |
| ar, nm, ranlib, strip | zig wrappers (Kominka) |
| Build tools | make, cmake, samurai (Kominka) |
| Languages | go (Kominka) |
| Shell / pm runtime | ysh (static musl), busybox (Kominka) |
| TLS / HTTP | boringssl, curl (Kominka) |
| VCS | git (Kominka) |
| Host deps | Docker only |
