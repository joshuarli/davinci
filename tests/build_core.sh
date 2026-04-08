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
    busybox
    baseinit
    runit
    zlib
    boringssl
    curl
    e2fsprogs
    dosfstools
    opendoas
"

# Excluded from default build:
#   glibc — host Debian provides it; building from source is slow.
#   kominka, git, grub — need upstream sources not in the container.
#   core, build-essential — metapackages; deps are built individually.
#   Build-essential packages (zig, linux-headers, bzip2, xz, m4, make,
#   bison, flex) built on demand as dependencies.

if [ $# -gt 0 ]; then
    pkgs="$*"
else
    pkgs=$all_pkgs
fi

: > "$SUMS"

# Bootstrap zig (prebuilt binary) and switch to zig cc for all builds.
echo "================================================================"
echo "=== Bootstrapping zig cc"
echo "================================================================"
pm b zig 2>&1 | tail -3
pm i zig 2>&1 | tail -1
export PATH="$KOMINKA_ROOT/usr/bin:$PATH"
export CC=cc CXX=c++

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

# Remove fake host-provided entries before listing.
for fake in cmake go ninja glibc perl; do
    rm -rf "$KOMINKA_ROOT/var/db/kominka/installed/$fake"
done

echo ""
echo "================================================================"
echo "=== Installed packages"
echo "================================================================"
pm l

echo ""
echo "=== Artifact checksums ==="
cat "$SUMS"
