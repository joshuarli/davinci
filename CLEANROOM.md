# Cleanroom Build Strategy

Goal: build every Kominka package using only Kominka packages.
The only external requirement is a minimal Debian image that runs pm
(shell utilities + curl for downloading + tar for extraction). Zero
Debian compilers, linkers, or build tools.

## Current state (2026-04-07)

### Phase 1: COMPLETE

`tests/Dockerfile.toolchain` builds BoringSSL from source using only
Kominka packages. Zero Debian build tools.

### On R2 (aarch64 binaries)

Core (9):
- glibc, baselayout, busybox, baseinit, runit
- boringssl (0.20260327.0-6, shared libs + headers)
- curl (7.80.0-5, shared lib + headers), opendoas, ysh

Toolchain (7):
- zig 0.15.2-2 (cc, c++, ld via lld, ar, ranlib, nm, objcopy)
- make, samurai (ninja), cmake, go
- zlib, linux-headers

Other (4):
- bison, m4, dosfstools, e2fsprogs

### Not on R2

Need to build and upload for Phase 2:
- **git** — built from source in cleanroom, not yet uploaded
- **bzip2** — source tarball decompression
- **xz** — source tarball decompression
- **flex** — parser generator
- **pkgconf** — pkg-config implementation

Not needed for self-hosting (zig replaces gcc):
- ~~gcc, binutils~~ — deleted, zig provides cc/ld/ar/nm
- perl — git builds without it (`NO_PERL=YesPlease`)
- grub — installer only
- sqlite, strace, libudev-zero — optional

### Debian runtime (pm only)

What Debian provides in `tests/Dockerfile.toolchain`:
- coreutils, findutils, grep, sed, gawk, diffutils
- curl, ca-certificates
- gzip, bzip2, xz-utils, tar
- patch

No compilers. No linkers. No build tools.

## Phases

### Phase 1: Build BoringSSL from source (DONE)

Validated in `tests/Dockerfile.toolchain`. BoringSSL builds from a
GitHub release tarball using only Kominka packages for the toolchain:

| Tool | Provider |
|------|----------|
| C/C++ compiler | zig cc (Kominka) |
| Linker | zig ld.lld (Kominka) |
| ar, nm, ranlib | zig wrappers (Kominka) |
| Build system | cmake (Kominka) |
| ninja | samurai (Kominka) |
| Go | go (Kominka) |
| make | make (Kominka) |

### Phase 2: Build ALL packages from source

Extend `tests/Dockerfile.toolchain` to build every package from source
in dependency order. Need to build and upload: git, bzip2, xz, flex,
pkgconf first.

Build order:
```
glibc → baselayout → busybox → baseinit → runit
zlib → boringssl → curl → git
opendoas → ysh
make → samurai → cmake
go
bzip2 → xz → flex → bison → m4
e2fsprogs → dosfstools
pkgconf
```

### Phase 3: Replace Debian pm runtime

Replace Debian shell utilities with Kominka's own:
- busybox provides: coreutils, findutils, grep, sed, diffutils, gzip,
  bzip2, tar, patch
- Kominka curl replaces Debian curl
- Kominka xz replaces Debian xz-utils
- Need: ca-certificates (or ship cert bundle via boringssl)

### Phase 4: Boot from own foundation

Build the live ISO using only Kominka-built packages. The entire
system — kernel, bootloader, userspace, package manager, every
library — comes from our repos.

## Gaps and workarounds

### PATH ordering — critical

**Kominka binaries MUST come AFTER Debian binaries on PATH.**

```dockerfile
# WRONG — Kominka curl can't find libssl.so, spins at 100% CPU forever
ENV PATH=/kominka-root/usr/bin:$PATH

# RIGHT — Debian curl handles downloads, Kominka tools handle builds
ENV PATH=$PATH:/kominka-root/usr/bin
```

Kominka binaries are built to run inside KOMINKA_ROOT (their ELF
interpreter points to `/usr/lib/ld-linux-aarch64.so.1` inside the
chroot). Running them on the Debian host fails because:
1. The dynamic linker can't find shared libs (`libssl.so`, etc.)
2. Even with `LD_LIBRARY_PATH`, mixing Kominka and Debian libs causes
   **segfaults** (status 139) or **infinite CPU spin** (status 141)

Set `CC`, `CXX` etc. explicitly to point at Kominka's zig wrappers:
```dockerfile
ENV CC=/kominka-root/usr/bin/cc CXX=/kominka-root/usr/bin/c++
```

### BoringSSL source

Switched from `git+https://boringssl.googlesource.com/boringssl` to a
GitHub release tarball. Googlesource rejects partial clones
(`--filter=blob:none`) with SIGPIPE, and Kominka's git binary can't
run on the Debian host (ELF interpreter mismatch). The tarball is
simpler, faster, and reproducible.

### Shared library creation

Zig's linker must be exposed as `zig ld.lld` (the real lld), not a
wrapper that translates flags through `zig cc -Wl,...`. Libtool calls
`ld` directly with flags like `-shared`, `-soname`, `-o` — a
pass-through to lld handles these natively. The old `zig cc` wrapper
silently failed to create shared libraries.

### nm for libtool

Libtool needs `nm` to extract export symbols when creating shared
libraries. Zig doesn't provide nm. Solved with a 50-line C ELF symbol
parser (`files/nm.c`) compiled with zig during the zig package build.

### Headers in packages

`pkg_clean_dev` was stripping `/usr/include` and `/usr/lib/pkgconfig`
from binary tarballs, breaking builds that depend on those libraries.
Fixed: headers and pkgconfig are preserved. Will move to `-dev` package
splits later.

### MAKEFLAGS

pm now sets `MAKEFLAGS=-j<nproc>` automatically for all builds. No
need for `-j` flags in individual build scripts.

### Comments in sources files

pm's source parser treats `#` at the start of a line as a comment (via
`case \#*`). Do not put comments on lines with source URLs — the `#`
in `git+URL#commit` works because it's mid-line, but standalone
comment lines may parse incorrectly in some edge cases.

## What "cleanroom" means

| Category | Provider |
|----------|----------|
| C/C++ compiler | zig (Kominka) |
| Linker | zig ld.lld (Kominka) |
| ar, nm, ranlib, objcopy | zig wrappers (Kominka) |
| Build tools | make, cmake, samurai (Kominka) |
| Languages | go (Kominka) |
| Libraries | glibc, boringssl, zlib, curl (Kominka) |
| Host OS | POSIX shell utilities + network access only |
