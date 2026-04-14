# Kominka Linux Architecture

## Overview

Kominka is a minimal, self-hosting Linux distribution. Supports aarch64 and x86_64. Custom kernel, busybox userspace, musl libc, zig as the system compiler. Builds inside Docker on macOS — no cross-compilation.

**Always reach for the most minimal software.** Fewer deps = shorter bootstrap, smaller images, less attack surface.

## Images

| Image | Contents |
|-------|----------|
| `kominka:core` | Core packages — minimal bootable system |
| `kominka-installer.img` | Bootable installer (MBR: EFI + ext4) |

FROM scratch. Only external dependency: `busybox:latest` (static musl) for the initial wget+tar bootstrap.

## Compiler Toolchain

Zig replaces gcc + binutils + ld — one binary, zero bootstrap chain:

| Wrapper | Implementation |
|---------|---------------|
| `cc`, `c++` | `zig cc` / `zig c++` |
| `ld` | `zig ld.lld` |
| `ar`, `ranlib` | `zig ar` / `zig ranlib` |
| `nm` | Custom 50-line C ELF parser |
| `objcopy` | `zig objcopy` |

All binaries are compiled with `zig cc -target ARCH-linux-musl` and dynamically link against musl libc.

## Core Packages

| Package | Role |
|---------|------|
| baselayout | FHS dirs, /etc configs, /bin→/usr/bin symlinks |
| musl | C library |
| mimalloc | System-wide allocator preloaded via ld.so.preload |
| busybox | init, sh, getty, mdev, udhcpc, ~170 applets |
| baseinit | rc.boot, rc.shutdown, rc.lib (YSH) |
| runit | Service supervision (runsvdir/runsv/sv) |
| boringssl | TLS library |
| curl | HTTP client + libcurl.so |
| ca-certificates | Root CAs |
| ysh | Shell (static musl binary, runs pm) |

`sudo-rs` is installed in the ISO layer (not core) with `NOPASSWD` for the `wheel` group.

## Build Pipeline

```
Dockerfile (FROM busybox:latest → FROM scratch)
  └── kominka:core   ← pm i core

Dockerfile.linux (FROM kominka:core)
  └── pm i linux → /out/Image

Dockerfile.iso (FROM kominka:core)
  └── pm i linux sudo-rs build-essential liveiso
  └── build_iso.sh → kominka-installer.img
```

All packages come from `~/d/repo`. Kernel and headers are the `linux` package.

## Bootstrap

The fetch stage (Docker Hub busybox, working TLS) downloads all core packages as tarballs named `pkg@ver-rel.tar.gz` into `/cache`. These pre-seed pm's binary cache so `pm i core` installs everything from disk without HTTPS calls. This bypasses a zig cc x86_64 boringssl SIGSEGV that prevents our curl from making HTTPS connections in OrbStack/QEMU.

```
busybox:latest (fetch stage)
  └── wget all core tarballs → /cache

FROM scratch (bootstrap stage)
  └── COPY /cache → /root/.cache/kominka/bin/
  └── pm i core → installs from cache, no downloads
  └── COPY → /kominka-root → final FROM scratch
```

## Boot Flow

**busybox init is PID 1** — not runit. Runit is used only as a service supervisor, not as an init replacement.

```
Kernel (EFISTUB, no initramfs, no switch_root)
  └── PID 1: /sbin/init  (busybox init, reads /etc/inittab)
```

Busybox init reads `/etc/inittab` on startup. The inittab has four types of entries:

```
::sysinit:/usr/lib/init/rc.boot        # run once before anything else
::restart:/sbin/init                   # re-exec on SIGHUP
::shutdown:/usr/lib/init/rc.shutdown   # run on shutdown/reboot
::respawn:runsvdir -P /var/service ... # restart if it dies
tty1::respawn:/bin/getty 38400 tty1   # virtual terminal
```

**sysinit phase** — busybox init runs `rc.boot` (a YSH script) synchronously and waits for it to finish:
1. Mount `/proc`, `/sys`, `/run`, `/dev`, `/dev/pts`, `/dev/shm`
2. Load `/etc/rc.conf`
3. Start device manager (`mdev -s` + `fork { mdev -df }`)
4. Remount rootfs read-only, then fsck, then remount read-write
5. Mount all local filesystems (`mount -a`)
6. Enable swap
7. Seed `/dev/urandom`
8. Set hostname from `/etc/hostname`
9. Apply sysctl settings
10. Kill device manager (services will restart it)
11. Run `/etc/rc.d/*.boot` hooks

**respawn phase** — after `rc.boot` exits, busybox init starts the `respawn` entries in parallel:
- `runsvdir -P /var/service` — runit service supervisor. Scans `/var/service/` for symlinks to service directories (`/etc/sv/{name}/`), starts a `runsv` process per service, monitors and restarts them.
- `/bin/getty 38400 tty1` — virtual terminal getty as fallback

**runit services** (managed by runsvdir) include `mdev`, `syslogd`, `getty-hvc0`, `udhcpc`, `ntpd`. Each service is a directory with a `run` script (YSH). The `run` script is exec'd by `runsv` in a tight loop — if it exits, `runsv` waits 1s and restarts it.

