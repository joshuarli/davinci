BUILDER_IMAGE := kiss-boot
KERNEL_IMAGE  := kiss-kernel
DISK_IMG      := disk.img
KERNEL        := Image
INITRAMFS     := initramfs.img

VFKIT_CMDLINE := root=/dev/vda3 rw console=hvc0 loglevel=4

.PHONY: build kernel boot boot-log test stop clean

test: kernel build boot

build:
	@command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
	docker build -t $(BUILDER_IMAGE) -f Dockerfile.boot .
	docker run --rm --privileged \
		-v "$(CURDIR)":/out \
		$(BUILDER_IMAGE) \
		sh /build_image.sh

kernel:
	@command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
	docker build -t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

boot:
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	@test -f $(KERNEL) || { echo "error: Image not found — run 'make kernel' first"; exit 1; }
	@test -f $(DISK_IMG) || { echo "error: disk.img not found — run 'make build' first"; exit 1; }
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "$(VFKIT_CMDLINE)" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(DISK_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,stdio

boot-log:
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	@test -f $(KERNEL) || { echo "error: Image not found — run 'make kernel' first"; exit 1; }
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
	rm -f disk.img Image initramfs.img kernel-config
