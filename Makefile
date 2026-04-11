KERNEL_IMAGE    := kominka-kernel
INSTALLER_IMAGE := kominka-iso
INSTALLER_IMG   := kominka-installer.img
KERNEL          := Image
INITRAMFS       := initramfs.img
TARGET_IMG      := target.img

VFKIT_CMDLINE := root=/dev/vda2 rw console=hvc0 loglevel=4

PACKAGES_DIR := $(realpath packages)

REPO_FILES := $(wildcard packages/*/PKGBUILD.ysh) \
              $(wildcard packages/*/build*) \
              $(wildcard packages/*/sources) \
              $(wildcard packages/*/files/*)

REPO_ENV := $(HOME)/d/repo/.env

DOCKER_BUILD_ENV := \
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

.PHONY: core kernel iso boot boot-installer rebuild-world stop test clean

core:
	docker build --build-context packages=$(PACKAGES_DIR) -t kominka:core .

kernel:
	docker build -t $(KERNEL_IMAGE) -f Dockerfile.linux .
	docker run --rm -v "$(CURDIR)":/out $(KERNEL_IMAGE)

iso: core kernel
	docker build --build-context packages=$(PACKAGES_DIR) -t $(INSTALLER_IMAGE) -f Dockerfile.iso .
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

rebuild-glibc:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	docker build --build-context packages=$(PACKAGES_DIR) \
		-t kominka-glibc-builder -f Dockerfile.glibc .
	docker run --rm $(DOCKER_BUILD_ENV) \
		-e KOMINKA_ROOT=/kominka-root \
		kominka-glibc-builder sh -c '\
		db=/kominka-root/var/db/kominka/installed; \
		for tool in make bison m4; do \
			mkdir -p "$$db/$$tool"; \
			printf "system 1\n" > "$$db/$$tool/version"; \
			printf "#!/bin/sh\n:\n" > "$$db/$$tool/build"; \
			chmod +x "$$db/$$tool/build"; \
			touch "$$db/$$tool/manifest"; \
		done; \
		pm b glibc; \
		pm p glibc || true'

rebuild-%:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	docker run --rm $(DOCKER_BUILD_ENV) kominka:core sh -c '\
		pm b "$*"; \
		ln -sf /usr/lib/libz.so.1.3.2 /usr/lib/libz.so.1 2>/dev/null; \
		ln -sf /usr/lib/libz.so.1.3.2 /usr/lib/libz.so 2>/dev/null; \
		ldconfig 2>/dev/null; \
		pm p "$*" || true'

rebuild-world:
	@test -f $(REPO_ENV) || { echo "error: $(REPO_ENV) not found"; exit 1; }
	@for pkg in $(PACKAGES_DIR)/*/; do \
		name=$$(basename "$$pkg"); \
		[ -f "$$pkg/PKGBUILD.ysh" ] || continue; \
		echo "==> $$name"; \
		$(MAKE) rebuild-$$name || true; \
	done

stop:
	-@pkill vfkit 2>/dev/null && echo "VM stopped" || echo "No VM running"

test:
	python3 -m pytest tests/ -x -q

clean:
	rm -f Image initramfs.img kominka-installer.img target.img
