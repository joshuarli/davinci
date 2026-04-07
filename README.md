## Quick Start

Prerequisites: Docker, [vfkit](https://github.com/crc-org/vfkit) (`brew install vfkit`).

```sh
# Build the custom kernel (ext4, virtio, EFI stub built-in — no initramfs).
make kernel

# Build the rootfs disk image (KISS Linux built with pm.ysh inside Docker).
make build

# Boot the VM (drops you into a ysh shell on the KISS rootfs).
make boot
```

### Make Targets

| Target | Description |
|--------|-------------|
| `make kernel` | Build custom minimal Linux kernel via Docker (outputs `Image`) |
| `make build` | Build KISS rootfs and disk image via Docker (outputs `disk.img`) |
| `make iso` | Build installer disk image (outputs `kiss-installer.img`) |
| `make boot` | Boot the VM with vfkit (needs `Image` + `disk.img`) |
| `make boot-installer` | Boot installer in VM with a 12G virtual target disk |
| `make boot-log` | Boot the VM in background, serial output to `/tmp/kiss-serial.log` |
| `make stop` | Stop the running VM |
| `make test` | `kernel` + `build` + `boot` |
| `make clean` | Remove build artifacts |

### Installer

Build the installer and test it in a VM:

```sh
make iso             # builds kiss-installer.img
make boot-installer  # boots installer with a virtual target disk (/dev/vdb)
# Inside the VM: run 'kiss-install', select /dev/vdb
```

To flash to a real USB drive:

```sh
dd if=kiss-installer.img of=/dev/sdX bs=4M status=progress
```

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

