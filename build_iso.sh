#!/bin/sh
# Build a bootable Kominka Linux installer disk image.
# Runs inside Docker with --privileged (needs losetup).
# All tools from Kominka packages (busybox, e2fsprogs, dosfstools).
#
# Output: /out/kominka-installer.img (MBR: EFI + ext4 root)
set -eu

OUT=/out
IMG="$OUT/kominka-installer.img"
MNT=/mnt

cleanup() {
    set +e
    umount "$MNT/boot" 2>/dev/null
    umount "$MNT" 2>/dev/null
    [ -n "${LOOP_EFI:-}" ]  && losetup -d "$LOOP_EFI"  2>/dev/null
    [ -n "${LOOP_ROOT:-}" ] && losetup -d "$LOOP_ROOT" 2>/dev/null
}
trap cleanup EXIT

# Size partitions to fit contents.
kernel_mb=$(( $(stat -c%s /usr/share/kominka/Image) / 1048576 + 1 ))
efi_mb=$(( kernel_mb + 4 ))
[ "$efi_mb" -lt 34 ] && efi_mb=34
rootfs_mb=$(du -sm /bin /etc /lib /sbin /usr /var /root 2>/dev/null | awk '{s+=$1} END{print s}')
root_mb=$(( rootfs_mb * 120 / 100 + 4 ))
img_mb=$(( 1 + efi_mb + root_mb + 1 ))

echo "==> Sizing: EFI=${efi_mb}M  root=${root_mb}M (${rootfs_mb}M content)  total=${img_mb}M"

rm -f "$IMG"
truncate -s "${img_mb}M" "$IMG"

# MBR partition table: partition 1 = EFI (type 0xEF), partition 2 = Linux.
# busybox fdisk with scripted input.
efi_end=$(( efi_mb * 2048 + 2047 ))
# busybox fdisk warns about ioctl on regular files — harmless.
fdisk "$IMG" <<FDISK || true
o
n
p
1
2048
$efi_end
t
ef
n
p
2
$(( efi_end + 1 ))

w
FDISK

# Calculate partition offsets from fdisk output.
eval "$(fdisk -l "$IMG" 2>/dev/null | awk '/\.img[12]/{
    gsub(/\*/, ""); n=split($0,a);
    if (++i==1) printf "P1_START=%s\nP1_END=%s\n", a[2], a[3];
    else printf "P2_START=%s\nP2_END=%s\n", a[2], a[3];
}')"

efi_off=$((P1_START * 512))
efi_size=$(( (P1_END - P1_START + 1) * 512 ))
root_off=$((P2_START * 512))
root_size=$(( (P2_END - P2_START + 1) * 512 ))

# busybox losetup: -f finds free device, -o sets offset.
# No --sizelimit support — mkfs respects the partition size from the table.
LOOP_EFI=$(losetup -f) && losetup -o "$efi_off" "$LOOP_EFI" "$IMG"
LOOP_ROOT=$(losetup -f) && losetup -o "$root_off" "$LOOP_ROOT" "$IMG"

echo "==> Formatting partitions"
mkfs.vfat -F32 -n KOMINKA_EFI "$LOOP_EFI"
mkfs.ext4 -q -m 0 -L KOMINKA_ROOT "$LOOP_ROOT"

echo "==> Mounting"
mount "$LOOP_ROOT" "$MNT"
mkdir -p "$MNT/boot"
mount "$LOOP_EFI" "$MNT/boot"

echo "==> Installing rootfs"
# Copy the live rootfs (this container IS the rootfs).
for d in bin etc lib lib64 packages root sbin usr var; do
    [ -e "/$d" ] && cp -a "/$d" "$MNT/"
done
mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT/tmp" "$MNT/home"

echo "==> Installing kernel to EFI partition"
mkdir -p "$MNT/boot/EFI/BOOT"
cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTAA64.EFI"

# vfkit requires --initrd even when the kernel doesn't need one.
echo "==> Creating empty initramfs"
echo | cpio -o -H newc 2>/dev/null | gzip > "$OUT/initramfs.img"

echo "==> Unmounting"
umount "$MNT/boot"
umount "$MNT"

echo "==> Done"
echo "  kominka-installer.img  $(du -h "$IMG" | cut -f1)"
echo ""
echo "  To flash:  dd if=kominka-installer.img of=/dev/sdX bs=4M status=progress"
