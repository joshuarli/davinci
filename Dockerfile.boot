# Multi-stage build: ysh -> KISS packages -> disk image builder
#
# Stage 1: Build ysh from source
# Stage 2: Build minimal KISS rootfs with pm.ysh
# Stage 3: Assemble GPT disk image (rootfs only, no kernel)
#
# Kernel is built separately via Dockerfile.linux.
#
# Usage:
#   docker build -t kiss-boot -f Dockerfile.boot .
#   docker run --rm --privileged -v "$(pwd)":/out kiss-boot sh /build_image.sh

FROM alpine:latest AS ysh-builder

RUN apk add --no-cache build-base readline-dev curl tar

RUN curl -fLo /tmp/oils.tar.gz \
        https://oils.pub/download/oils-for-unix-0.37.0.tar.gz && \
    cd /tmp && tar xzf oils.tar.gz && \
    cd oils-for-unix-* && \
    ./configure && \
    _build/oils.sh && \
    ./install

FROM alpine:latest AS pkg-builder

COPY --from=ysh-builder /usr/local/bin/oils-for-unix /usr/local/bin/oils-for-unix
RUN ln -s oils-for-unix /usr/local/bin/osh && \
    ln -s oils-for-unix /usr/local/bin/ysh

RUN apk add --no-cache \
    coreutils findutils grep sed gawk diffutils \
    curl git openssl \
    build-base gcc g++ musl-dev linux-headers \
    make patch bison flex m4 texinfo \
    perl gzip bzip2 xz zlib-dev zstd \
    automake autoconf python3 \
    gmp-dev mpfr-dev mpc1-dev \
    tar

COPY pm.ysh /usr/bin/kiss
RUN chmod +x /usr/bin/kiss

COPY tests/fixtures/repo /home/kiss/repo
COPY tests/fixtures/sources /home/kiss/sources

RUN find /home/kiss/repo -name build -exec chmod +x {} + && \
    find /home/kiss/repo -name post-install -exec chmod +x {} +

RUN mkdir -p /kiss-root/var/db/kiss/installed /kiss-root/var/db/kiss/choices

ENV KISS_PATH=/home/kiss/repo \
    KISS_ROOT=/kiss-root \
    KISS_COMPRESS=gz \
    KISS_COLOR=0 \
    KISS_PROMPT=0 \
    KISS_STRIP=0 \
    KISS_FORCE=1 \
    LOGNAME=root \
    HOME=/root \
    CC=gcc \
    CXX=g++ \
    PKG_CONFIG_PATH=/kiss-root/usr/lib/pkgconfig \
    CPPFLAGS="-I/kiss-root/usr/include" \
    LDFLAGS="-L/kiss-root/usr/lib"

WORKDIR /home/kiss

# Build minimal bootable system: baselayout + musl + busybox
# (linux-headers and make are build-time deps for busybox)
RUN ysh /usr/bin/kiss b baselayout musl linux-headers make busybox

FROM alpine:latest

RUN apk add --no-cache \
    e2fsprogs dosfstools sgdisk util-linux

COPY --from=pkg-builder /kiss-root /rootfs
COPY --from=ysh-builder /usr/local/bin/oils-for-unix /ysh-bin/oils-for-unix

# ysh needs these Alpine shared libs at runtime.
COPY --from=ysh-builder /lib/ld-musl-aarch64.so.1 /ysh-libs/ld-musl-aarch64.so.1
COPY --from=ysh-builder /usr/lib/libstdc++.so.6 /ysh-libs/libstdc++.so.6
COPY --from=ysh-builder /usr/lib/libgcc_s.so.1 /ysh-libs/libgcc_s.so.1
COPY --from=ysh-builder /usr/lib/libreadline.so.8 /ysh-libs/libreadline.so.8
COPY --from=ysh-builder /usr/lib/libncursesw.so.6 /ysh-libs/libncursesw.so.6

COPY build_image.sh /build_image.sh
