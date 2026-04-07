## Quick Start

Prerequisites: Docker, [vfkit](https://github.com/crc-org/vfkit) (`brew install vfkit`).

```sh
make boot   # builds everything, boots VM — drops you into ysh on KISS Linux
```

That's it. `make boot` auto-triggers `make kernel` and `make build` if the
artifacts are missing.

## Build Pipeline

Three Docker builds produce the system. Each caches independently.

```
 Dockerfile.linux              Dockerfile.boot
 ┌──────────────────┐          ┌──────────────────────────────────┐
 │ kernel source     │          │ Stage 1: build ysh from source   │
 │ + kernel.config   │          │ Stage 2: pm.ysh builds KISS pkgs │
 │ (tinyconfig base) │          │   baselayout, musl, busybox      │
 └────────┬─────────┘          │ Stage 3: disk image tools        │
          │                     └──────────────┬───────────────────┘
     make kernel                          make build
          │                                    │
          ▼                                    ▼
       Image                         disk.img + initramfs.img
    (ARM64 kernel,                 (12G sparse GPT, ~200M actual)
     ~20M, all drivers             (EFI + swap + ext4 root with
     built-in)                      KISS rootfs + ysh)
          │                                    │
          └──────────┐    ┌────────────────────┘
                     ▼    ▼
                    make boot
                        │
                        ▼
                    vfkit VM ──► ysh shell on KISS Linux
```

The installer adds a third layer:

```
                  kiss-boot + kiss-kernel
                    (Docker images)
                           │
                      make iso ──────► Dockerfile.iso
                           │
                           ▼
                  kiss-installer.img
                (rightsized GPT: EFI + ext4 root
                 with rootfs + kernel + install script)
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
      make boot-installer          dd to USB
     (vfkit with /dev/vdb          + UEFI boot
      as virtual target)           on real hardware
```

## Make Targets

| Target | Produces | Description |
|--------|----------|-------------|
| `make kernel` | `Image` | Custom ARM64 kernel (tinyconfig + `kernel.config`). Ext4, virtio, NVMe, AHCI, USB, EFI stub all built-in. No modules. |
| `make build` | `disk.img`, `initramfs.img` | KISS rootfs built by pm.ysh inside Docker. 12G sparse GPT (256M EFI + 8G swap + ext4 root). The rootfs has baselayout + musl + busybox + ysh. |
| `make iso` | `kiss-installer.img` | Installer disk image, rightsized to content. Includes rootfs + kernel + `kiss-install` script + mkfs tools. |
| `make boot` | | Boot `disk.img` in vfkit. Auto-builds `Image` and `disk.img` if missing. |
| `make boot-installer` | | Boot installer in vfkit with a 12G virtual target at `/dev/vdb`. Auto-builds `Image` and `kiss-installer.img` if missing. |
| `make boot-log` | | Like `boot` but serial goes to `/tmp/kiss-serial.log`. |
| `make stop` | | Kill running vfkit. |
| `make test` | | `boot` (which auto-builds everything). |
| `make clean` | | Remove all build artifacts. |

### Artifacts

| File | Size | Sparse | Description |
|------|------|--------|-------------|
| `Image` | ~20M | no | Uncompressed ARM64 kernel. vfkit loads this directly. |
| `disk.img` | 12G apparent, ~200M actual | yes | VM system disk. Room to install packages inside the VM. |
| `initramfs.img` | ~50 bytes | no | Empty dummy — vfkit requires `--initrd` but our kernel doesn't need one. |
| `kiss-installer.img` | ~50-80M | no | Installer image, rightsized. `dd` this to a USB drive. |
| `target.img` | 12G apparent, ~0 actual | yes | Virtual target disk for testing the installer. Created by `make boot-installer`. |
| `kernel-config` | ~5K | no | Resolved `.config` from kernel build (for debugging). |

### Dev Loop

```sh
make kernel          # once (rebuilds only when kernel.config changes)
make build && make boot   # iterate on rootfs (edit build_image.sh, pm.ysh, etc.)
```

To rebuild the kernel after editing `kernel.config`:
```sh
make kernel && make boot
```

### Installer

```sh
make iso                # build installer image
make boot-installer     # test in VM — pick /dev/vdb as target
```

To flash to a real USB drive:
```sh
dd if=kiss-installer.img of=/dev/sdX bs=4M status=progress
```

Boot the target machine from USB via UEFI. The kernel has a built-in
`CONFIG_CMDLINE` (`root=LABEL=KISS_ROOT`) for EFISTUB boot — no
bootloader needed. After install, remove the USB and reboot.

### Running Tests

```sh
# Fast tests (no Docker)
python3 -m pytest tests/test_pm_cheap.py -v

# Full Docker build tests (download sources first)
cd tests && ./download_sources.sh && cd ..
python3 -m pytest tests/test_docker_build_ysh.py -v
```

## Vision

1. build kiss linux core with kiss (pm)
2. clean port to ysh
3. build installer iso
5. port more packages over to osh
6. start simplifying
   - would be nice to port away from autoconf, m4, etc.
   - use busybox as much as possible
7. once a brutally simple system is in place,
   we place `ysh` with `exsh` - the "executor shell"
8. then: wayland and firefox

The dream is to further shrink the required userland to the most
elemental tools and have `ysh` builtins replace most of the individual
text processing stuff - a coreutils-less distribution if you will.
The vision is that shell builtins can replace the need for many
individual traditional unix userland binaries - you boot to linux
and the shell and the only other userland is the package manager itself
which is just a shell script, and busybox (for now). That alone is
enough to ntpd, ip, dhcpcd and start downloading and building packages.

The idea behind using `ysh` is that the shell should be powerful and
expressive enough that it can be a beautiful language for
gluing together the rest of the system. No system perl, no python, etc.

---

POSIX shell is ugly but KISS Linux showed a usable system could be
possible wtih a package manager in pure POSIX shell. KISS also distilled
the userspace down to a reasonable minimum.

Alpine Linux showed that a viable distribution was possible based on
busybox and musl libc (though I'd like to avoid musl due to the performance hit).

Oil shell (ysh) showed that reimagining the shell as a more serious,
beautiful language was possible.
We can take these core design ideas, but also leave all of the
compatibility baggage behind since we're redesigning the entire
system. We have the opportunity to rewrite everything in `ysh`,
hopefully with minimal patching.

The vision is to use `ysh` as a PoC, then replace it with a rust
port called `exsh` - the "executor shell". The main innovation here is that `exsh` is exclusively limited to only execute scripts;
it doesn't have interactive mode. Shells carry a lot of complexity
with job control and line editing and history search etc. all of
which is not needed for a system shell.

I've already shown such a split is possible - a noninteractive core
shell `epsh` and a rich (fish-like) interactive layer built on top - `ish`.
