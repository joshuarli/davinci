KERNEL_IMAGE    := kominka-kernel
INSTALLER_IMAGE := kominka-iso
INSTALLER_IMG   := kominka-installer.img
KERNEL          := Image
INITRAMFS       := initramfs.img
TARGET_IMG      := target.img

VFKIT_CMDLINE := root=/dev/vda2 rw console=hvc0 loglevel=4

PACKAGES_DIR := $(realpath packages)
REPO_ENV     := $(HOME)/d/repo/.env

# Source REPO_URL from .env so docker build can reach the repo server.
# The server runs on the host; --network=host makes localhost:3000 reachable.
REPO_URL := $(shell grep '^KOMINKA_REPO=' $(REPO_ENV) 2>/dev/null | cut -d= -f2-)

.PHONY: core kernel iso boot boot-installer stop test clean

core:
	docker build --build-context packages=$(PACKAGES_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t kominka:core .

kernel:
	docker build --build-context packages=$(PACKAGES_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

iso: core
	docker build --build-context packages=$(PACKAGES_DIR) \
		--network=host \
		--build-arg REPO_URL=$(REPO_URL) \
		-t $(INSTALLER_IMAGE) -f Dockerfile.iso .
	docker run --rm --privileged -v "$(CURDIR)":/out $(INSTALLER_IMAGE)

$(KERNEL): Dockerfile.linux packages/linux/PKGBUILD.ysh
	$(MAKE) kernel

$(INSTALLER_IMG): Dockerfile.iso build_iso.sh install.sh Dockerfile pm.ysh
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

# ── Package rebuild targets ───────────────────────────────────────────────────
# Source all secrets from ~/d/repo/.env and override KOMINKA_REPO to use
# host.docker.internal (Docker's way to reach the host from a container).

DOCKER_RUN := docker run --rm \
	-v $(PACKAGES_DIR):/packages:ro \
	-v $(CURDIR)/pm.ysh:/usr/bin/pm:ro \
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

# Build with Debian GCC — for packages that need gcc (glibc, git, strace...).
# Usage: make rebuild-glibc-debian
rebuild-%-debian:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	docker build --build-context packages=$(PACKAGES_DIR) -t kominka-debian-builder -f Dockerfile.glibc .
	$(DOCKER_RUN) -e KOMINKA_ROOT=/kominka-root kominka-debian-builder sh -c '\
		db=/kominka-root/var/db/kominka/installed; \
		for tool in make bison m4; do \
			mkdir -p "$$db/$$tool"; \
			printf "system 1\n" > "$$db/$$tool/version"; \
			printf "#!/bin/sh\n:\n" > "$$db/$$tool/build"; \
			chmod +x "$$db/$$tool/build"; \
			touch "$$db/$$tool/manifest"; \
		done; \
		pm b "$*" && pm p "$*" || true'

# Build with zig cc in kominka:core. Usage: make rebuild-curl
rebuild-%:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	$(DOCKER_RUN) kominka:core sh -c 'pm b "$*"; ldconfig 2>/dev/null; pm p "$*" || true'
