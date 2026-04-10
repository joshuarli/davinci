## Quick Start

Prerequisites: Docker, [vfkit](https://github.com/crc-org/vfkit) (`brew install vfkit`).

```sh
make boot   # builds everything, boots VM — drops you into ysh on Kominka Linux
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make core` | Build `kominka:core` Docker image (~57MB, FROM scratch) |
| `make kernel` | Build ARM64 kernel |
| `make iso` | Build 161MB bootable installer image |
| `make boot` | Boot `kominka:core` in vfkit VM |
| `make boot-installer` | Boot installer in vfkit with virtual target disk |
| `make test` | Run all tests |

## Running Tests

```sh
# Fast unit tests (no Docker, no builds)
python3 -m pytest tests/test_pm_cheap.py -v
```

## Building Packages

Use the `build.yml` GitHub Actions workflow (workflow_dispatch) to build packages for both aarch64 and x86_64:

1. Go to Actions → Build package
2. Enter package name
3. Download artifacts and upload to R2 with `pm p`

Or build locally inside `kominka:core`:

```sh
docker run --rm \
  -v "$PWD/tests/fixtures/repo:/packages:ro" \
  -e KOMINKA_PATH=/packages \
  -e KOMINKA_BIN_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev \
  -e KOMINKA_COMPRESS=gz -e KOMINKA_FORCE=1 \
  kominka:core sh -c 'pm i build-essential && pm b <pkg>'
```

## Vision

1. Self-hosting minimal Linux — zero Debian in final images ✓
2. Clean YSH package manager ✓
3. Bootable installer ISO ✓
4. Multiarch (aarch64 + x86_64) ✓
5. Eventually replace ysh with exsh (non-interactive executor shell)
6. Wayland + Firefox (long term)

The dream: boot to Linux + shell, the only userland is the package manager (a shell script) + busybox. Shell builtins replace individual text-processing utilities. No system Perl, no Python.

See ARCHITECTURE.md for system design. See AGENTS.md for contributor context.
