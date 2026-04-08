# davinci

A project to build a complete Linux distribution using the Kominka package manager
(`pm`), with the eventual goal of porting the package manager to YSH and
building an installer ISO. The YSH port (`pm.ysh`) is in progress.

## Repository Structure

```
pm.ysh                      # The package manager (YSH, forked from KLPM 5.5.28)
YSH.md                      # YSH language reference and gotchas
Makefile                    # Build/boot/test orchestration
Dockerfile.boot             # Multi-stage: ysh + Kominka rootfs + disk image
Dockerfile.linux            # Custom kernel build (tinyconfig + kernel.config)
Dockerfile.iso              # Installer disk image (references kominka-boot + kominka-kernel)
build_image.sh              # Disk image assembly (runs inside Docker)
build_iso.sh                # Installer image assembly (runs inside Docker)
install.sh                  # Interactive installer script (runs on live rootfs)
kernel.config               # Kernel config fragment (ext4, virtio, EFI stub built-in)
TODO.md                     # Pending work items
tests/
  test_pm.py                # Unit-level integration tests (run on macOS/Linux, no Docker)
  test_pm_cheap.py          # Fast tests (search, list, deps, checksum) — no Docker, no builds
  test_docker_build_ysh.py  # Full build tests using pm.ysh in Debian Docker (with ysh)
  Dockerfile.ysh            # Debian-based image with ysh + build toolchain (pm.ysh)
  fixtures/
    repo/                   # Vendored Kominka package definitions (20 packages from the upstream repo)
      <package>/
        build               # Build script (POSIX shell, executable)
        build.ysh           # YSH build script (optional, preferred by pm.ysh)
        version             # "VERSION RELEASE" format
        sources             # Source URLs/paths (downloaded via KOMINKA_MIRROR or upstream)
        checksums           # SHA256 checksums, one per source line
        depends             # Dependencies (optional)
        patches/            # Patch files (optional)
        files/              # Config/data files (optional)
```

## How `pm` Works

`pm` is a YSH port of Dylan Araps' package manager (v5.5.28), a ~2000-line
script. It handles the full package lifecycle:

### Key Concepts

- **KOMINKA_PATH**: Colon-separated list of repository directories to search for
  packages. Each package is a directory containing `build`, `version`, and
  optionally `sources`, `checksums`, `depends`.
- **KOMINKA_ROOT**: Target root filesystem. All packages install relative to this.
  Defaults to `/`. Used for chroot/cross builds.
- **Package database**: `$KOMINKA_ROOT/var/db/kominka/installed/<pkg>/` stores
  manifest, version, depends, and build script for each installed package.
- **Alternatives**: When two packages own the same file, the conflict is
  stored in `$KOMINKA_ROOT/var/db/kominka/choices/` and can be swapped with `pm a`.

### Build Pipeline

1. **Dependency resolution** (`pkg_depends`): Walks the dependency tree,
   detects circular deps, orders deepest-first.
2. **Source download** (`pkg_source`): Fetches remote URLs or resolves local
   files. Supports VERSION/MAJOR/MINOR/PATCH placeholders.
3. **Checksum verification** (`pkg_verify`): SHA256 of each source vs checksums file.
4. **Source extraction** (`pkg_extract`): Tarballs extracted with strip-components
   implemented in shell. Local files copied in.
5. **Build** (`pkg_build`): Runs the package's `build` script with `$1=DESTDIR`,
   `$2=VERSION`. Sets CC, CXX, AR, etc.
6. **Manifest generation** (`pkg_manifest`): Lists all files in the built package.
7. **Binary stripping** (`pkg_strip`): Strips ELF binaries using `od` to detect type.
8. **Dependency fixup** (`pkg_fix_deps`): Uses `ldd`/`readelf` to find unlisted
   runtime deps.
9. **Tarball creation** (`pkg_tar`): Creates `<pkg>@<ver>-<rel>.tar.<compress>`.
10. **Installation** (`pkg_install`): Atomic file installation (temp name + mv).
    Handles upgrades by diff-removing old files then re-verifying.

### CLI Commands

