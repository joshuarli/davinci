#!/usr/bin/busybox sh
# Kominka Linux installer.
# Partitions a disk, formats filesystems, and copies the live rootfs into place.
#
# Partition layout (MBR via busybox fdisk):
#   1: EFI System (256M, FAT32, type 0xEF)  -> /boot
#   2: Linux swap  (8G, type 0x82)
#   3: Linux root  (rest, ext4, type 0x83)

set -eu

echo "Kominka Linux Installer"
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
mkfs.vfat -F32 -n KOMINKA_EFI "${P}1"
/usr/bin/busybox mkswap -L KOMINKA_SWAP "${P}2"
mkfs.ext4 -q -L KOMINKA_ROOT "${P}3"

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
/usr/bin/busybox rm -f "$MNT/usr/bin/pm-install"
/usr/bin/busybox rm -rf "$MNT/usr/share/kominka"

echo "==> Installing kernel"
/usr/bin/busybox mkdir -p "$MNT/boot/EFI/BOOT"
/usr/bin/busybox cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTAA64.EFI"

echo "==> Writing fstab"
/usr/bin/busybox cat > "$MNT/etc/fstab" <<'EOF'
LABEL=KOMINKA_ROOT  /      ext4  defaults  0 1
LABEL=KOMINKA_EFI   /boot  vfat  defaults  0 2
LABEL=KOMINKA_SWAP  none   swap  defaults  0 0
EOF

echo "==> Setting up user account"
echo ""
/usr/bin/busybox printf "Username: "
read -r NEW_USER

if [ -n "$NEW_USER" ]; then
    # Create wheel group if missing.
    /usr/bin/busybox grep -q '^wheel:' "$MNT/etc/group" || \
        echo "wheel:x:10:" >> "$MNT/etc/group"

    # Add user with home directory, default shell, and wheel group.
    echo "${NEW_USER}:x:1000:1000:${NEW_USER}:/home/${NEW_USER}:/bin/sh" >> "$MNT/etc/passwd"
    echo "${NEW_USER}:!:14871::::::" >> "$MNT/etc/shadow"

    # Add user to wheel group.
    if /usr/bin/busybox grep -q "^wheel:.*:$" "$MNT/etc/group"; then
        /usr/bin/busybox sed -i "s/^wheel:\(.*\):$/wheel:\1:${NEW_USER}/" "$MNT/etc/group"
    else
        /usr/bin/busybox sed -i "s/^wheel:\(.*\)/wheel:\1,${NEW_USER}/" "$MNT/etc/group"
    fi

    # Create user's primary group.
    echo "${NEW_USER}:x:1000:" >> "$MNT/etc/group"

    # Create home directory.
    /usr/bin/busybox mkdir -p "$MNT/home/${NEW_USER}"
    /usr/bin/busybox chown 1000:1000 "$MNT/home/${NEW_USER}"

    # Set password.
    echo ""
    echo "Set password for ${NEW_USER}:"
    # chroot into the target to use busybox passwd.
    /usr/bin/busybox chroot "$MNT" /usr/bin/busybox passwd "$NEW_USER"

    echo ""
    echo "  User '${NEW_USER}' created (wheel group, sudo access)."
else
    echo "  Skipped — root-only system."
fi

echo ""
echo "==> WiFi setup"
WLAN=""
for _d in /sys/class/net/*/wireless; do
    [ -d "$_d" ] && WLAN=$(/usr/bin/busybox basename $(/usr/bin/busybox dirname "$_d")) && break
done

if [ -n "$WLAN" ]; then
    /usr/bin/busybox printf "Wireless interface %s detected. Configure WiFi? [y/N] " "$WLAN"
    read -r _ans
    case "$_ans" in
        y|Y)
            # wifi-setup writes /etc/wifi.conf and /etc/wpa_supplicant.conf
            # directly into the target via --target.  It also enables the
            # wifi runit service by creating the symlink in /var/service.
            wifi-setup --target "$MNT"
            # Enable wifi service on the installed system.
            /usr/bin/busybox mkdir -p "$MNT/var/service"
            /usr/bin/busybox ln -sf /etc/sv/wifi "$MNT/var/service/wifi"
            ;;
    esac
fi

echo ""
echo "==> Unmounting"
/usr/bin/busybox umount "$MNT/boot"
/usr/bin/busybox umount "$MNT"

echo ""
echo "Done! Kominka Linux installed to $DISK."
echo "Remove installer media and reboot."
