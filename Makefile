KERNEL_IMAGE    := kominka-kernel
INSTALLER_IMAGE := kominka-iso
INSTALLER_IMG   := kominka-installer.img
KERNEL          := Image
INITRAMFS       := initramfs.img
TARGET_IMG      := target.img

KERNEL_AMD64        := Image-amd64
INITRAMFS_AMD64     := initramfs-amd64.img
INSTALLER_IMG_AMD64 := kominka-installer-amd64.img

VFKIT_CMDLINE := root=/dev/vda2 rw console=hvc0 loglevel=4
QEMU_CMDLINE  := root=/dev/vda2 rw console=ttyS0 loglevel=4

PACKAGES_DIR := $(realpath packages)
PM_DIR       := $(HOME)/d/pm
REPO_ENV     := $(HOME)/d/repo/.env

# Source REPO_URL from .env so docker build can reach the repo server.
# The server runs on the host; --network=host makes localhost:3000 reachable.
REPO_URL := $(shell grep '^KOMINKA_REPO=' $(REPO_ENV) 2>/dev/null | cut -d= -f2-)

AMD64 := --platform linux/amd64

.PHONY: core kernel iso boot boot-installer stop test clean \
        core-amd64 kernel-amd64 iso-amd64 boot-amd64 boot-installer-amd64

core:
	docker build --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t kominka:core .

core-amd64:
	docker build $(AMD64) --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t kominka:core-amd64 .

kernel:
	docker build --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

kernel-amd64:
	docker build $(AMD64) --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(KERNEL_IMAGE)-amd64 -f Dockerfile.linux .
	docker run $(AMD64) --rm -v "$(CURDIR)":/out \
		-e OUT_KERNEL=$(KERNEL_AMD64) -e OUT_INITRAMFS=$(INITRAMFS_AMD64) \
		$(KERNEL_IMAGE)-amd64

iso: core
	docker build --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(INSTALLER_IMAGE) -f Dockerfile.iso .
	docker run --rm --privileged -v "$(CURDIR)":/out $(INSTALLER_IMAGE)

iso-amd64: core-amd64
	docker build $(AMD64) --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(INSTALLER_IMAGE)-amd64 -f Dockerfile.iso .
	docker run $(AMD64) --rm --privileged -v "$(CURDIR)":/out \
		-e OUT_IMG=$(INSTALLER_IMG_AMD64) \
		$(INSTALLER_IMAGE)-amd64

$(KERNEL): Dockerfile.linux packages/linux/PKGBUILD.ysh
	$(MAKE) kernel

$(INSTALLER_IMG): Dockerfile.iso build_iso.ysh packages/liveiso/files/install.ysh Dockerfile pm.ysh
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
		--device virtio-serial,stdio \
		--device virtio-fs,sharedDir=$(PACKAGES_DIR),mountTag=packages

boot-amd64: $(KERNEL_AMD64) $(INSTALLER_IMG_AMD64)
	@command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu required — brew install qemu"; exit 1; }
	qemu-system-x86_64 \
		-M q35 -cpu qemu64 -m 4096 -smp 4 \
		-kernel $(KERNEL_AMD64) \
		-initrd $(INITRAMFS_AMD64) \
		-append "$(QEMU_CMDLINE)" \
		-drive file=$(INSTALLER_IMG_AMD64),if=virtio,format=raw \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-nographic

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

boot-installer-amd64: $(KERNEL_AMD64) $(INSTALLER_IMG_AMD64)
	@command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu required — brew install qemu"; exit 1; }
	@test -f $(TARGET_IMG) || truncate -s 12G $(TARGET_IMG)
	qemu-system-x86_64 \
		-M q35 -cpu qemu64 -m 4096 -smp 4 \
		-kernel $(KERNEL_AMD64) \
		-initrd $(INITRAMFS_AMD64) \
		-append "$(QEMU_CMDLINE)" \
		-drive file=$(INSTALLER_IMG_AMD64),if=virtio,format=raw \
		-drive file=$(TARGET_IMG),if=virtio,format=raw \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-nographic

stop:
	-@pkill vfkit 2>/dev/null && echo "VM stopped" || echo "No VM running"

test:
	python3 -m pytest tests/ -x -q

clean:
	rm -f Image initramfs.img kominka-installer.img target.img

# ── Package rebuild targets ───────────────────────────────────────────────────
# Source all secrets from ~/d/repo/.env and override KOMINKA_REPO to use
# host.docker.internal (Docker's way to reach the host from a container).

DOCKER_RUN := docker run --rm \
	-v $(PACKAGES_DIR):/packages:ro \
	-v $(PM_DIR)/pm.ysh:/usr/bin/pm:ro \
	--env-file $(REPO_ENV) \
	-e KOMINKA_REPO=http://host.docker.internal:3000 \
	-e KOMINKA_PATH=/packages \
	-e KOMINKA_COMPRESS=gz \
	-e KOMINKA_COLOR=0 \
	-e KOMINKA_PROMPT=0 \
	-e KOMINKA_FORCE=1 \
	-e KOMINKA_GET=/usr/bin/curl \
	-e KOMINKA_INSECURE=1 \
	-e LD_LIBRARY_PATH=/usr/lib \
	-e LOGNAME=root \
	-e HOME=/root

DOCKER_RUN_AMD64 := $(DOCKER_RUN) $(AMD64) -e KOMINKA_ARCH=x86_64-linux-gnu

# Pre-register Debian system tools so pm doesn't try to rebuild them.
# KOMINKA_REPO is set (host.docker.internal:3000) so other mkdeps are
# fetched from the server rather than pre-registered.
DEBIAN_SYSREG := bash -ec '\
	DB=/kominka-root/var/db/kominka/installed; \
	for tool in make bison m4 flex bc perl cmake ninja python3 glibc; do \
		mkdir -p "$$DB/$$tool"; \
		printf "system 1\n" > "$$DB/$$tool/version"; \
		printf "#!/bin/sh\n:\n" > "$$DB/$$tool/build"; \
		chmod +x "$$DB/$$tool/build"; \
		touch "$$DB/$$tool/manifest"; \
	done; \
	pm b "$(PKG)" && pm p "$(PKG)" || true'

# Build with Debian GCC — for packages that need gcc (glibc, git, strace...).
# Usage: make rebuild-git-debian
rebuild-%-debian:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	docker build --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		-t kominka-debian-builder -f Dockerfile.glibc .
	$(DOCKER_RUN) -e KOMINKA_ROOT=/kominka-root -e PKG=$* \
		kominka-debian-builder $(DEBIAN_SYSREG)

# Same but targeting x86_64. Usage: make rebuild-git-debian-amd64
rebuild-%-debian-amd64:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	docker build $(AMD64) --build-context packages=$(PACKAGES_DIR) --build-context pm=$(PM_DIR) \
		-t kominka-debian-builder-amd64 -f Dockerfile.glibc .
	$(DOCKER_RUN_AMD64) -e KOMINKA_ROOT=/kominka-root -e PKG=$* \
		kominka-debian-builder-amd64 $(DEBIAN_SYSREG)

# Build with zig cc in kominka:core. Usage: make rebuild-curl
rebuild-%:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	$(DOCKER_RUN) kominka:core sh -c 'pm b "$*"; ldconfig 2>/dev/null; pm p "$*" || true'

# Same but targeting x86_64. Usage: make rebuild-amd64-curl
rebuild-amd64-%:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	$(DOCKER_RUN_AMD64) kominka:core-amd64 sh -c 'pm b "$*"; ldconfig 2>/dev/null; pm p "$*" || true'
