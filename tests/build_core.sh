#!/bin/sh
# Install Kominka core packages from pre-built binary tarballs.
#
# Requires KOMINKA_BIN_MIRROR to be set (R2 URL with binary packages).
#
# Usage: ./build_core.sh [pkg...]
#   No args = install all core packages.
#   With args = install only the named packages.
set -e

all_pkgs="
    glibc
    baselayout
    busybox
    baseinit
    runit
    boringssl
    curl
    e2fsprogs
    dosfstools
    opendoas
"

if [ $# -gt 0 ]; then
    pkgs="$*"
else
    pkgs=$all_pkgs
fi

for pkg in $pkgs; do
    echo "=== Installing: $pkg"
    pm i "$pkg" 2>&1 | tail -3
done

# Remove fake host-provided entries before listing.
for fake in cmake go ninja perl; do
    rm -rf "$KOMINKA_ROOT/var/db/kominka/installed/$fake"
done

echo ""
echo "=== Installed packages ==="
pm l
