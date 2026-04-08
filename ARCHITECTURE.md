# Kominka Linux Architecture

## Overview

Kominka Linux is a minimal Linux distribution built with a YSH package manager
(`pm.ysh`). The system boots on ARM64 (aarch64) using a custom minimal kernel,
busybox for core userspace, glibc as the C library, and `zig cc` as the
system C/C++ compiler.

The entire OS is built inside Docker containers on macOS, producing a bootable
disk image that runs under vfkit (or on real ARM64 hardware via EFISTUB).

## Design Principles

**Always reach for the most minimal software.** When choosing between
implementations, prefer the smallest, simplest one that does the job:

- **samurai** over ninja (single C file, no python dependency)
- **zig** over gcc+binutils+ld (one binary replaces an entire toolchain)
- **busybox** over GNU coreutils (one binary, ~300 applets)
- **opendoas** over sudo (700 lines vs 200,000+)
- **runit** over systemd (PID 1 is ~600 lines of C)
- **Custom nm.c** over binutils (50 lines vs a full binutils build chain)

This isn't minimalism for its own sake — fewer dependencies mean a shorter
path to self-hosting, faster builds, smaller images, and less attack surface.
Every external dependency is a liability. Before adding one, ask: can we
write 50 lines of C instead? See `CLEANROOM.md` for the self-hosting strategy.

## Base System

### Compiler Toolchain

Kominka uses **Zig** as its C/C++ compiler toolchain. The `zig` package
provides the entire compilation toolchain in a single binary:

- `cc` / `c++` — C/C++ compiler (zig cc, clang-based)
- `ld` — linker (lld, reports as GNU ld for autotools compatibility)
- `ar` / `ranlib` — archiver
- `nm` — symbol lister (custom minimal ELF parser, ~50 lines of C)
- `objcopy` — object copy/transform

This replaces gcc + binutils + ld — three complex packages with deep
dependency chains — with one self-contained binary plus thin wrappers.
All packages are dynamically linked against glibc (no static linking —
zig's lld doesn't support static glibc).

### Core Packages

The `core` metapackage depends on the minimal boot/network/pm packages:

| Package | Role |
|---------|------|
| baselayout | FHS directory structure, `/etc` config files, symlinks (`/bin -> /usr/bin`, `/lib -> /usr/lib`) |
| glibc | C library (host-provided during bootstrap, package exists for self-hosting) |
| busybox | Core userspace: init, sh, getty, mount, fsck, mdev, udhcpc, coreutils, and ~300 other applets |
| baseinit | Init framework: rc.boot, rc.shutdown, rc.lib, kpow, kall |
| runit | Service supervision: runsvdir, runsv, sv |
| boringssl | TLS library (shared, used by curl and git) |
| curl | HTTP client and library |
| opendoas | Privilege escalation (sudo alternative) |
| ysh | Shell and scripting language (runs pm) |

The `build-essential` metapackage adds compiler/build tools:

| Package | Role |
|---------|------|
| zig | C/C++ compiler (zig cc), linker (lld), and `cc`/`c++` wrappers |
| linux-headers | Kernel headers for building C programs |
| zlib | Compression library (dependency of curl) |
| bzip2, xz | Source tarball decompression |
| m4 | Macro processor (dependency of bison) |
| make | Build system |
| bison, flex | Parser generators |

## Filesystem Layout

```
/                           ext4 root (GPT partition 3)
/boot                       EFI system partition (GPT partition 1, FAT32)
/boot/EFI/BOOT/BOOTAA64.EFI  Kernel image (EFISTUB for real hardware)
/bin -> /usr/bin             All binaries in one flat directory
/sbin -> /usr/bin
/lib -> /usr/lib             All libraries in one flat directory
/lib64 -> /usr/lib
/usr/bin/busybox             Core binary, ~300 symlinks point here
/usr/bin/oils-for-unix       YSH/OSH runtime
/usr/bin/ysh -> oils-for-unix
/usr/bin/sh -> oils-for-unix
/usr/bin/pm                  Package manager (ysh script)
/usr/lib/init/               baseinit scripts (rc.boot, rc.shutdown, rc.lib)
/usr/lib/ld-linux-aarch64.so.1  glibc dynamic linker
/packages/                   Package definitions (repo)
/root/.cache/kominka/bin/    Pre-built package tarballs
/var/db/kominka/installed/   Package database
/var/db/kominka/choices/     File alternative tracking
```

