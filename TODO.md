# TODO

## Packaged but not yet building in Docker

These packages are defined in `tests/fixtures/repo/` with sources downloaded
but get SIGTERM'd during Docker build. Need to debug — possibly OrbStack
resource limits or a pm interaction issue. Build individually with:
`sh build_core.sh e2fsprogs`

- e2fsprogs (ext4 tools — fsck.ext4, mkfs.ext4)
- dosfstools (FAT tools — mkfs.vfat, fsck.fat)
- opendoas (privilege escalation, sudo alternative)
- pkgconf (pkg-config implementation)
- strace (syscall tracer)
- perl (scripting language, build dep for many packages)
- sqlite (embedded database)
- libudev-zero (minimal libudev without systemd)

## Deferred packages

Build system / scripting:
- python (hoping to replace with `uv` for Python tooling)
- meson (requires python or samurai)
- samurai (ninja-compatible build tool in C)
- ninja (alternative to samurai)
- libffi (dependency of python)

Console tools:
- ncurses (needed by vim, mutt, and TUI programs)
- vim (text editor — needs ncurses)
- openssh (remote access — needs openssl)
- mandoc + man-pages (documentation)
- bkeymaps (console keyboard layouts)
- gnupg1 (package/commit signing)
- ccache (faster rebuilds when self-hosting)
- mdevd (better hotplug daemon than busybox mdev)
- zstd (compression, increasingly used for tarballs)

## Installer

- ~~User creation prompt during install~~ (done — install.sh)
- Test installer user creation end-to-end

## linux-headers

Roll into the linux kernel package — it already has the full source, so
`make headers` comes for free. No need for a separate linux-headers package.

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- Consider switching /bin/sh from osh to busybox ash (osh has compat issues with POSIX scripts)
