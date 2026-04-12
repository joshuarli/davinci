#!/usr/bin/busybox sh
# Kominka Linux installer.
# Partitions a disk, formats filesystems, copies the live rootfs, and
# builds a machine-specific kernel for the target hardware.
#
# Partition layout (MBR via busybox fdisk):
#   1: EFI System (256M, FAT32, type 0xEF)  -> /boot
#   2: Linux swap  (8G, type 0x82)
#   3: Linux root  (rest, ext4, type 0x83)

set -eu

BB=/usr/bin/busybox
ARCH=$($BB uname -m)
MNT=/mnt/target
KERNEL_VER=6.19.12
KERNEL_SHA256=ce5c4f1205f9729286b569b037649591555f31ca1e03cc504bd3b70b8e58a8d5

echo "Kominka Linux Installer"
echo ""

# ── Network setup ────────────────────────────────────────────────────────────
# Network is needed to download the kernel source (~130MB) for machine-specific
# builds. Optional — skipping falls back to the pre-built baseline kernel.

setup_network() {
    WLAN=""
    for _d in /sys/class/net/*/wireless; do
        [ -d "$_d" ] && WLAN=$($BB basename $($BB dirname "$_d")) && break
    done

    if [ -n "$WLAN" ]; then
        $BB printf "Wireless interface %s detected. Connect to WiFi now? [y/N] " "$WLAN"
        $BB printf "(needed for machine-specific kernel download)\n"
        read -r _ans
        case "$_ans" in
            y|Y) wifi-setup ;;
        esac
    fi
}

# ── Machine selection ─────────────────────────────────────────────────────────

MACHINE_PROFILE=""   # empty = use baseline (pre-built kernel, no custom build)
MACHINE_NAME=""

detect_machine() {
    [ "$ARCH" = "x86_64" ] || return 0

    MACHINES_DIR=/usr/share/kominka/machines
    [ -d "$MACHINES_DIR" ] || return 0

    DMI=$($BB cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    [ -n "$DMI" ] || return 0

    # Look up DMI name in the index.
    MATCH=$($BB grep -F "^${DMI}=" "$MACHINES_DIR/index" 2>/dev/null | $BB cut -d= -f2 || true)

    echo ""
    echo "==> Machine detection"
    if [ -n "$MATCH" ] && [ -f "$MACHINES_DIR/${MATCH}.config" ]; then
        echo "    Detected: $DMI"
        echo ""
        $BB printf "    Build kernel for '%s'? [Y/n/list] " "$MATCH"
        read -r _ans
        case "$_ans" in
            n|N)
                MACHINE_PROFILE="" ;;
            l|list|L)
                select_machine ;;
            *)
                MACHINE_PROFILE="$MATCH"
                MACHINE_NAME="$DMI"
                ;;
        esac
    else
        echo "    Machine not in profile list (DMI: ${DMI:-unknown})"
        echo ""
        $BB printf "    Build a machine-specific kernel? [y/N/list] "
        read -r _ans
        case "$_ans" in
            y|Y)      select_machine ;;
            l|list|L) select_machine ;;
            *)        MACHINE_PROFILE="" ;;
        esac
    fi

    if [ -n "$MACHINE_PROFILE" ]; then
        echo ""
        echo "    Will build: $MACHINE_PROFILE"
    else
        echo ""
        echo "    Using pre-built baseline kernel."
    fi
}

select_machine() {
    MACHINES_DIR=/usr/share/kominka/machines
    echo ""
    echo "    Available profiles:"
    i=1
    for cfg in "$MACHINES_DIR"/*.config; do
        name=$($BB basename "$cfg" .config)
        $BB printf "      %2d) %s\n" "$i" "$name"
        i=$((i + 1))
    done
    echo ""
    $BB printf "    Enter number (or blank to use baseline): "
    read -r _num
    [ -z "$_num" ] && return 0

    i=1
    for cfg in "$MACHINES_DIR"/*.config; do
        if [ "$i" = "$_num" ]; then
            MACHINE_PROFILE=$($BB basename "$cfg" .config)
            MACHINE_NAME="$MACHINE_PROFILE"
            return 0
        fi
        i=$((i + 1))
    done
    echo "    Invalid selection — using baseline."
}

# ── Kernel build ──────────────────────────────────────────────────────────────

install_kernel() {
    $BB mkdir -p "$MNT/boot/EFI/BOOT"

    if [ "$ARCH" = "x86_64" ] && [ -n "$MACHINE_PROFILE" ]; then
        build_kernel_x86_64
    else
        # Baseline pre-built kernel.
        case "$ARCH" in
            x86_64)  EFI_NAME=BOOTX64.EFI ;;
            aarch64) EFI_NAME=BOOTAA64.EFI ;;
            *)        EFI_NAME=BOOTX64.EFI ;;
        esac
        $BB cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/$EFI_NAME"
        echo "    Baseline kernel installed."
    fi
}

build_kernel_x86_64() {
    MACHINES_DIR=/usr/share/kominka/machines
    PROFILE_CFG="$MACHINES_DIR/${MACHINE_PROFILE}.config"
    BUILD_DIR="$MNT/tmp/kernel-build"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VER}.tar.xz"

    echo ""
    echo "==> Building machine-specific kernel ($MACHINE_PROFILE)"
    echo "    Kernel: linux-$KERNEL_VER"
    echo ""

    $BB mkdir -p "$BUILD_DIR"

    # Download kernel source.
    echo "    Downloading kernel source (~130MB)..."
    TARBALL="$BUILD_DIR/linux-${KERNEL_VER}.tar.xz"
    if ! /usr/bin/curl -fsSL --progress-bar -o "$TARBALL" "$KERNEL_URL"; then
        echo "    Download failed — falling back to baseline kernel."
        $BB cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
        $BB rm -rf "$BUILD_DIR"
        return 0
    fi

    # Verify checksum.
    ACTUAL=$($BB sha256sum "$TARBALL" | $BB cut -d' ' -f1)
    if [ "$ACTUAL" != "$KERNEL_SHA256" ]; then
        echo "    Checksum mismatch — falling back to baseline kernel."
        $BB cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
        $BB rm -rf "$BUILD_DIR"
        return 0
    fi

    echo "    Extracting..."
    $BB tar xJf "$TARBALL" -C "$BUILD_DIR" --strip-components=1 \
        --one-top-level="linux-${KERNEL_VER}" 2>/dev/null
    SRC="$BUILD_DIR/linux-${KERNEL_VER}"

    # Merge base x86_64 config with machine profile.
    echo "    Configuring..."
    $BB cp /usr/share/kominka/kernel.config "$SRC/.config"
    "$SRC/scripts/kconfig/merge_config.sh" -m "$SRC/.config" "$PROFILE_CFG" \
        2>/dev/null
    make -C "$SRC" ARCH=x86_64 olddefconfig 2>/dev/null

    # Build.
    NPROC=$(nproc 2>/dev/null || echo 4)
    echo "    Building kernel (this takes 10-20 minutes on $NPROC cores)..."
    echo "    Output: $MNT/boot/EFI/BOOT/BOOTX64.EFI"
    echo ""

    if make -C "$SRC" ARCH=x86_64 -j"$NPROC" bzImage; then
        $BB cp "$SRC/arch/x86/boot/bzImage" "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
        # Save the config used for this build.
        $BB cp "$SRC/.config" "$MNT/usr/share/kominka/kernel.config" 2>/dev/null || true
        echo ""
        echo "    Kernel built and installed."
    else
        echo ""
        echo "    Build failed — falling back to baseline kernel."
        $BB cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
    fi

    # Clean up ~1GB of object files; keep only the installed kernel.
    echo "    Cleaning up build directory..."
    $BB rm -rf "$BUILD_DIR"
}

# ── Disk helpers ──────────────────────────────────────────────────────────────

list_disks() {
    for dev in /sys/block/*; do
        name=$($BB basename "$dev")
        case "$name" in
            loop*|ram*|dm-*) continue ;;
        esac
        size=$($BB cat "$dev/size" 2>/dev/null) || continue
        size_mb=$((size / 2048))
        [ "$size_mb" -gt 0 ] || continue
        model=$($BB cat "$dev/device/model" 2>/dev/null) || model=""
        model=$($BB echo "$model" | $BB sed 's/ *$//')
        $BB printf "  /dev/%-10s %6d MB  %s\n" "$name" "$size_mb" "$model"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

setup_network
detect_machine

echo ""
echo "Available disks:"
echo ""
list_disks
echo ""

$BB printf "Install to (e.g. /dev/sda): "
read -r DISK

if [ -z "$DISK" ]; then
    echo "Aborted."
    exit 0
fi

if [ ! -b "$DISK" ]; then
    echo "error: $DISK is not a block device"
    exit 1
fi

size=$($BB cat "/sys/block/$($BB basename "$DISK")/size" 2>/dev/null) || size=0
size_mb=$((size / 2048))
root_mb=$((size_mb - 256 - 8192))

echo ""
echo "WARNING: all data on $DISK will be destroyed."
echo ""
echo "  Partition layout (MBR):"
echo "    ${DISK}1   256M   EFI System (FAT32)   /boot"
echo "    ${DISK}2     8G   Linux swap"
$BB printf "    ${DISK}3  %4dM   Linux (ext4)          /\n" "$root_mb"
echo ""
$BB printf "Continue? [y/N] "
read -r ans
case "$ans" in
    y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo ""
echo "==> Partitioning $DISK (MBR)"
$BB dd if=/dev/zero of="$DISK" bs=1M count=1 2>/dev/null

$BB fdisk "$DISK" <<'FDISK'
o
n
p
1

+256M
t
ef
n
p
2

+8G
t
2
82
n
p
3



w
FDISK

$BB sleep 1

# Determine partition device names.
case "$DISK" in
    *nvme*|*mmcblk*) P="${DISK}p" ;;
    *)               P="${DISK}" ;;
esac

echo "==> Formatting partitions"
mkfs.vfat -F32 -n KOMINKA_EFI "${P}1"
$BB mkswap -L KOMINKA_SWAP "${P}2"
mkfs.ext4 -q -L KOMINKA_ROOT "${P}3"

echo "==> Mounting target"
$BB mkdir -p "$MNT"
$BB mount "${P}3" "$MNT"
$BB mkdir -p "$MNT/boot"
$BB mount "${P}1" "$MNT/boot"

echo "==> Copying rootfs"
for dir in usr etc var root; do
    [ -d "/$dir" ] && $BB cp -a "/$dir" "$MNT/"
done
$BB mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/mnt"
$BB ln -sf usr/bin "$MNT/bin"
$BB ln -sf usr/bin "$MNT/sbin"
$BB ln -sf usr/lib "$MNT/lib"

# Remove installer-only files from target.
$BB rm -f "$MNT/usr/bin/pm-install"

echo "==> Installing kernel"
install_kernel

echo "==> Writing fstab"
$BB cat > "$MNT/etc/fstab" <<'EOF'
LABEL=KOMINKA_ROOT  /      ext4  defaults  0 1
LABEL=KOMINKA_EFI   /boot  vfat  defaults  0 2
LABEL=KOMINKA_SWAP  none   swap  defaults  0 0
EOF

echo ""
echo "==> Setting up user account"
echo ""
$BB printf "Username: "
read -r NEW_USER

if [ -n "$NEW_USER" ]; then
    $BB grep -q '^wheel:' "$MNT/etc/group" || \
        echo "wheel:x:10:" >> "$MNT/etc/group"

    echo "${NEW_USER}:x:1000:1000:${NEW_USER}:/home/${NEW_USER}:/bin/sh" \
        >> "$MNT/etc/passwd"
    echo "${NEW_USER}:!:14871::::::" >> "$MNT/etc/shadow"

    if $BB grep -q "^wheel:.*:$" "$MNT/etc/group"; then
        $BB sed -i "s/^wheel:\(.*\):$/wheel:\1:${NEW_USER}/" "$MNT/etc/group"
    else
        $BB sed -i "s/^wheel:\(.*\)/wheel:\1,${NEW_USER}/" "$MNT/etc/group"
    fi
    echo "${NEW_USER}:x:1000:" >> "$MNT/etc/group"

    $BB mkdir -p "$MNT/home/${NEW_USER}"
    $BB chown 1000:1000 "$MNT/home/${NEW_USER}"

    echo ""
    echo "Set password for ${NEW_USER}:"
    $BB chroot "$MNT" /usr/bin/busybox passwd "$NEW_USER"
    echo ""
    echo "  User '${NEW_USER}' created (wheel group, sudo access)."
else
    echo "  Skipped — root-only system."
fi

echo ""
echo "==> WiFi setup"
WLAN=""
for _d in /sys/class/net/*/wireless; do
    [ -d "$_d" ] && WLAN=$($BB basename $($BB dirname "$_d")) && break
done

if [ -n "$WLAN" ]; then
    # If WiFi was already configured for download, offer to reuse.
    if [ -f /etc/wifi.conf ]; then
        $BB printf "Reuse WiFi config from this session on installed system? [Y/n] "
        read -r _ans
        case "$_ans" in
            n|N) wifi-setup --target "$MNT" ;;
            *)
                $BB cp /etc/wifi.conf "$MNT/etc/wifi.conf"
                $BB cp /etc/wpa_supplicant.conf "$MNT/etc/wpa_supplicant.conf" 2>/dev/null || true
                $BB chmod 600 "$MNT/etc/wifi.conf" "$MNT/etc/wpa_supplicant.conf" 2>/dev/null || true
                ;;
        esac
    else
        $BB printf "Wireless interface %s detected. Configure WiFi? [y/N] " "$WLAN"
        read -r _ans
        case "$_ans" in
            y|Y) wifi-setup --target "$MNT" ;;
        esac
    fi

    if [ -f "$MNT/etc/wifi.conf" ]; then
        $BB mkdir -p "$MNT/var/service"
        $BB ln -sf /etc/sv/wifi "$MNT/var/service/wifi"
    fi
fi

echo ""
echo "==> Unmounting"
$BB umount "$MNT/boot"
$BB umount "$MNT"

echo ""
echo "Done! Kominka Linux installed to $DISK."
[ -n "$MACHINE_NAME" ] && echo "Kernel: $MACHINE_PROFILE (built for $MACHINE_NAME)"
echo "Remove installer media and reboot."
