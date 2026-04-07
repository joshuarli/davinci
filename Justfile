set shell := ["sh", "-c"]

disk_img := justfile_directory() / "disk.img"
kernel := justfile_directory() / "Image"
initramfs := justfile_directory() / "initramfs.img"

builder_image := "kiss-boot"

default:
    @just --list

# Build disk image and boot VM
test: build boot

# Build Docker image, then create disk image
build: _docker-build _disk-image

_docker-build:
    @command -v docker >/dev/null || { echo "error: docker required"; exit 1; }
    docker build -t {{ builder_image }} -f Dockerfile.boot .

_disk-image:
    docker run --rm --privileged \
        -v "{{ justfile_directory() }}":/out \
        {{ builder_image }} \
        sh /build_image.sh

# Boot the disk image in vfkit (interactive serial console)
boot:
    @command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
    @test -f "{{ kernel }}" || { echo "error: Image not found — run 'just build' first"; exit 1; }
    @test -f "{{ initramfs }}" || { echo "error: initramfs.img not found"; exit 1; }
    @test -f "{{ disk_img }}" || { echo "error: disk.img not found"; exit 1; }
    -@pkill vfkit 2>/dev/null; sleep 0.5
    vfkit \
        --bootloader "linux,kernel={{ kernel }},initrd={{ initramfs }},cmdline=root=/dev/vda3 rw console=hvc0 loglevel=4" \
        --cpus 4 --memory 4096 \
        --device virtio-blk,path={{ disk_img }} \
        --device virtio-net,nat \
        --device virtio-serial,stdio

# Boot with serial output to log file (for non-interactive use)
boot-log:
    @command -v vfkit >/dev/null || { echo "error: vfkit required — brew install vfkit"; exit 1; }
    @test -f "{{ kernel }}" || { echo "error: Image not found — run 'just build' first"; exit 1; }
    -@pkill vfkit 2>/dev/null; sleep 0.5
    vfkit \
        --bootloader "linux,kernel={{ kernel }},initrd={{ initramfs }},cmdline=root=/dev/vda3 rw console=hvc0 loglevel=4" \
        --cpus 4 --memory 4096 \
        --device virtio-blk,path={{ disk_img }} \
        --device virtio-net,nat \
        --device virtio-serial,logFilePath=/tmp/kiss-serial.log &
    @sleep 3 && echo "VM started. Serial log: /tmp/kiss-serial.log"

# Stop the VM
stop:
    -@pkill vfkit 2>/dev/null && echo "VM stopped" || echo "No VM running"

# Remove build artifacts
clean:
    rm -f disk.img vmlinuz Image initramfs.img
