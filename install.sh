#!/usr/bin/busybox sh
# KISS Linux installer.
# Partitions a disk, formats filesystems, and copies the live rootfs into place.
#
# Partition layout (MBR via busybox fdisk):
#   1: EFI System (256M, FAT32, type 0xEF)  -> /boot
#   2: Linux swap  (8G, type 0x82)
#   3: Linux root  (rest, ext4, type 0x83)

set -eu

echo "KISS Linux Installer"
echo ""

list_disks() {
    for dev in /sys/block/*; do
        name=$(/usr/bin/busybox basename "$dev")
        case "$name" in
            loop*|ram*|dm-*) continue ;;
        esac
        size=$(/usr/bin/busybox cat "$dev/size" 2>/dev/null) || continue
        size_mb=$((size / 2048))
        [ "$size_mb" -gt 0 ] || continue
        model=$(/usr/bin/busybox cat "$dev/device/model" 2>/dev/null) || model=""
        model=$(/usr/bin/busybox echo "$model" | /usr/bin/busybox sed 's/ *$//')
        /usr/bin/busybox printf "  /dev/%-10s %6d MB  %s\n" "$name" "$size_mb" "$model"
    done
}

echo "Available disks:"
echo ""
list_disks
echo ""

/usr/bin/busybox printf "Install to (e.g. /dev/vdb): "
read -r DISK

if [ -z "$DISK" ]; then
    echo "Aborted."
    exit 0
fi

if [ ! -b "$DISK" ]; then
    echo "error: $DISK is not a block device"
    exit 1
fi

size=$(/usr/bin/busybox cat "/sys/block/$(/usr/bin/busybox basename "$DISK")/size" 2>/dev/null) || size=0
size_mb=$((size / 2048))
root_mb=$((size_mb - 256 - 8192))

echo ""
echo "WARNING: all data on $DISK will be destroyed."
echo ""
echo "  Partition layout (MBR):"
echo "    ${DISK}1   256M   EFI System (FAT32)   /boot"
echo "    ${DISK}2     8G   Linux swap"
/usr/bin/busybox printf "    ${DISK}3  %4dM   Linux (ext4)          /\n" "$root_mb"
echo ""
/usr/bin/busybox printf "Continue? [y/N] "
read -r ans
case "$ans" in
    y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo ""
echo "==> Partitioning $DISK (MBR)"
/usr/bin/busybox dd if=/dev/zero of="$DISK" bs=1M count=1 2>/dev/null

/usr/bin/busybox fdisk "$DISK" <<'FDISK'
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

/usr/bin/busybox sleep 1

# Determine partition device names.
case "$DISK" in
    *nvme*|*mmcblk*) P="${DISK}p" ;;
    *)               P="${DISK}" ;;
esac

echo "==> Formatting partitions"
/usr/sbin/mkfs.vfat -F32 -n KISS_EFI "${P}1"
/usr/bin/busybox mkswap -L KISS_SWAP "${P}2"
/usr/sbin/mkfs.ext4 -q -L KISS_ROOT "${P}3"

echo "==> Mounting target"
MNT=/mnt/target
/usr/bin/busybox mkdir -p "$MNT"
/usr/bin/busybox mount "${P}3" "$MNT"
/usr/bin/busybox mkdir -p "$MNT/boot"
/usr/bin/busybox mount "${P}1" "$MNT/boot"

echo "==> Copying rootfs"
for dir in usr etc var root; do
    [ -d "/$dir" ] && /usr/bin/busybox cp -a "/$dir" "$MNT/"
done
/usr/bin/busybox mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/mnt"
# Merged-usr symlinks (from baselayout).
/usr/bin/busybox ln -sf usr/bin "$MNT/bin"
/usr/bin/busybox ln -sf usr/bin "$MNT/sbin"
/usr/bin/busybox ln -sf usr/lib "$MNT/lib"

# Remove installer-only files from target.
/usr/bin/busybox rm -f "$MNT/usr/bin/kiss-install"
/usr/bin/busybox rm -rf "$MNT/usr/share/kiss"

echo "==> Installing kernel"
/usr/bin/busybox mkdir -p "$MNT/boot/EFI/BOOT"
/usr/bin/busybox cp /usr/share/kiss/Image "$MNT/boot/EFI/BOOT/BOOTAA64.EFI"

echo "==> Writing fstab"
/usr/bin/busybox cat > "$MNT/etc/fstab" <<'EOF'
LABEL=KISS_ROOT  /      ext4  defaults  0 1
LABEL=KISS_EFI   /boot  vfat  defaults  0 2
LABEL=KISS_SWAP  none   swap  defaults  0 0
EOF

echo "==> Unmounting"
/usr/bin/busybox umount "$MNT/boot"
/usr/bin/busybox umount "$MNT"

echo ""
echo "Done! KISS Linux installed to $DISK."
echo "Remove installer media and reboot."
