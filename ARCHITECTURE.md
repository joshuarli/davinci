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
| busybox | init, sh, getty, mdev, udhcpc, ~170 applets |
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

Dockerfile.linux (FROM kominka:core)
  └── pm i linux → /out/Image

Dockerfile.iso (FROM kominka:core)
  └── pm i linux sudo-rs build-essential liveiso
  └── build_iso.sh → kominka-installer.img
```

All packages come from the repo server at `~/d/repo`. Kernel and headers are
the `linux` package; built once via `make rebuild-linux-debian`, then served
like any other package.

## Bootstrap

```
busybox:latest
  └── busybox wget → ysh (static musl binary, from new R2 bucket)
  └── ysh pm.ysh i core → downloads packages from repo server
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

virtiofs mounts the host `packages/` (symlink to `~/d/repo/packages`) as `/packages` at autologin, so package definitions are live without rebuilding the image.

## Package Manager

`pm.ysh` — ~2700 line YSH script. Key behaviors:

- `pm i pkg` — install binary from repo server, auto-resolve runtime deps
- `pm b pkg` — build from source, resolve build+runtime deps
- `pm p pkg` — upload built tarball to repo server
- Make deps skipped during `pm i`; also skipped during `pm b` when parent is already installed
- Each package operation receives the loaded package record as an explicit typed parameter (`p Dict`) — no shared mutable globals for package state
- Parallel downloads with live progress

## Repository

Package definitions and repository server live in `~/d/repo`. The server is a
Rust HTTP service (~400 lines, tiny_http + ureq, no async) backed by Cloudflare
R2 via S3 APIs. It serves a per-arch JSON package index and tarballs.

```
{arch}/{pkg}/{ver}-{rel}.tar.gz   R2 storage layout
{arch}/packages.json              package index
```

`pm i` fetches the remote package index and resolves deps without needing a
local git checkout of package definitions. `pm p` uploads built tarballs to
the server. See `~/d/repo/AGENTS.md` for server architecture details.

## ARM64 Compatibility

Packages must work in Apple Virtualization.framework guests (used by vfkit on
Apple Silicon). This CPU does NOT expose SVE, PAC, or BTI. zig cc defaults to
a conservative `armv8-a` baseline — safe for any ARM64 VM.

For packages needing gcc (glibc, git, strace), use `make rebuild-<pkg>-debian`
which builds with Debian GCC and explicit `-march=armv8-a+lse+crypto`.

## Self-Hosting

Packages are built in `kominka:core`. All build tools (zig, samurai, cmake, etc.)
are installed from the repo server via `pm i build-essential`. Compiled-in paths
are correct because the build environment IS the target (`KOMINKA_ROOT=/` effectively).

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
deps = glibc + libnl only.

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