## Boot Flow

```
Kernel
  |
  v
/sbin/init (busybox init)
  |
  |-- reads /etc/inittab
  |
  |-- ::sysinit: /lib/init/rc.boot
  |     |
  |     |-- sources /usr/lib/init/rc.lib (logging, mount helpers, sos shell)
  |     |-- "Welcome to Kominka!"
  |     |-- Mount pseudo filesystems (proc, sys, dev, run, devpts, shm)
  |     |-- Create /dev/fd, /dev/stdin, /dev/stdout, /dev/stderr symlinks
  |     |-- Load /etc/rc.conf
  |     |-- Start device manager (mdev from busybox)
  |     |-- Remount / read-only
  |     |-- fsck
  |     |-- Remount / read-write
  |     |-- mount -a (from /etc/fstab)
  |     |-- swapon -a
  |     |-- Load random seed
  |     |-- Set up loopback (ip link set up dev lo)
  |     |-- Set hostname from /etc/hostname
  |     |-- Load sysctl settings
  |     |-- Run /etc/rc.d/*.boot hooks
  |     `-- Log boot time
  |
  |-- ::respawn: runsvdir -P /var/service
  |     |
  |     |-- mdev        device manager
  |     |-- syslogd     system logger
  |     |-- getty-hvc0   serial console (115200 baud)
  |     |-- udhcpc      DHCP client on eth0
  |     `-- ntpd        NTP daemon (waits for network)
  |
  `-- ::shutdown: /lib/init/rc.shutdown
```

## Shutdown Flow

```
busybox init receives SIGTERM / reboot / poweroff
  |
  v
