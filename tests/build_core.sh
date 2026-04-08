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
    opendoas
    ysh
"

if [ $# -gt 0 ]; then
    pkgs="$*"
else
    pkgs=$all_pkgs
fi

# shellcheck disable=SC2086
echo "=== Installing core packages ==="
pm i $pkgs

# Remove fake host-provided entries before listing.
for fake in cmake go; do
    rm -rf "$KOMINKA_ROOT/var/db/kominka/installed/$fake"
done

echo ""
echo "=== Installed packages ==="
pm l
