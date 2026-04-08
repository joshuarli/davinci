# Kominka Linux Architecture

## Overview

Kominka is a minimal, self-hosting Linux distribution. ARM64 (aarch64),
custom kernel, busybox userspace, glibc, zig as the system compiler.
The entire OS builds inside Docker on macOS — no cross-compilation.

**Always reach for the most minimal software.** Fewer deps = shorter
bootstrap, smaller images, less attack surface.

## Images

| Image | Size | Contents |
|-------|------|----------|
| `kominka:core` | 57MB | 9 packages — minimal bootable system |
| `kominka-installer.img` | 161MB | Bootable installer (MBR: EFI + ext4) |

FROM scratch. Only external dependency: `busybox:latest` (4MB static
musl) for the initial wget+tar bootstrap. Install additional packages
on top of core with `pm i build-essential`, `pm i liveiso`, etc.

## Compiler Toolchain

Zig replaces gcc + binutils + ld — one binary, zero bootstrap chain:

| Wrapper | Implementation |
|---------|---------------|
| `cc`, `c++` | `zig cc` / `zig c++` |
| `ld` | `zig ld.lld` (real lld, not a flag translator) |
| `ar`, `ranlib` | `zig ar` / `zig ranlib` |
| `nm` | Custom 50-line C ELF parser (libtool needs it) |
| `strip` | `zig objcopy --strip-debug` with fallback |
| `objcopy` | `zig objcopy` |

ysh is statically linked against musl (`zig c++ -target aarch64-linux-musl`).
Everything else dynamically links against glibc.

## Core Packages

| Package | Role |
|---------|------|
| baselayout | FHS dirs, /etc configs, /bin→/usr/bin symlinks |
| glibc | C library |
| busybox | init, sh, getty, mdev, udhcpc, coreutils (~300 applets) |
| baseinit | rc.boot, rc.shutdown, rc.lib |
| runit | Service supervision (runsvdir/runsv/sv) |
| boringssl | TLS library (shared, from GitHub release tarball) |
| curl | HTTP client + libcurl.so |
| opendoas | Privilege escalation |
| ysh | Shell (static musl binary, runs pm) |

## Build Pipeline

```
Dockerfile (FROM busybox:latest → FROM scratch)
  └── kominka:core   ← pm i core

Dockerfile.linux (FROM debian, kernel source)
  └── Image (ARM64 kernel, EFISTUB)

Dockerfile.iso (FROM kominka:core)
  └── pm i liveiso + kernel + install.sh
  └── build_iso.sh → kominka-installer.img
```

## Boot Flow

```
Kernel (EFISTUB) → busybox init → /etc/inittab
  ├── sysinit:  rc.boot (mount, fsck, mdev, network)
  ├── respawn:  runsvdir (mdev, syslogd, getty, udhcpc, ntpd)
  └── shutdown: rc.shutdown (save state, kill, umount, kpow)
```

## Installer

`install.sh` — interactive, runs on the live image:
1. Lists block devices from /sys/block
2. Partitions with busybox fdisk (MBR: 256M EFI + 8G swap + ext4 root)
3. Formats with mkfs.vfat (dosfstools) + mkfs.ext4 (e2fsprogs)
4. Copies live rootfs to target
5. Installs kernel as BOOTAA64.EFI
6. Creates user account with busybox passwd

## Package Manager

`pm.ysh` — 2200-line YSH script. Key behaviors:

- `pm i pkg` — install binary from R2, auto-resolve runtime deps
- `pm b pkg` — build from source, resolve build+runtime deps
- `pm i metapkg` — install all deps, register metapackage (no tarball)
- Build deps tagged `make` in depends files, skipped during `pm i`
- Parallel download with live progress (`pkg1 45MB | pkg2 12MB`)
- `MAKEFLAGS=-j<nproc>` for all builds
- wget fallback when curl unavailable

## Self-Hosting Bootstrap

The bootstrap has one external dependency: `busybox:latest` from Docker
Hub (4MB static musl). It provides `wget` and `tar` to download the
first package (ysh). After ysh is installed, pm handles everything else.

```
busybox:latest → wget ysh (static musl) → pm i core → FROM scratch
```

**Package order matters**: baselayout must extract first (creates /bin,
/lib, /sbin symlinks). Without these, the dynamic linker can't be found.

**PATH in hybrid builds**: when building on a non-Kominka host (e.g.
Debian), Kominka binaries MUST come AFTER host binaries on PATH.
Kominka's dynamically-linked binaries (curl, git) will spin at 100% CPU
if the host linker can't find their shared libs. Set CC/CXX explicitly.

**ld must be real lld**: `zig ld.lld`, not a wrapper. Libtool calls ld
directly with `-shared`, `-soname` flags. A `zig cc -Wl,...` wrapper
silently fails to create shared libraries.

## Filesystem

```
/bin → /usr/bin          Merged-usr layout (baselayout)
/lib → /usr/lib
/sbin → /usr/bin
/usr/bin/busybox         Core binary + ~300 symlinks
/usr/bin/pm              Package manager
/usr/local/bin/ysh       Static musl binary
/var/db/kominka/         Package database
```

## Service Management

runit via `runsvdir -P /var/service`. Symlink to enable:
```sh
ln -s /etc/sv/sshd /var/service/sshd   # enable
rm /var/service/sshd                     # disable
sv status /var/service/*                 # status
```
