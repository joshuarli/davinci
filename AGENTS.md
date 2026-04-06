# davinci

A project to build a complete Linux distribution using the KISS package manager
(`pm`), with the eventual goal of porting the package manager to osh and
building an installer ISO.

## Repository Structure

```
pm                          # The package manager (KISS 5.5.28, pure POSIX shell)
tests/
  test_pm.py                # Unit-level integration tests (run on macOS/Linux, no Docker)
  test_docker_build.py      # Full build tests (builds real packages in Alpine Docker)
  Dockerfile                # Alpine-based image with build toolchain
  download_sources.sh       # Downloads upstream source tarballs to fixtures/sources/
  localize_sources.sh       # Rewrites sources files to use local paths
  fixtures/
    repo/                   # Vendored KISS package definitions (20 packages from kisslinux/repo core)
      <package>/
        build               # Build script (executable)
        version             # "VERSION RELEASE" format
        sources             # Source URLs/paths (localized to /home/kiss/sources/...)
        checksums           # SHA256 checksums, one per source line
        depends             # Dependencies (optional)
        patches/            # Patch files (optional)
        files/              # Config/data files (optional)
    sources/                # Downloaded upstream tarballs (~263MB, gitignored)
      <package>/
        <tarball>
```

## How `pm` Works

`pm` is Dylan Araps' KISS package manager (v5.5.28), a ~2000-line POSIX shell
script. It handles the full package lifecycle:

### Key Concepts

- **KISS_PATH**: Colon-separated list of repository directories to search for
  packages. Each package is a directory containing `build`, `version`, and
  optionally `sources`, `checksums`, `depends`.
- **KISS_ROOT**: Target root filesystem. All packages install relative to this.
  Defaults to `/`. Used for chroot/cross builds.
- **Package database**: `$KISS_ROOT/var/db/kiss/installed/<pkg>/` stores
  manifest, version, depends, and build script for each installed package.
- **Alternatives**: When two packages own the same file, the conflict is
  stored in `$KISS_ROOT/var/db/kiss/choices/` and can be swapped with `kiss a`.

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
| `search` | `s` | Search for packages in KISS_PATH |
| `update` | `u` | Update repositories (git pull) and upgrade packages |
| `upgrade` | `U` | Upgrade installed packages to newer versions |
| `version` | `v` | Print version (5.5.28) |

### Important Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KISS_PATH` | (required) | Package search path |
| `KISS_ROOT` | `/` | Target rootfs |
| `KISS_COMPRESS` | `gz` | Tarball compression (gz/bz2/xz/zst/lz/lzma) |
| `KISS_PROMPT` | `1` | Set to `0` to skip confirmations |
| `KISS_FORCE` | (unset) | Set to `1` to skip dep/removal checks |
| `KISS_COLOR` | (auto) | Set to `0` to disable color |
| `KISS_STRIP` | (unset) | Set to `0` to skip binary stripping |
| `KISS_DEBUG` | `0` | Set to `1` to preserve build dirs on exit |
| `KISS_KEEPLOG` | (unset) | Set to `1` to keep build logs |

### Notable Design Choices

- All string tests use `case` statements (no `[ ... ]`) for portability and speed.
- Functions communicate through globals (`repo_dir`, `repo_ver`, `_res`, etc.).
- `set -f`/`set +f` toggled throughout to control globbing precisely.
- `kill 0` used on build failure (no PIPEFAIL in POSIX shell).
- `file_rwx` parses `ls -ld` output to convert permissions to octal (fragile but portable).
- `/etc` files use 3-way checksum merge (old/installed/new) like Arch's pacman.

## Vendored Packages

All 20 packages from `kisslinux/repo` core are vendored:

**Built and tested (16 packages)**:
baselayout, baseinit, busybox, musl, linux-headers, bzip2, xz, zlib,
pigz, bison, flex, m4, make, curl, openssl, kiss

**Vendored but not built** (too complex for the Alpine cross-build env):
binutils, gcc, git, grub

Sources files have been rewritten to point to local tarballs in
`/home/kiss/sources/` (the path inside the Docker container).

## Running Tests

### Unit Tests (fast, no Docker)

These test the pm CLI surface using mock packages in tmpdir rootfs's:

```sh
python3 -m unittest tests.test_pm -v
```

### Docker Build Tests (slow, builds real packages)

These build actual KISS core packages inside Alpine Docker:

```sh
# 1. Download source tarballs (once, ~263MB).
cd tests && ./download_sources.sh

# 2. Run the full build suite.
python3 -m unittest tests.test_docker_build -v

# Or build all 16 packages via the helper script directly:
docker build -t pm-test -f tests/Dockerfile .
docker run --rm pm-test ./build_core.sh
```

### Manual Docker Testing

```sh
# Build the image.
docker build -t pm-test -f tests/Dockerfile .

# Start a container.
docker run -it pm-test sh

# Inside the container:
mkdir -p /kiss-root/var/db/kiss/installed /kiss-root/var/db/kiss/choices
KISS_ROOT=/kiss-root kiss b baselayout
KISS_ROOT=/kiss-root kiss l
```

## Known Issues and Build Fixes

Build fixes applied to vendored packages for Alpine compatibility:

- **busybox**: CONFIG_TC disabled in `.config` (TC_CBQ_MAXPRIO removed in newer headers).
  Source URL changed from git.busybox.net snapshot to busybox.net/downloads/.
- **m4**: gnulib's `_GL_ATTRIBUTE_NODISCARD` redefined to empty (GCC compat).
- **make**: gnulib K&R prototypes (`extern char *getenv ()`) conflict with musl;
  sed'd out at build time. Added `-Wno-error -Wno-int-conversion`.
- **openssl**: Changed target from `linux-x86_64` to `linux-generic64` (Alpine
  GCC doesn't support -m64). Removed `perl` from depends (Alpine provides it).
- **pigz**: Upstream URL dead; uses GitHub archive. Checksums updated.
- **zlib**: Old version removed from zlib.net; uses fossils mirror.
- **kiss**: Removed `git` dependency (not needed for the simple file-copy build).
- **git, binutils, gcc, grub**: Not built — too complex for Alpine cross-build
  (musl basename conflict, missing REG_STARTEND, long compile times).
- **pm alternatives bug**: When exactly one other package is installed,
  `grep` doesn't prefix filenames in output, breaking `IFS=: read` parsing
  in `pkg_conflicts`. Tests work around this by ensuring multiple packages
  are installed first.
