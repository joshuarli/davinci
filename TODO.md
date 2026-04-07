# TODO

- Add efibootmgr to userspace for managing UEFI boot entries on real hardware
- Build and package a KISS-native kernel (replace Alpine linux-virt)
- Port remaining 4 vendored packages to build.ysh (binutils, gcc, git, grub)
- Networking in rootfs (dhcp via busybox udhcpc, or static config)
- Real init system (baseinit runit services) instead of shell-as-init