**getty-hvc0** service (`/etc/sv/getty-hvc0/run`):
```sh
exec getty 115200 hvc0 -n -l /usr/local/bin/autologin
```
`-n` skips login prompt. `-l /usr/local/bin/autologin` replaces the login program with an autologin script that optionally mounts the virtiofs packages share, then runs `su -l josh`.

**No switch_root / initramfs**: The kernel boots directly into the installed filesystem. There is no initial RAM disk and no pivot_root.

**Shutdown**: busybox init sends `SIGTERM` to all processes (via `killall5 -15`), waits, then runs `rc.shutdown` which stops runit services, kills remaining processes, unmounts filesystems, and remounts rootfs read-only. Busybox init handles the final `reboot(2)` syscall.

virtiofs mounts the host `packages/` (symlink to `~/d/repo/packages`) as `/packages` at autologin, so package definitions are live without rebuilding the image.

## Package Manager

See `~/d/pm/README.md`. Key behaviors:

- `pm i pkg` — install binary from repo server, auto-resolve runtime deps
- `pm b pkg` — build from source, resolve build+runtime deps
- `pm p pkg` — upload built tarball to repo server
- `pm t pkg` — show dependency tree
- Parallel downloads with live progress
- Make deps skipped when parent has a pre-built binary in the repo

## Self-Hosting

Packages are built in `kominka:core`. All build tools (zig, samurai, cmake, etc.) are installed from the repo server via `pm i build-essential`. Compiled-in paths are correct because the build environment IS the target (`KOMINKA_ROOT=/` effectively).

arm64 self-hosting via `build-package.yml` is fully working. x86_64 uses `bootstrap-build-package.yml` (Alpine environment) due to a zig cc boringssl SIGSEGV affecting our x86_64 curl. See `~/d/repo/ZIG-CC.md` and `~/d/repo/TODO.md`.

## Filesystem

```
/bin → /usr/bin          Merged-usr layout
/lib → /usr/lib
/sbin → /usr/bin
/usr/bin/busybox         + ~170 symlinks
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

## Networking

### Wired
udhcpc (busybox) handles DHCP. Service at `/etc/sv/udhcpc`, runs `udhcpc -f -i eth0`.

### WiFi
WiFi is managed by a minimal three-part stack, no network manager:

```
kernel nl80211 driver
    ↓ netlink socket (via libnl3)
wpa_supplicant    ← handles the WPA2 4-way handshake
    ↓ action script on CONNECTED/DISCONNECTED
udhcpc            ← gets IP address via DHCP
```

**Why wpa_supplicant?** WPA2-PSK authentication cannot be done in the kernel.
The 802.11 framing and frame exchange happen in the kernel (nl80211/cfg80211),
but the cryptographic 4-way handshake — which derives per-session keys from
the PSK — must run in userspace. There is no smaller well-audited alternative:

- **iwd** (Intel's daemon): modern but requires D-Bus at runtime
- **connman / NetworkManager**: both shell wpa_supplicant underneath, adding
  their own daemon and IPC layer on top
- **DIY nl80211 + crypto in shell**: the handshake math is well-defined but
  rolling custom crypto state machines invites CVEs

wpa_supplicant is built **without OpenSSL** for PSK-only operation. The PSK
path uses PBKDF2-SHA1 (passphrase → PMK) and HMAC-SHA256 (PTK derivation),
both provided by wpa_supplicant's internal crypto. The kernel handles CCMP
encryption after the supplicant installs the session keys. Result: one binary,
deps = musl + libnl only.

**Config files** (root-readable only):

| File | Contents |
|------|----------|
| `/etc/wifi.conf` | `IFACE=`, `SSID=`, `PSK=` (plaintext, 0600) |
| `/etc/wpa_supplicant.conf` | Generated by `wpa_passphrase`; PSK is hashed |

`/etc/wpa_supplicant.conf` is (re)generated from `wifi.conf` on each service
start, so editing `wifi.conf` is the only thing a user needs to do.

**Service lifecycle** (`/etc/sv/wifi/run`):
1. Checks `/etc/wifi.conf` exists; exits cleanly if not (no WiFi configured)
2. Regenerates `/etc/wpa_supplicant.conf` if `wifi.conf` is newer
3. Runs `wpa_supplicant -D nl80211` in the foreground (runit supervises)
4. wpa_supplicant calls `/usr/lib/wifi/action.sh` on state changes:
   - `CONNECTED` → starts `udhcpc -b -i $IFACE`
   - `DISCONNECTED` → kills udhcpc, flushes IP

**Setup** (installer or `wifi-setup` on a running system):
1. Detects wlan interfaces via `/sys/class/net/*/wireless`
2. Scans via wpa_supplicant + `wpa_cli scan` + `wpa_cli scan_results`
3. Prompts SSID (by number or name) + password (hidden input)
4. Connects; loops on failure
5. Writes `/etc/wifi.conf` and `/etc/wpa_supplicant.conf`

Enable after install: `ln -s /etc/sv/wifi /var/service/wifi`