/lib/init/rc.shutdown
  |-- Load /etc/rc.conf
  |-- Run /etc/rc.d/*.pre.shutdown hooks
  |-- Save random seed
  |-- SIGTERM all processes (kall 15), wait 2s
  |-- SIGKILL all processes (kall 9)
  |-- swapoff -a
  |-- umount all non-pseudo filesystems
  |-- Remount / read-only, sync
  |-- Run /etc/rc.d/*.post.shutdown hooks
  `-- kpow p (poweroff) or kpow r (reboot)
```

## Init Components

**busybox init** (`/sbin/init -> /usr/bin/busybox`): PID 1. Reads
`/etc/inittab`, runs sysinit/shutdown actions, respawns gettys. Simple and
reliable — no supervision tree, no dependency graph, just sequential actions
and respawned processes.

**baseinit** (shell scripts in `/usr/lib/init/`):
- `rc.boot` — boot sequence, ~120 lines of shell
- `rc.shutdown` — shutdown sequence, ~60 lines
- `rc.lib` — shared functions: `log`, `mnt`, `mounted`, `sos`, `run_hook`, `random_seed`
- Hook system: drop scripts in `/etc/rc.d/` with `.boot`, `.pre.shutdown`, or `.post.shutdown` suffix

**kpow** (C): Calls `reboot(2)` to power off or reboot. Used at the
end of rc.shutdown as an init-agnostic shutdown method.

**kall** (C): Sends a signal to all processes except PID 1 and its own
session. Replacement for `killall5`.

## Service Management

**runit** provides service supervision via `runsvdir`. busybox init respawns
`runsvdir -P /var/service`, which monitors one `runsv` process per enabled
service.

### Service layout

```
/etc/sv/<name>/run        Service run script (executable, execs into daemon)
/etc/sv/<name>/supervise  -> /run/runit/supervise.<name>  (runsv state, tmpfs)
/var/service/<name>       -> /etc/sv/<name>  (symlink = enabled)
```

### Default services

| Service | Description |
|---------|-------------|
| mdev | Device manager (busybox) |
| syslogd | System logger (busybox) |
| getty-hvc0 | Serial console getty at 115200 baud |
| getty-tty1 | VT getty at 38400 baud (available, not enabled by default) |
| udhcpc | DHCP client on eth0 (busybox) |
| ntpd | NTP daemon (busybox) |
| acpid | ACPI event handler (busybox, not enabled by default) |

### Service ordering

Network-dependent services (ntpd) wait for `/run/network-up`, a marker file
created by the udhcpc lease script (`/etc/udhcpc.sh`) on successful DHCP
lease. The marker is removed on deconfig, so services re-block if the lease
is lost.

### Managing services

```sh
sv status /var/service/*   # Status of all enabled services
sv stop  /var/service/ntpd # Stop a service
sv start /var/service/ntpd # Start a service
ln -s /etc/sv/acpid /var/service/acpid  # Enable a service
rm /var/service/acpid                    # Disable a service
```

## Build Pipeline

All builds happen inside Docker on the host (macOS). Four Dockerfiles, each
producing a Docker image:

```
Dockerfile.linux   ->  kominka-kernel  (custom ARM64 kernel)
Dockerfile.boot    ->  kominka-boot    (rootfs + disk image builder)
Dockerfile.iso     ->  kominka-iso     (installer image, references the above)
```

### Dockerfile.boot (multi-stage)

```
Stage 1: ysh-builder
  Debian bookworm -> build oils-for-unix from source

Stage 2: pkg-builder
  Debian bookworm + build toolchain
  -> Install ysh from stage 1
  -> Copy package repo + source tarballs
  -> Register host-provided packages (cmake, go, ninja, glibc, perl)
  -> Run build_core.sh: build 23 packages with pm.ysh
  -> Output: /kominka-root (installed rootfs), /packages, tarballs

Stage 3: disk image builder
  Debian bookworm + e2fsprogs + gdisk
  -> Copy rootfs, ysh + libs, packages, tarballs, pm
  -> build_image.sh creates GPT disk image
```

### Disk Layout

```
GPT partition table:
  Partition 1: 256 MB  EFI System (FAT32)  - kernel as BOOTAA64.EFI
  Partition 2: 8 GB    Linux swap
  Partition 3: rest    Linux root (ext4)
```

### Kernel

Custom minimal kernel built from `tinyconfig` + `kernel.config` fragment.
All drivers built-in (no modules, no initramfs). Includes: ext4, virtio
(PCI/BLK/NET/console), NVMe, AHCI, USB, EFI stub, devtmpfs auto-mount,
framebuffer console.

## Package Manager

`pm.ysh` is a ~2000-line YSH script (port of KISS package manager v5.5.28).
Full lifecycle: dependency resolution, source download, checksum verification,
build, strip, tarball creation, atomic installation, removal, upgrades.

Packages are directories containing:
- `build` / `build.ysh` — build script (receives `$1=DESTDIR`, `$2=VERSION`)
- `version` — `VERSION RELEASE` format
- `sources` — one URL or path per line
- `checksums` — SHA256, one per source line
- `depends` — optional, one package per line

State is stored in `/var/db/kominka/installed/<pkg>/` with manifest, version,
and depends files.

Key environment variables:
- `KOMINKA_PATH` — colon-separated package repo search path
- `KOMINKA_ROOT` — target rootfs (default `/`)

## VM Boot (Development)

```sh
make kernel    # Build custom kernel (Dockerfile.linux)
make build     # Build rootfs + disk image (Dockerfile.boot + build_image.sh)
make boot      # Boot with vfkit (direct kernel boot, serial on stdio)
```

vfkit boots the uncompressed ARM64 `Image` directly with
`root=/dev/vda3 rw console=hvc0`. The kernel's built-in `CONFIG_CMDLINE`
provides `root=LABEL=KOMINKA_ROOT` for real hardware EFISTUB boot.
