KERNEL_IMAGE    := kominka-kernel
INSTALLER_IMAGE := kominka-iso
INSTALLER_IMG   := kominka-installer.img
KERNEL          := Image
INITRAMFS       := initramfs.img
TARGET_IMG      := target.img

VFKIT_CMDLINE := root=/dev/vda2 rw console=hvc0 loglevel=4

REPO_FILES := $(wildcard tests/fixtures/repo/*/build*) \
              $(wildcard tests/fixtures/repo/*/sources) \
              $(wildcard tests/fixtures/repo/*/files/*)

.PHONY: core kernel iso boot boot-installer stop test clean

core:
	docker build -t kominka:core .

kernel:
	docker build -t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

iso: core kernel
	docker build -t $(INSTALLER_IMAGE) -f Dockerfile.iso .
	docker run --rm --privileged -v "$(CURDIR)":/out $(INSTALLER_IMAGE)

$(KERNEL): kernel.config Dockerfile.linux
	$(MAKE) kernel

$(INSTALLER_IMG): Dockerfile.iso build_iso.sh install.sh $(KERNEL) Dockerfile pm.ysh $(REPO_FILES)
	$(MAKE) iso

boot: $(KERNEL) $(INSTALLER_IMG)
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "$(VFKIT_CMDLINE)" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(INSTALLER_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,stdio

boot-installer: $(KERNEL) $(INSTALLER_IMG)
	@command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
	@test -f $(TARGET_IMG) || truncate -s 12G $(TARGET_IMG)
	-@pkill vfkit 2>/dev/null; sleep 0.5
	vfkit \
		--kernel $(KERNEL) \
		--initrd $(INITRAMFS) \
		--kernel-cmdline "$(VFKIT_CMDLINE)" \
		--cpus 4 --memory 4096 \
		--device virtio-blk,path=$(INSTALLER_IMG) \
		--device virtio-blk,path=$(TARGET_IMG) \
		--device virtio-net,nat \
		--device virtio-serial,stdio

stop:
	-@pkill vfkit 2>/dev/null && echo "VM stopped" || echo "No VM running"

test:
	python3 -m pytest tests/ -x -q

clean:
	rm -f Image initramfs.img kominka-installer.img target.img
