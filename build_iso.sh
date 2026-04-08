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
    busybox umount "$MNT/boot" 2>/dev/null
    busybox umount "$MNT" 2>/dev/null
    [ -n "${LOOP_EFI:-}" ]  && busybox losetup -d "$LOOP_EFI"  2>/dev/null
    [ -n "${LOOP_ROOT:-}" ] && busybox losetup -d "$LOOP_ROOT" 2>/dev/null
}
trap cleanup EXIT

# Size partitions to fit contents.
kernel_mb=$(( $(busybox stat -c%s /usr/share/kominka/Image) / 1048576 + 1 ))
efi_mb=$(( kernel_mb + 4 ))
[ "$efi_mb" -lt 34 ] && efi_mb=34
rootfs_mb=$(busybox du -sm /bin /etc /lib /sbin /usr /var /root 2>/dev/null | busybox awk '{s+=$1} END{print s}')
root_mb=$(( rootfs_mb * 120 / 100 + 4 ))
img_mb=$(( 1 + efi_mb + root_mb + 1 ))

echo "==> Sizing: EFI=${efi_mb}M  root=${root_mb}M (${rootfs_mb}M content)  total=${img_mb}M"

busybox rm -f "$IMG"
busybox truncate -s "${img_mb}M" "$IMG"

# MBR partition table: partition 1 = EFI (type 0xEF), partition 2 = Linux.
efi_end=$(( efi_mb * 2048 + 2047 ))
# busybox fdisk warns about ioctl on regular files — harmless.
busybox fdisk "$IMG" <<FDISK || true
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

# Partition offsets — we know the layout because we just created it.
P1_START=2048
P1_END=$efi_end
P2_START=$(( efi_end + 1 ))
P2_END=$(( img_mb * 2048 - 1 ))

efi_off=$((P1_START * 512))
efi_size=$(( (P1_END - P1_START + 1) * 512 ))
root_off=$((P2_START * 512))
root_size=$(( (P2_END - P2_START + 1) * 512 ))

# busybox losetup: -f finds free device, -o sets offset.
LOOP_EFI=$(busybox losetup -f) && busybox losetup -o "$efi_off" "$LOOP_EFI" "$IMG"
LOOP_ROOT=$(busybox losetup -f) && busybox losetup -o "$root_off" "$LOOP_ROOT" "$IMG"

echo "==> Formatting partitions"
# Pass explicit size since busybox losetup has no --sizelimit.
efi_blocks=$(( efi_size / 1024 ))
root_blocks=$(( root_size / 4096 ))
mkfs.vfat -F32 -n KOMINKA_EFI -S 512 -s 1 "$LOOP_EFI" "$efi_blocks"
mkfs.ext4 -q -m 0 -L KOMINKA_ROOT -b 4096 "$LOOP_ROOT" "$root_blocks"

echo "==> Mounting"
busybox mount "$LOOP_ROOT" "$MNT"
busybox mkdir -p "$MNT/boot"
busybox mount "$LOOP_EFI" "$MNT/boot"

echo "==> Installing rootfs"
for d in bin etc lib lib64 packages root sbin usr var; do
    [ -e "/$d" ] && busybox cp -a "/$d" "$MNT/"
done
busybox mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT/tmp" "$MNT/home"

echo "==> Installing kernel to EFI partition"
busybox mkdir -p "$MNT/boot/EFI/BOOT"
busybox cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/BOOTAA64.EFI"

# vfkit requires --initrd even when the kernel doesn't need one.
echo "==> Creating empty initramfs"
echo | busybox cpio -o -H newc 2>/dev/null | busybox gzip > "$OUT/initramfs.img"

echo "==> Unmounting"
busybox umount "$MNT/boot"
busybox umount "$MNT"

echo "==> Done"
echo "  kominka-installer.img  $(busybox du -h "$IMG" | busybox cut -f1)"
echo ""
echo "  To flash:  dd if=kominka-installer.img of=/dev/sdX bs=4M status=progress"
