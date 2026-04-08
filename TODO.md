# TODO

## Packaging

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
