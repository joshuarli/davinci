## Quick Start

Prerequisites: Docker, [vfkit](https://github.com/crc-org/vfkit) (`brew install vfkit`).

```sh
make boot   # builds everything, boots VM — autologins as josh
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make core` | Build `kominka:core` Docker image (~57MB, FROM scratch) |
| `make kernel` | Build kernel (ARM64 or x86_64) |
| `make iso` | Build bootable installer image |
| `make boot` | Boot in vfkit (virtiofs-mounts `tests/fixtures/repo` as `/packages`) |
| `make boot-installer` | Boot installer with virtual target disk |
| `make test` | Run all tests |

## Running Tests

```sh
python3 -m pytest tests/test_pm_cheap.py -v
```

## Building Packages

Use `build.yml` (workflow_dispatch, builds for both arches):

1. Actions → Build package → enter package name
2. Download artifacts, upload to R2:

```sh
for arch_dir in pkg-NAME-amd64 pkg-NAME-arm64; do
    case $arch_dir in *amd64) arch=x86_64-linux-gnu ;; *arm64) arch=aarch64-linux-gnu ;; esac
    for f in "$arch_dir"/*.tar.gz; do
        base=$(basename "$f"); pkg=${base%%@*}; verrel=${base#*@}; verrel=${verrel%.tar.gz}
        wrangler r2 object put "kominka-sources/${arch}/${pkg}/${verrel}.tar.gz" \
            --file="$f" --content-type=application/octet-stream --remote
    done
done
```

Or build locally:

```sh
docker build -t kominka:core .
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

The dream: boot to Linux + shell, the only userland is the package manager (a shell script) + busybox.

See ARCHITECTURE.md for system design. See AGENTS.md for contributor context.
