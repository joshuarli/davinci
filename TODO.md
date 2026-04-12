# TODO

## System

- `hwclock --hctosys` in rc.boot for hardware clock sync on real hardware
- DNS: /etc/resolv.conf is ephemeral (udhcpc overwrites) — consider persisting
  nameservers across reboots via a hook or static fallback
- Log rotation: syslogd rotates to /var/log/messages — no rotation configured;
  add logrotate or busybox syslogd `-s` size cap
- Investigate: is there a way to have zig cc emit `armv8.2-a+crypto` for builds
  that want LSE atomics + crypto without the GCC-specific flag format?

---

## Before first real-hardware ISO (Dell XPS 13 9343, x86_64)

### 1. Outstanding package builds (server has stale versions)

These packages have been updated locally but not yet rebuilt and uploaded:

| Package     | Old rel | New rel | What changed |
|-------------|---------|---------|--------------|
| busybox     | 4       | 7       | Ash removed, major applet trim, utmp disabled |
| ysh         | 2       | 3       | Adds /usr/bin/sh → ysh (critical: /bin/sh broken without it) |
| sudo-rs     | 1       | 2       | PAM enabled, NOPASSWD removed |
| linux       | 1       | 2       | Security hardening (coredump off, io_uring off, slab hardening) |

New packages that have never been built:

- `libnl` — netlink library (dep of wpa_supplicant)
- `wpa_supplicant` — WiFi authentication daemon
- `wifi` — wifi-setup script + runit service + action.sh

The liveiso package now depends on `wifi`, which depends on the above.
Nothing will build until these are in the server.

### 2. Kernel: missing drivers for XPS 13 9343 hardware

The current x86_64 kernel config covers VM + basic real hardware well
(xHCI, USB HID, AHCI, NVMe, EFI stub) but is missing:

**WiFi — iwlwifi (Intel Wireless 7265, used by XPS 13 9343):**
```
CONFIG_CFG80211=y          # 802.11 kernel framework
CONFIG_MAC80211=y          # 802.11 MAC layer
CONFIG_IWLWIFI=y           # Intel wireless driver base
CONFIG_IWLMVM=y            # 7265 uses MVM firmware (not DVM)
```

**ACPI — essential for any laptop:**
```
CONFIG_ACPI=y
CONFIG_ACPI_BUTTON=y       # power/lid button events
CONFIG_ACPI_BATTERY=y      # battery status
CONFIG_ACPI_AC=y           # AC adapter detection
CONFIG_ACPI_THERMAL=y      # thermal zones
CONFIG_ACPI_FAN=y
```

**Power management (suspend/resume, throttling):**
```
CONFIG_PM=y
CONFIG_SUSPEND=y
CONFIG_PM_SLEEP=y
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_GOV_ONDEMAND=y
CONFIG_INTEL_IDLE=y
CONFIG_X86_INTEL_PSTATE=y
```

**Intel i915 graphics (internal display):**
```
CONFIG_DRM=y
CONFIG_DRM_I915=y
CONFIG_DRM_FBDEV_EMULATION=y
```

**I2C bus + touchpad (XPS 13 uses I2C-connected Cypress/Synaptics):**
```
CONFIG_I2C=y
CONFIG_I2C_I801=y          # Intel SMBus/I2C controller
CONFIG_X86_INTEL_LPSS=y    # Low Power Subsystem (LPSS provides I2C)
CONFIG_I2C_HID=y
CONFIG_I2C_HID_ACPI=y
CONFIG_MOUSE_PS2_SYNAPTICS=y
```

**Firmware loader (needed by iwlwifi to load .ucode blobs at boot):**
```
CONFIG_FW_LOADER=y
CONFIG_EXTRA_FIRMWARE=""   # or embed directly via EXTRA_FIRMWARE
CONFIG_EXTRA_FIRMWARE_DIR="/lib/firmware"
```

### 3. WiFi firmware (linux-firmware, non-free)

iwlwifi will load but silently fail without its firmware blob.
The XPS 13 9343 uses Intel 7265, which needs:
```
/lib/firmware/iwlwifi-7265D-29.ucode   (or highest available rev)
/lib/firmware/iwlwifi-7265-17.ucode    (fallback)
```

These come from the `linux-firmware` package (GPL + proprietary blobs).
Options:
- New `linux-firmware` package sourced from kernel.org/firmware/
- Minimal `iwlwifi-firmware` package with just the 7265 blobs
- Bundle in the live ISO at `/lib/firmware/` without a PKGBUILD

The blobs are ~500KB each. Not optional — without them WiFi won't work.

### 4. Installer: hardcoded BOOTAA64.EFI

`install.sh` unconditionally writes to `EFI/BOOT/BOOTAA64.EFI`.
For x86_64 this must be `EFI/BOOT/BOOTX64.EFI`.

Fix is one-liner — detect arch at runtime:
```sh
case "$(uname -m)" in
    x86_64)  EFI_NAME=BOOTX64.EFI ;;
    aarch64) EFI_NAME=BOOTAA64.EFI ;;
esac
cp /usr/share/kominka/Image "$MNT/boot/EFI/BOOT/$EFI_NAME"
```

### 5. Self-hosting verification (do before real hardware)

Boot a VM, run `pm i git` or `pm b curl` from inside the running system.
This confirms the package manager, index fetching, and dep resolution all
work on a live Kominka system before trusting the hardware install.

---

## Infrastructure

- Deploy repository server publicly (VPS/fly.io) so build-package.yml
  can upload directly from CI instead of saving artifacts for manual upload.
  Once done: remove the `|| true` from pm p in build-package.yml and drop
  the artifact-save workaround.

- Package signing (v2): per REPOSITORY.md design.