| Command | Short | Description |
|---------|-------|-------------|
| `alternatives` | `a` | List/swap file alternatives between packages |
| `build` | `b` | Build packages (resolves deps, downloads, builds, creates tarballs) |
| `checksum` | `c` | Generate checksums for package sources |
| `download` | `d` | Download/verify package sources |
| `install` | `i` | Install package from tarball |
| `list` | `l` | List installed packages |
| `remove` | `r` | Remove installed packages |
| `search` | `s` | Search for packages in KOMINKA_PATH |
| `update` | `u` | Update repositories (git pull) and upgrade packages |
| `upgrade` | `U` | Upgrade installed packages to newer versions |
| `version` | `v` | Print version (5.5.28) |

### Important Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KOMINKA_PATH` | (required) | Package search path |
| `KOMINKA_ROOT` | `/` | Target rootfs |
| `KOMINKA_COMPRESS` | `gz` | Tarball compression (gz/bz2/xz/zst/lz/lzma) |
| `KOMINKA_PROMPT` | `1` | Set to `0` to skip confirmations |
| `KOMINKA_FORCE` | (unset) | Set to `1` to skip dep/removal checks |
| `KOMINKA_COLOR` | (auto) | Set to `0` to disable color |
| `KOMINKA_STRIP` | (unset) | Set to `0` to skip binary stripping |
| `KOMINKA_DEBUG` | `0` | Set to `1` to preserve build dirs on exit |
| `KOMINKA_KEEPLOG` | (unset) | Set to `1` to keep build logs |

### Notable Design Choices

- All string tests use `case` statements (no `[ ... ]`) for portability and speed.
- Functions communicate through globals (`repo_dir`, `repo_ver`, `_res`, etc.).
- `set -f`/`set +f` toggled throughout to control globbing precisely.
- `kill 0` used on build failure (no PIPEFAIL in POSIX shell).
- `file_rwx` parses `ls -ld` output to convert permissions to octal (fragile but portable).
- `/etc` files use 3-way checksum merge (old/installed/new) like Arch's pacman.

## YSH Port

`pm.ysh` is a line-by-line port of `pm` from POSIX shell to YSH (`ysh:all`
mode). Key differences from the POSIX version:

- **build.ysh preference**: `pm.ysh` checks for `build.ysh` before `build`.
  If a package has `build.ysh`, it runs `ysh build.ysh` instead of `./build`.
- **No word splitting**: Empty env vars like `$CFLAGS` pass `""` as an
  argument. Build scripts split flags into lists and splice with `@list`.
- **Explicit globbing**: `@[glob('pattern')]` instead of bare `*.ext`.
- **ARGV**: `ARGV[0]` replaces `$1`. `@ARGV` splices all args.
- **ENV access**: `ENV => get("VAR", "default")` instead of `$VAR`.
- **Error handling**: `try { proc }; if failed { die }` instead of
  `proc || die` (OILS-ERR-301 forbids procs on left of `||`).

16 of 20 vendored packages have `build.ysh` ports. See `YSH.md` for the
full language reference and gotchas discovered during porting.

## Boot Infrastructure

The project builds a bootable Kominka Linux disk image and can boot it in a VM:

- **`Dockerfile.linux`**: Builds a custom minimal Linux kernel from source
  (tinyconfig + `kernel.config` fragment). All drivers built-in, no modules,
  no initramfs required. Outputs uncompressed ARM64 `Image`.
- **`kernel.config`**: Config fragment merged on top of `make tinyconfig`.
  Includes built-in ext4, virtio (PCI/BLK/NET/console), NVMe, AHCI, USB,
  EFI stub, devtmpfs auto-mount, framebuffer console.
