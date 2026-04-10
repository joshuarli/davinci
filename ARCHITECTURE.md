# Kominka Linux Architecture

## Overview

Kominka is a minimal, self-hosting Linux distribution. Supports aarch64 and x86_64. Custom kernel, busybox userspace, glibc, zig as the system compiler. Builds inside Docker on macOS — no cross-compilation.

**Always reach for the most minimal software.** Fewer deps = shorter bootstrap, smaller images, less attack surface.

## Images

| Image | Size | Contents |
|-------|------|----------|
| `kominka:core` | ~57MB | 11 packages — minimal bootable system |
| `kominka-installer.img` | ~161MB | Bootable installer (MBR: EFI + ext4) |

FROM scratch. Only external dependency: `busybox:latest` (4MB static musl) for the initial wget+tar bootstrap.

## Compiler Toolchain

Zig replaces gcc + binutils + ld — one binary, zero bootstrap chain:

| Wrapper | Implementation |
|---------|---------------|
| `cc`, `c++` | `zig cc` / `zig c++` |
| `ld` | `zig ld.lld` (real lld, not a flag translator) |
| `ar`, `ranlib` | `zig ar` / `zig ranlib` |
| `nm` | Custom 50-line C ELF parser |
| `strip` | Custom 70-line C ELF section stripper |
| `objcopy` | `zig objcopy` |

ysh is statically linked against musl (`zig c++ -target aarch64-linux-musl`). Everything else dynamically links against glibc.

## Core Packages (`core` metapackage)

| Package | Role |
|---------|------|
| baselayout | FHS dirs, /etc configs, /bin→/usr/bin symlinks |
| glibc | C library (with libcrypt, compat symlinks) |
| busybox | init, sh, getty, mdev, udhcpc, ~300 applets |
| baseinit | rc.boot, rc.shutdown, rc.lib |
| runit | Service supervision (runsvdir/runsv/sv) |
| boringssl | TLS library |
| curl | HTTP client + libcurl.so |
| ca-certificates | Root CAs |
| opendoas | Privilege escalation (being replaced by sudo-rs) |
| ysh | Shell (static musl binary, runs pm) |

## Build Pipeline

```
Dockerfile (FROM busybox:latest → FROM scratch)
  └── kominka:core   ← pm i core

Dockerfile.linux (FROM debian, kernel source)
  └── Image (ARM64) or bzImage (x86_64)

Dockerfile.iso (FROM kominka:core)
  └── pm i liveiso + kernel + install.sh
  └── build_iso.sh → kominka-installer.img
```

## Bootstrap

```
busybox:latest
  └── busybox wget → ysh (static musl, runs on any Linux)
  └── ysh pm.ysh i core → downloads 11 packages from R2
FROM scratch (copy /kominka-root → /)
```

## Boot Flow

```
Kernel (EFISTUB) → busybox init → /etc/inittab
  ├── sysinit:  rc.boot (mount, fsck, mdev, network)
  ├── respawn:  runsvdir (mdev, syslogd, getty, udhcpc, ntpd)
  └── shutdown: rc.shutdown
```

## Package Manager

`pm.ysh` — ~2400 line YSH script. Key behaviors:

- `pm i pkg` — install binary from R2, auto-resolve runtime deps
- `pm b pkg` — build from source, resolve build+runtime deps
- Make deps (tagged with `make` in depends) skipped during `pm i`, also skipped during `pm b` when parent is already installed
- Parallel downloads with live progress
- `MAKEFLAGS=-j<nproc>` for all builds
- `KOMINKA_GET=/usr/bin/wget` — use busybox wget instead of curl

## R2 Binary Mirror

Packages stored at `{arch}/{pkg}/{ver}-{rel}.tar.gz`:
- `aarch64-linux-gnu/curl/7.80.0-5.tar.gz`
- `x86_64-linux-gnu/boringssl/0.20260327.0-6.tar.gz`

Upload: `KOMINKA_ARCH=aarch64-linux-gnu KOMINKA_BUCKET=kominka-sources pm p <tarball>`

## Self-Hosting

Packages are built in `kominka:core` (not Debian). All build tools (zig, make, samurai, cmake, muon) are installed from R2 binaries. Compiled-in paths are correct because the build environment IS the target (`KOMINKA_ROOT=/` effectively).

## Filesystem

```
/bin → /usr/bin          Merged-usr layout
/lib → /usr/lib
/sbin → /usr/bin
/usr/bin/busybox         + ~300 symlinks
/usr/bin/pm              Package manager
/usr/local/bin/ysh       Static musl binary
/var/db/kominka/         Package database
```

## Service Management

runit via `runsvdir -P /var/service`:
```sh
ln -s /etc/sv/sshd /var/service/sshd   # enable
rm /var/service/sshd                     # disable
sv status /var/service/*                 # status
```
