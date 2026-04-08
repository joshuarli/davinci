# TODO

## Bugs

- **flex**: stage1flex crashes with SIGPIPE when built with zig cc.
  May be a zig signal handling issue with self-bootstrapping builds.
- **strip**: zig objcopy can't `--strip-all` on shared libs or static
  musl binaries. Wrapper backs up and restores on failure. Binaries
  are larger than necessary.

## Packaging

- CA certificates package (currently using `KOMINKA_INSECURE=1`)
- openssh (remote access)
- ncurses + vim (text editing)
- zstd (compression, increasingly common for tarballs)

## Multi-architecture

- x86_64 installer ISO and package builds
- `go` package source URL hardcoded to `linux-arm64` — needs ARCH
  substitution in pm or per-arch source files
- Kernel config for x86_64

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- Roll linux-headers into the linux kernel package
