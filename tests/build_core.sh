#!/bin/sh
# Build and install Kominka core packages into /kominka-root, recording
# artifact checksums to /kominka-root/artifact-checksums.
#
# Usage: ./build_core.sh [pkg...]
#   No args = build all core packages in dependency order.
#   With args = build only the named packages.
set -e

SUMS=/kominka-root/artifact-checksums

all_pkgs="
    baselayout
    musl
    linux-headers
    zlib
    bzip2
    xz
    m4
    make
    busybox
    baseinit
    boringssl
    curl
    pigz
    bison
    flex
    binutils
    gcc
    pm
"

# Heavy packages excluded from default build:
#   git, grub — require complex cross-compilation fixes and/or
#   take too long. Pass them explicitly to build.

if [ $# -gt 0 ]; then
    pkgs="$*"
else
    pkgs=$all_pkgs
fi

: > "$SUMS"

for pkg in $pkgs; do
    echo "================================================================"
    echo "=== Building: $pkg"
    echo "================================================================"

    pm b "$pkg" 2>&1 | tail -5
    pm i "$pkg" 2>&1 | tail -1

    # Record the tarball checksum.
    tarball=$(ls -1t "$HOME/.cache/kominka/bin/${pkg}@"*.tar.* 2>/dev/null | head -1)
    if [ -n "$tarball" ]; then
        hash=$(sha256sum "$tarball" | cut -d' ' -f1)
        echo "$hash  ${tarball##*/}" >> "$SUMS"
        echo "  artifact: ${tarball##*/} sha256=$hash"
    fi
done

echo ""
echo "================================================================"
echo "=== Installed packages"
echo "================================================================"
pm l

echo ""
echo "=== Artifact checksums ==="
cat "$SUMS"
