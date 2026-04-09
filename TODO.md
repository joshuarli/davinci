# TODO

## Packaging

- openssh (remote access)
- ncurses + vim (text editing)
- zstd (compression, increasingly common for tarballs)

## Infrastructure

- Replace R2 wrangler uploads with a proper package server
- `pm upload` currently uses wrangler CLI — should use direct R2 API
  or a dedicated package repository service

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync
- Roll linux-headers into the linux kernel package
