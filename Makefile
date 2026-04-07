BUILDER_IMAGE   := kiss-boot
KERNEL_IMAGE    := kiss-kernel
INSTALLER_IMAGE := kiss-iso
DISK_IMG        := disk.img
INSTALLER_IMG   := kiss-installer.img
TARGET_IMG      := target.img
KERNEL          := Image
INITRAMFS       := initramfs.img

VFKIT_CMDLINE := root=/dev/vda3 rw console=hvc0 loglevel=4

.PHONY: kernel build iso boot boot-installer boot-log test stop clean

test: boot

# Docker builds (always re-run when invoked directly; Docker layer cache
# makes rebuilds fast when nothing changed).
kernel:
	@command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
	docker build -t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

build:
	@command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
	docker build -t $(BUILDER_IMAGE) -f Dockerfile.boot .
	docker run --rm --privileged \
		-v "$(CURDIR)":/out \
		$(BUILDER_IMAGE) \
		sh /build_image.sh

iso:
	@command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
	docker build -t $(INSTALLER_IMAGE) -f Dockerfile.iso .
	docker run --rm --privileged \
		-v "$(CURDIR)":/out \
		$(INSTALLER_IMAGE)

# Auto-build missing or stale artifacts.
# Make rebuilds when source files are newer than the output.
$(KERNEL): kernel.config Dockerfile.linux
	$(MAKE) kernel

$(DISK_IMG): Dockerfile.boot build_image.sh pm.ysh
	$(MAKE) build

$(INSTALLER_IMG): Dockerfile.iso build_iso.sh install.sh $(KERNEL) $(DISK_IMG)
	$(MAKE) iso

# Boot targets — file dependencies trigger builds when artifacts are missing.
boot: $(KERNEL) $(DISK_IMG)
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "$(VFKIT_CMDLINE)" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(DISK_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,stdio

boot-installer: $(KERNEL) $(INSTALLER_IMG)
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	@test -f $(TARGET_IMG) || truncate -s 12G $(TARGET_IMG)
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "root=/dev/vda2 rw console=hvc0 loglevel=4" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(INSTALLER_IMG) \
		--device virtio-blk,path=$(TARGET_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,stdio

boot-log: $(KERNEL) $(DISK_IMG)
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "$(VFKIT_CMDLINE)" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(DISK_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,logFilePath=/tmp/kiss-serial.log &
	@sleep 3 && echo "VM started. Serial log: /tmp/kiss-serial.log"

stop:
	-@pkill vfkit 2>/dev/null && echo "VM stopped" || echo "No VM running"

clean:
	rm -f disk.img Image initramfs.img kernel-config kiss-installer.img target.img