- **`Dockerfile.boot`**: Multi-stage Docker build. Stage 1 builds ysh from
  source. Stage 2 uses `pm.ysh` to build the Kominka rootfs (baselayout, glibc,
  busybox). Stage 3 assembles the disk image (no kernel — that's separate).
- **`build_image.sh`**: Runs inside Docker with `--privileged`. Creates a 12GB
  GPT disk image (256MB EFI + 8GB swap + ext4 root) via sgdisk + loopback
  mounts. Installs the Kominka rootfs and ysh + Debian shared libs.
- **`Dockerfile.iso`**: Builds the installer disk image. References kominka-boot
  (rootfs + ysh) and kominka-kernel (Image). Adds mkfs.ext4/mkfs.vfat from Debian
  and the install script. Outputs `kominka-installer.img`.
- **`build_iso.sh`**: Creates a rightsized image (EFI + ext4 root, sized to
  content) with the Kominka rootfs, ysh, mkfs.ext4/mkfs.vfat, and kernel.
- **`install.sh`**: Interactive installer. Lists block devices, shows
  partition layout with sizes, partitions with busybox fdisk (MBR: 256M EFI
  type 0xEF + 8G swap + ext4 root), formats, copies live rootfs to target,
  installs kernel to EFI as BOOTAA64.EFI.
- **`Makefile`**: File-based dependencies trigger rebuilds when sources change
  (e.g. editing `kernel.config` makes `Image` stale, which cascades to
  `kominka-installer.img`). Phony targets (`make kernel`, etc.) always run when
  invoked directly. `make boot` / `make boot-installer` auto-build missing
  or stale artifacts.
- The rootfs `/usr/bin/init` mounts pseudofs and execs ysh. Auto-detects
  installer mode if `pm-install` is present.
- vfkit boots the uncompressed ARM64 `Image` directly (not vmlinuz).
- `CONFIG_CMDLINE` provides a default `root=LABEL=KOMINKA_ROOT` for real hardware
  EFISTUB boot; vfkit overrides this via `--kernel-cmdline`.
- Dockerfiles ordered for layer caching: stable layers (ysh, Debian packages,
  kernel source) first, frequently-changed layers (pm.ysh, scripts) last.

## Vendored Packages

All packages from the upstream repo core are vendored:

**Core packages (built and tested)**:
baselayout, baseinit, busybox, glibc, boringssl, curl, e2fsprogs,
dosfstools, opendoas, runit

**Build-essential packages (built and tested)**:
zig, linux-headers, zlib, bzip2, xz, m4, make, bison, flex

**Other packages (vendored, not in default build)**:
git, grub, pkgconf, strace, perl, sqlite, libudev-zero, kominka

All packages are compiled with `zig cc` (clang-based, bundled with Zig).
No static linking — all binaries dynamically link against glibc.
Source tarballs are downloaded at build time from the R2 mirror
(`KOMINKA_MIRROR`) or upstream URLs.

## Running Tests

### Cheap Tests (fast, no Docker, no builds)

Exercise search, list, dependency resolution, checksum, and argument
validation. Every test class is duplicated for pm.ysh via subclassing
(YSH tests skipped if `ysh` is not installed):

```sh
python3 -m pytest tests/test_pm_cheap.py -v
```

### Unit Tests (fast, no Docker)

These test the pm CLI surface using mock packages in tmpdir rootfs's:

```sh
python3 -m unittest tests.test_pm -v
```

### Docker Build Tests (slow, builds real packages)

These build actual Kominka core packages inside Debian Docker:

```sh
python3 -m pytest tests/test_docker_build_ysh.py -v
```

### Manual Docker Testing

```sh
docker build -t pm-ysh-test -f tests/Dockerfile.ysh .
docker run -it pm-ysh-test sh

# Inside the container:
mkdir -p /kominka-root/var/db/kominka/installed /kominka-root/var/db/kominka/choices
KOMINKA_ROOT=/kominka-root pm b baselayout
KOMINKA_ROOT=/kominka-root pm l
```

## Known Issues and Build Fixes

Build fixes applied to vendored packages for zig cc (clang/lld) compatibility:

- **busybox**: CONFIG_TC disabled in `.config` (TC_CBQ_MAXPRIO removed in newer headers).
  Clang UB fix patch applied. Unsupported lld flags (`--warn-common`, `-Map`, `--verbose`)
  stripped from `scripts/trylink`. Dynamically linked (CONFIG_STATIC=n).
- **runit**: `-D_GNU_SOURCE` added for `setgroups()` declaration.
  `-Wno-implicit-function-declaration -Wno-incompatible-pointer-types` for old C style.
  `-static` removed from Makefile.
- **m4**: gnulib's `_GL_ATTRIBUTE_NODISCARD` redefined to empty.
- **make**: gnulib K&R prototypes sed'd out. Added `-Wno-error -Wno-int-conversion`.
- **boringssl**: CMake explicitly told to use `$CC`/`$CXX` (prevents fallback to system g++).
- **zlib**: Old version removed from zlib.net; uses fossils mirror. Must build with
  `-O2` to avoid zig's default UBSan instrumentation at `-O0`.
- **All packages**: Static linking removed (zig's lld cannot statically link glibc).
- **pm alternatives bug**: When exactly one other package is installed,
  `grep` doesn't prefix filenames in output, breaking `IFS=: read` parsing
  in `pkg_conflicts`. Tests work around this by ensuring multiple packages
  are installed first.
