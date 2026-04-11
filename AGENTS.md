# davinci — Kominka Linux

A self-hosting minimal Linux distribution built with the Kominka package manager (`pm.ysh`). Targets aarch64 and x86_64. No Debian, no host compiler in the final image — everything built from source with zig.

## Core Principle: Minimal Software

Always reach for the most minimal implementation. Every dependency is a liability — longer bootstrap, larger image, more attack surface.

- samurai (1 C file) instead of ninja
- zig (1 binary) instead of gcc + binutils + ld
- Custom nm.c (50 lines) — libtool compatibility
- busybox over GNU coreutils
- runit over systemd

## Repository Structure

```
Dockerfile                  # kominka:core (FROM busybox → FROM scratch, ~57MB)
Dockerfile.linux            # Kernel build (aarch64 + x86_64)
Dockerfile.iso              # Installer image (FROM kominka:core)
pm.ysh                      # Package manager (~2300 lines YSH)
install.sh                  # Interactive installer
kernel.config               # ARM64 kernel config fragment
kernel-x86_64.config        # x86_64 kernel config fragment
Makefile                    # Build orchestration
tests/
  test_pm_cheap.py          # 47 fast pm tests (no Docker)
packages/ → ~/d/repo/packages  # Package definitions (symlink)
.github/workflows/
  build.yml                 # Build any package (amd64 + arm64, workflow_dispatch)
  rebuild-world.yml         # Rebuild packages with conservative march flags
```

## Package Definitions

Every package is a single `PKGBUILD.ysh` file in `packages/<name>/` (symlink to `~/d/repo/packages`):

```ysh
#!/usr/local/bin/ysh

var name    = 'curl'
var ver     = '7.80.0'
var rel     = '5'
var deps    = ['boringssl', 'zlib']   # runtime deps
var mkdeps  = ['zig']                  # build-only deps (skipped on pm i)

var sources = ['https://curl.haxx.se/download/curl-VERSION.tar.xz']
var checksums = ['a132bd93...']

# Optional: arch-specific checksums override checksums
# var checksums_aarch64 = [...]
# var checksums_x86_64  = [...]

# Optional: skip binary stripping
# var nostrip = true

proc build(dest) {
    # dest is the staging directory (DESTDIR equivalent)
    ./configure --prefix=/usr ...
    make
    make DESTDIR=$dest install
}
```

**Source URL substitution**: `VERSION`, `ARCH`, `GOARCH`, `MAJOR`, `MINOR`, `PATCH`, `PACKAGE` are substituted. `ARCH` is the GNU triplet (e.g. `aarch64-linux-gnu`).

**Source line format**: `url-or-path [dest-subdir]` — the optional second field is the destination subdirectory in the build tree.

**Metapackages**: if `sources = []`, the package has no tarball — `pm i` just registers it in the db and installs its deps. Use for virtual groups.

## Package Manager Quick Reference

```sh
pm i <pkg>          # install binary from R2 mirror (skips make deps)
pm b <pkg>          # build from source (resolves make+runtime deps)
pm r <pkg>          # remove
pm l                # list installed
pm c <pkg>          # generate checksums
pm d <pkg>          # download sources only
pm s <pkg>          # search
pm U                # upgrade all packages
```

Key env vars: `KOMINKA_ROOT`, `KOMINKA_PATH`, `KOMINKA_BIN_MIRROR`, `KOMINKA_MIRROR`, `KOMINKA_COMPRESS=gz`, `KOMINKA_FORCE=1`.

## Building Packages in CI

`build.yml` builds a single package for both arches using `kominka:core` as the base:

1. Builds `kominka:core` (cached by content hash of Dockerfile + pm.ysh + PKGBUILDs)
2. Runs `pm i build-essential` inside to get build tools from R2
3. Runs `pm b <package>` — pm auto-resolves and builds deps if needed
4. Uploads the target package's tarball as a GitHub artifact

After downloading artifacts, upload to R2:
```sh
wrangler r2 object put "kominka-sources/{arch}/{pkg}/{ver}-{rel}.tar.gz" \
    --file=<tarball> --content-type=application/octet-stream --remote
```

## ARM64 Compatibility

R2 packages must work in Apple Virtualization.framework guests (used by vfkit on Apple Silicon). This guest CPU does NOT expose SVE, PAC, BTI, or other ARMv8.3+ security extensions.

- **zig cc** defaults to a conservative `armv8-a` baseline — safe for any ARM64 VM
- **GCC** on Graviton3 CI runners may emit SVE/newer instructions without explicit flags
- `rebuild-world.yml` rebuilds affected packages using GCC with `-march=armv8-a+lse+crypto`
- zig does NOT accept `-march=armv8-a` (GCC arch string format); it uses `-mcpu=<name>`

## Common Pitfalls

**zig cc march format**: zig cc doesn't accept GCC-style `-march=armv8-a+lse+crypto`. It uses CPU names (`-mcpu=cortex_a55`) not architecture strings. Don't set explicit march for zig builds — its default is already conservative.

**glibc clobbering**: Running `pm i` inside a non-Kominka environment (e.g. Ubuntu Docker) will attempt to install Kominka's glibc, overwriting the host's libc and breaking all system utilities. Always use `kominka:core` as the build base, or carefully pre-register system packages.

**Metapackage R2 lookups**: pm skips the R2 mirror for metapackages (empty `sources`). No 404s for virtual packages.

**Make deps at install time**: `pm i` never installs make deps. If `pm i pkg` fails with "missing N packages", those are runtime deps that need to be installed first, not make deps.

**pkg_owner was broken**: `pkg_owner` had a local `var _owns` shadowing the global, causing it to always return "not found". Fixed — swaps and alternatives now work correctly.

**lld version scripts**: lld is stricter than GNU ld — errors on undefined symbols in version scripts. Fix: use wildcard patterns (`pam_sm_*`) in the version script.
