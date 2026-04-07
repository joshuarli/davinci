#!/bin/sh
# Bootstrap a self-hosting Kominka rootfs.
#
# Phase 1: Build all 16 core packages using the Alpine host toolchain,
#           installing into /kominka-root.
# Phase 2: Chroot into /kominka-root with host gcc bind-mounted, verify
#           the package manager works from inside the chroot.
#
# Usage: ./bootstrap.sh
set -e

ROOT=/kominka-root

phase1() {
    echo "============================================"
    echo "  Phase 1: Build core with host toolchain"
    echo "============================================"

    ./build_core.sh

    echo ""
    echo "Phase 1 complete. Installed packages:"
    pm l
}

phase2() {
    echo ""
    echo "============================================"
    echo "  Phase 2: Chroot verification"
    echo "============================================"

    # The chroot needs a few things to function:
    #   /dev, /proc, /sys      — kernel interfaces
    #   /tmp                   — build scratch space
    #   host gcc + binutils    — compiler (until we build our own)
    #   pm itself              — the package manager

    # Mount kernel filesystems.
    mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/tmp"
    mount --bind /dev  "$ROOT/dev"  2>/dev/null || true
    mount -t proc proc "$ROOT/proc" 2>/dev/null || true
    mount -t sysfs sys "$ROOT/sys"  2>/dev/null || true

    # Bind-mount the host compiler toolchain into the chroot.
    # We mount specific directories to keep the footprint small.
    mkdir -p "$ROOT/host"
    for d in /usr/bin /usr/lib /usr/libexec /usr/include; do
        mkdir -p "$ROOT/host$d"
        mount --bind "$d" "$ROOT/host$d" 2>/dev/null || true
    done

    # Copy pm into the chroot (it's not one of the built packages' bins).
    cp /usr/bin/pm "$ROOT/usr/bin/pm"
    chmod +x "$ROOT/usr/bin/pm"

    # Copy the repo into the chroot.
    mkdir -p "$ROOT/home/kominka"
    cp -r /packages "$ROOT/packages"
    cp -r /home/kominka/sources "$ROOT/home/kominka/sources"

    # Ensure build scripts are executable inside chroot.
    find "$ROOT/packages" -name build -exec chmod +x {} +

    # Run verification inside the chroot.
    chroot "$ROOT" /bin/sh <<'CHROOT_EOF'
        set -e

        export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/host/usr/bin
        export KOMINKA_PATH=/packages
        export KOMINKA_ROOT=/
        export KOMINKA_COMPRESS=gz
        export KOMINKA_COLOR=0
        export KOMINKA_PROMPT=0
        export KOMINKA_FORCE=1
        export KOMINKA_STRIP=0
        export LOGNAME=root
        export HOME=/root
        export CC=/host/usr/bin/gcc
        export CPPFLAGS="-I/usr/include"
        export LDFLAGS="-L/usr/lib"

        echo "--- chroot: verifying pm works ---"
        pm l
        echo ""

        echo "--- chroot: counting installed packages ---"
        count=$(pm l | wc -l)
        echo "$count packages installed"

        echo ""
        echo "--- chroot: searching for packages ---"
        pm s musl
        pm s busybox

        echo ""
        echo "--- chroot: rebuild test (baselayout) ---"
        # Rebuild baselayout as a quick smoke test — it's just mkdir/cp.
        pm b baselayout
        pm i baselayout
        echo "baselayout rebuilt successfully inside chroot"

        echo ""
        echo "--- chroot: rebuild test (pigz, uses $CC) ---"
        pm b pigz
        pm i pigz
        echo "pigz rebuilt successfully inside chroot"

        echo ""
        echo "Phase 2 complete: chroot is functional"
CHROOT_EOF

    # Cleanup mounts.
    for d in /usr/include /usr/libexec /usr/lib /usr/bin; do
        umount "$ROOT/host$d" 2>/dev/null || true
    done
    umount "$ROOT/dev"  2>/dev/null || true
    umount "$ROOT/proc" 2>/dev/null || true
    umount "$ROOT/sys"  2>/dev/null || true
}

phase1
phase2

echo ""
echo "============================================"
echo "  Bootstrap complete"
echo "============================================"
echo ""
echo "Seed packages from Alpine:"
echo "  gcc, g++, binutils, musl-dev, linux-headers, make, perl, bzip2, xz"
echo ""
echo "Kominka packages built and installed into $ROOT:"
pm l
