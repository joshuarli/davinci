# Kominka Linux Architecture

## Overview

Kominka is a minimal, self-hosting Linux distribution. Supports aarch64 and x86_64. Custom kernel, busybox userspace, glibc, zig as the system compiler. Builds inside Docker on macOS — no cross-compilation.

**Always reach for the most minimal software.** Fewer deps = shorter bootstrap, smaller images, less attack surface.

## Images

| Image | Size | Contents |
|-------|------|----------|
| `kominka:core` | ~57MB | Core packages — minimal bootable system |
| `kominka-installer.img` | ~161MB | Bootable installer (MBR: EFI + ext4) |

FROM scratch. Only external dependency: `busybox:latest` (4MB static musl) for the initial wget+tar bootstrap.

## Compiler Toolchain

Zig replaces gcc + binutils + ld — one binary, zero bootstrap chain:

| Wrapper | Implementation |
|---------|---------------|
| `cc`, `c++` | `zig cc` / `zig c++` |
| `ld` | `zig ld.lld` |
| `ar`, `ranlib` | `zig ar` / `zig ranlib` |
| `nm` | Custom 50-line C ELF parser |
| `strip` | Custom 70-line C ELF stripper |
| `objcopy` | `zig objcopy` |

ysh is statically linked against musl. Everything else dynamically links against glibc.

## Core Packages

| Package | Role |
|---------|------|
| baselayout | FHS dirs, /etc configs, /bin→/usr/bin symlinks |
| glibc | C library |
| busybox | init, sh, getty, mdev, udhcpc, ~300 applets |
| baseinit | rc.boot, rc.shutdown, rc.lib |
| runit | Service supervision (runsvdir/runsv/sv) |
| boringssl | TLS library (libssl.so, libcrypto.so) |
| curl | HTTP client + libcurl.so |
| ca-certificates | Root CAs |
| ysh | Shell (static musl binary, runs pm) |

`sudo-rs` is installed in the ISO layer (not core) with `NOPASSWD` for the `wheel` group. Authentication uses busybox `su` (no PAM) with an empty root password.

## Build Pipeline

```
Dockerfile (FROM busybox:latest → FROM scratch)
  └── kominka:core   ← pm i core

Dockerfile.linux (FROM debian, kernel source)
  └── Image (ARM64) or bzImage (x86_64)

Dockerfile.iso (FROM kominka:core)
  └── pm i sudo-rs build-essential
  └── kernel + install.sh
  └── build_iso.sh → kominka-installer.img
```

## Bootstrap

```
busybox:latest
  └── busybox wget → ysh (static musl, runs on any Linux)
  └── ysh pm.ysh i core → downloads packages from R2
FROM scratch (copy /kominka-root → /)
```

## Boot Flow

```
Kernel (EFISTUB) → busybox init → /etc/inittab
  ├── sysinit:  rc.boot (mount, fsck, mdev, network)
  ├── respawn:  runsvdir (mdev, syslogd, getty-hvc0, udhcpc, ntpd)
  └── shutdown: rc.shutdown

getty-hvc0 → autologin script (root) → su -l josh
```

virtiofs mounts the host `tests/fixtures/repo` as `/packages` at autologin, so package definitions are live without rebuilding the image.

## Package Manager

`pm.ysh` — ~2300 line YSH script. Key behaviors:

- `pm i pkg` — install binary from R2, auto-resolve runtime deps
- `pm b pkg` — build from source, resolve build+runtime deps
- Make deps skipped during `pm i`; also skipped during `pm b` when parent is already installed
- Each package operation receives the loaded package record as an explicit typed parameter (`p Dict`) — no shared mutable globals for package state
- Parallel downloads with live progress

## R2 Binary Mirror

Packages stored at `{arch}/{pkg}/{ver}-{rel}.tar.gz`:
```
aarch64-linux-gnu/curl/7.80.0-5.tar.gz
x86_64-linux-gnu/boringssl/0.20260327.0-6.tar.gz
```

Upload via wrangler:
```sh
wrangler r2 object put "kominka-sources/{arch}/{pkg}/{ver}-{rel}.tar.gz" \
    --file=<tarball> --content-type=application/octet-stream --remote
```

## ARM64 Compatibility

R2 binaries must target `armv8-a+lse+crypto` (not the native host CPU) to work in Apple Virtualization.framework guests, which don't expose SVE, PAC, or BTI. The `rebuild-world.yml` CI workflow rebuilds affected packages using Ubuntu GCC with explicit `-march=armv8-a+lse+crypto`. zig cc targets a conservative baseline by default.

## Self-Hosting

Packages are built in `kominka:core`. All build tools (zig, samurai, cmake, etc.) are installed from R2 via `pm i build-essential`. Compiled-in paths are correct because the build environment IS the target (`KOMINKA_ROOT=/` effectively).

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
