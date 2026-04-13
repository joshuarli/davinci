## Quick Start

Prerequisites: Docker, [vfkit](https://github.com/crc-org/vfkit) (`brew install vfkit`),
repo server running (`cd ~/d/repo/server && cargo run`).

```sh
make boot   # builds everything, boots VM — autologins as josh
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make core` | Build `kominka:core` Docker image (~57MB, FROM scratch) |
| `make kernel` | Build kernel (ARM64 or x86_64) |
| `make iso` | Build bootable installer image |
| `make boot` | Boot in vfkit (virtiofs-mounts `packages/` as `/packages`) |
| `make boot-installer` | Boot installer with virtual target disk |
| `make test` | Run all tests |
| `make rebuild-<pkg>` | Build + upload a package (zig cc, uses kominka:core) |

`make core` reads `KOMINKA_REPO` from `~/d/repo/.env` and builds with `--network=host`
so the Docker build can reach the local repo server at `localhost:3000`.

## Running Tests

```sh
python3 -m pytest tests/test_pm_cheap.py -v
```

## Building Packages

```sh
# Start the repo server first
cd ~/d/repo/server && source ~/d/repo/.env && cargo run

# Build and upload a package (sources credentials from ~/d/repo/.env)
make rebuild-curl

# Check what's in the index
curl -sf http://localhost:3000/ | less
```

For CI, `build.yml` (workflow_dispatch) builds for both arches automatically.

## Vision

1. Self-hosting minimal Linux — zero Debian in final images ✓
2. Clean YSH package manager ✓
3. Bootable installer ISO ✓
4. Multiarch (aarch64 + x86_64) ✓
5. Eventually replace ysh with exsh (non-interactive executor shell)
6. Wayland + Firefox (long term)

The dream: boot to Linux + shell, the only userland is the package manager (a shell script) + busybox.

See ARCHITECTURE.md for system design. See AGENTS.md for contributor context.
