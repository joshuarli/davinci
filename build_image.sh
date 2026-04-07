#!/bin/sh
# Build a bootable KISS Linux disk image.
# Runs inside Docker with --privileged (needs losetup).
#
# Outputs (written to /out):
#   disk.img        - Bootable disk image (GPT: EFI + swap + ext4 root)

set -eu

OUT=/out
DISK="$OUT/disk.img"
DISK_SIZE_MB=12288
ROOTFS=/mnt

cleanup() {
    set +e
    umount -R "$ROOTFS" 2>/dev/null
    [ -n "${LOOP_EFI:-}" ]  && losetup -d "$LOOP_EFI"  2>/dev/null
    [ -n "${LOOP_SWAP:-}" ] && losetup -d "$LOOP_SWAP" 2>/dev/null
    [ -n "${LOOP_ROOT:-}" ] && losetup -d "$LOOP_ROOT" 2>/dev/null
}
trap cleanup EXIT

echo "==> Creating ${DISK_SIZE_MB}M disk image"
rm -f "$DISK"
truncate -s "${DISK_SIZE_MB}M" "$DISK"

# GPT: EFI (256M) + swap (8G) + root (rest)
sgdisk \
    -n 1:2048:+256M  -t 1:ef00 \
    -n 2:0:+8G       -t 2:8200 \
    -n 3:0:0         -t 3:8300 \
    "$DISK"

# Compute byte offsets for loopback mounting.
# sgdisk output: "  N  start  end  ..."
eval "$(sgdisk -p "$DISK" | awk '/^ *[123] /{
    printf "P%d_START=%d\nP%d_END=%d\n", $1, $2, $1, $3
}')"

efi_off=$((P1_START * 512))
efi_size=$(( (P1_END - P1_START + 1) * 512 ))
swap_off=$((P2_START * 512))
swap_size=$(( (P2_END - P2_START + 1) * 512 ))
root_off=$((P3_START * 512))
root_size=$(( (P3_END - P3_START + 1) * 512 ))

LOOP_EFI=$(losetup  --find --show --offset "$efi_off"  --sizelimit "$efi_size"  "$DISK")
LOOP_SWAP=$(losetup --find --show --offset "$swap_off" --sizelimit "$swap_size" "$DISK")
LOOP_ROOT=$(losetup --find --show --offset "$root_off" --sizelimit "$root_size" "$DISK")

echo "==> Formatting partitions"
mkfs.vfat -F32 -n KISS_EFI "$LOOP_EFI"
mkswap -L KISS_SWAP "$LOOP_SWAP"
mkfs.ext4 -q -L KISS_ROOT "$LOOP_ROOT"

echo "==> Mounting filesystems"
mount "$LOOP_ROOT" "$ROOTFS"
mkdir -p "$ROOTFS/boot"
mount "$LOOP_EFI" "$ROOTFS/boot"

echo "==> Installing rootfs"
cp -a /rootfs/. "$ROOTFS/"

# Install ysh and its Alpine shared lib dependencies.
# Our KISS musl is older; use Alpine's musl as the dynamic linker for ysh.
cp /ysh-bin/oils-for-unix "$ROOTFS/usr/bin/oils-for-unix"
cp /ysh-libs/libstdc++.so.6 /ysh-libs/libgcc_s.so.1 \
   /ysh-libs/libreadline.so.8 /ysh-libs/libncursesw.so.6 \
   "$ROOTFS/usr/lib/"
# Replace KISS musl with Alpine's musl (ysh was built against it).
cp /ysh-libs/ld-musl-aarch64.so.1 "$ROOTFS/usr/lib/ld-musl-aarch64.so.1"
ln -sf oils-for-unix "$ROOTFS/usr/bin/ysh"
ln -sf oils-for-unix "$ROOTFS/usr/bin/osh"
# /bin/sh -> ysh so the interactive shell is ysh
ln -sf oils-for-unix "$ROOTFS/usr/bin/sh"

echo "==> Configuring system"

cat > "$ROOTFS/etc/fstab" <<'EOF'
/dev/vda3  /      ext4  defaults  0 1
/dev/vda1  /boot  vfat  defaults  0 2
/dev/vda2  none   swap  defaults  0 0
EOF

echo "kiss" > "$ROOTFS/etc/hostname"

# Minimal init: mount pseudofs, drop to shell.
# Remove busybox's init -> busybox symlink before creating the script,
# otherwise writing through the symlink corrupts the busybox binary.
rm -f "$ROOTFS/usr/bin/init"
cat > "$ROOTFS/usr/bin/init" <<'INIT'
#!/usr/bin/busybox sh
/usr/bin/busybox mount -t devtmpfs none /dev 2>/dev/null
/usr/bin/busybox mount -t proc     none /proc
/usr/bin/busybox mount -t sysfs    none /sys
/usr/bin/busybox mount -t tmpfs    none /tmp

/usr/bin/busybox hostname -F /etc/hostname

/usr/bin/busybox clear
echo "KISS Linux (built with pm.ysh)"
echo "Kernel: $(/usr/bin/busybox uname -sr)"
echo ""

exec /usr/bin/ysh
INIT
chmod 755 "$ROOTFS/usr/bin/init"

# Install kernel to EFI partition for EFISTUB boot on real hardware.
# On real hardware: EFI firmware finds /EFI/BOOT/BOOTAA64.EFI
if [ -f "$OUT/Image" ]; then
    echo "==> Installing kernel to EFI partition"
    mkdir -p "$ROOTFS/boot/EFI/BOOT"
    cp "$OUT/Image" "$ROOTFS/boot/EFI/BOOT/BOOTAA64.EFI"
else
    echo "    (no Image found — run 'make kernel' to include kernel on disk)"
fi

# vfkit requires --initrd even when the kernel doesn't need one.
echo "==> Creating empty initramfs"
echo | cpio -o -H newc 2>/dev/null | gzip > "$OUT/initramfs.img"

echo "==> Unmounting"
umount "$ROOTFS/boot"
umount "$ROOTFS"

echo "==> Done"
echo "  disk.img  $(du -h "$DISK" | cut -f1)"
