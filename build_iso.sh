#!/bin/sh
# Build a bootable Kominka Linux installer disk image.
# Runs inside Docker with --privileged (needs losetup).
#
# Inputs (from Docker image layers):
#   /rootfs         - Kominka rootfs (from kominka-boot)
#   /ysh-bin/       - ysh binary
#   /ysh-libs/      - ysh shared libs
#   /boot/Image     - kernel (from kominka-kernel)
#   /install.sh     - installer script
#
# Output (written to /out):
#   kominka-installer.img - dd-able disk image (GPT: EFI + ext4 root)

set -eu

OUT=/out
IMG="$OUT/kominka-installer.img"
ROOTFS=/mnt

cleanup() {
    set +e
    umount -R "$ROOTFS" 2>/dev/null
    [ -n "${LOOP_EFI:-}" ]  && losetup -d "$LOOP_EFI"  2>/dev/null
    [ -n "${LOOP_ROOT:-}" ] && losetup -d "$LOOP_ROOT" 2>/dev/null
}
trap cleanup EXIT

echo "==> Preparing rootfs"

# Install ysh (same as build_image.sh).
cp /ysh-bin/oils-for-unix /rootfs/usr/bin/oils-for-unix
cp /ysh-libs/libstdc++.so.6 /ysh-libs/libgcc_s.so.1 \
   /ysh-libs/libreadline.so.8 /ysh-libs/libtinfo.so.6 \
   /ysh-libs/libc.so.6 /ysh-libs/libm.so.6 \
   /rootfs/usr/lib/
cp /ysh-libs/ld-linux-aarch64.so.1 /rootfs/usr/lib/ld-linux-aarch64.so.1
ln -sf oils-for-unix /rootfs/usr/bin/ysh
ln -sf oils-for-unix /rootfs/usr/bin/osh
ln -sf oils-for-unix /rootfs/usr/bin/sh

# Add mkfs.ext4 + mkfs.vfat and their shared lib dependencies.
# The rootfs already has Debian's glibc (for ysh), so Debian binaries work.
cp /sbin/mke2fs /rootfs/usr/sbin/mkfs.ext4
cp /sbin/mkfs.fat /rootfs/usr/sbin/mkfs.vfat
for bin in /sbin/mke2fs /sbin/mkfs.fat; do
    ldd "$bin" 2>/dev/null | awk '/=>/{print $3}' | while read -r lib; do
        cp -n "$lib" /rootfs/usr/lib/ 2>/dev/null || true
    done
done

# Add installer script and kernel (on the rootfs, not the ESP, so
# install.sh can access it without mounting the installer's ESP).
cp /install.sh /rootfs/usr/bin/pm-install
chmod +x /rootfs/usr/bin/pm-install
mkdir -p /rootfs/usr/share/kominka
cp /boot/Image /rootfs/usr/share/kominka/Image

# Use busybox init with baseinit rc scripts (same as build_image.sh).
cat > /rootfs/etc/inittab <<'INITTAB'
::sysinit:/lib/init/rc.boot
::restart:/sbin/init
::shutdown:/lib/init/rc.shutdown
::respawn:runsvdir -P /var/service
INITTAB

# Allow root login with no password (installer).
sed -i 's|^root:!:|root::|' /rootfs/etc/shadow

mkdir -p /rootfs/var/service
for svc in mdev syslogd getty-hvc0 udhcpc; do
    [ -d /rootfs/etc/sv/$svc ] && ln -sf "/etc/sv/$svc" "/rootfs/var/service/$svc"
done

echo "kominka-installer" > /rootfs/etc/hostname

cat >> /rootfs/etc/profile <<'PROFILE'

# Kominka package manager.
export KOMINKA_PATH=/packages
export KOMINKA_ROOT=/
PROFILE

# Size partitions to fit contents.
# ESP: kernel Image + FAT32 overhead. FAT32 needs ~34M minimum to avoid
#   cluster warnings, so we use max(kernel + 4M, 34M).
# Root: rootfs + ext4 overhead (~20% for journal, inodes, superblocks).
# GPT: 1M alignment at start, 1M backup table at end.
kernel_mb=$(( $(stat -c%s /boot/Image) / 1048576 + 1 ))
efi_min=$(( kernel_mb + 4 ))
efi_mb=$(( efi_min > 34 ? efi_min : 34 ))
rootfs_mb=$(du -sm /rootfs | awk '{print $1}')
root_mb=$(( rootfs_mb * 120 / 100 + 4 ))
img_mb=$(( 1 + efi_mb + root_mb + 1 ))

echo "==> Sizing: EFI=${efi_mb}M  root=${root_mb}M (${rootfs_mb}M content)  total=${img_mb}M"

rm -f "$IMG"
truncate -s "${img_mb}M" "$IMG"

sgdisk \
    -n 1:2048:+${efi_mb}M  -t 1:ef00 \
    -n 2:0:0               -t 2:8300 \
    "$IMG"

eval "$(sgdisk -p "$IMG" | awk '/^ *[12] /{
    printf "P%d_START=%d\nP%d_END=%d\n", $1, $2, $1, $3
}')"

efi_off=$((P1_START * 512))
efi_size=$(( (P1_END - P1_START + 1) * 512 ))
root_off=$((P2_START * 512))
root_size=$(( (P2_END - P2_START + 1) * 512 ))

LOOP_EFI=$(losetup  --find --show --offset "$efi_off"  --sizelimit "$efi_size"  "$IMG")
LOOP_ROOT=$(losetup --find --show --offset "$root_off" --sizelimit "$root_size" "$IMG")

echo "==> Formatting partitions"
mkfs.vfat -F32 -n KOMINKA_EFI "$LOOP_EFI"
mkfs.ext4 -q -m 0 -L KOMINKA_ROOT "$LOOP_ROOT"

echo "==> Mounting"
mount "$LOOP_ROOT" "$ROOTFS"
mkdir -p "$ROOTFS/boot"
mount "$LOOP_EFI" "$ROOTFS/boot"

echo "==> Installing rootfs"
cp -a /rootfs/. "$ROOTFS/"

echo "==> Installing kernel to EFI partition"
mkdir -p "$ROOTFS/boot/EFI/BOOT"
cp /boot/Image "$ROOTFS/boot/EFI/BOOT/BOOTAA64.EFI"

# vfkit requires --initrd even when the kernel doesn't need one.
echo "==> Creating empty initramfs"
echo | cpio -o -H newc 2>/dev/null | gzip > "$OUT/initramfs.img"

echo "==> Unmounting"
umount "$ROOTFS/boot"
umount "$ROOTFS"

echo "==> Done"
echo "  kominka-installer.img  $(du -h "$IMG" | cut -f1)"
echo ""
echo "  To flash:  dd if=kominka-installer.img of=/dev/sdX bs=4M status=progress"
