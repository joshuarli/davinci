# Multi-stage build: ysh -> Kominka packages -> disk image builder
#
# Stage 1: Build ysh from source
# Stage 2: Build minimal Kominka rootfs with pm.ysh
# Stage 3: Assemble GPT disk image (rootfs only, no kernel)
#
# Kernel is built separately via Dockerfile.linux.
#
# Usage:
#   docker build -t kominka-boot -f Dockerfile.boot .
#   docker run --rm --privileged -v "$(pwd)":/out kominka-boot sh /build_image.sh

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

# Sources (~263MB tarballs, rarely change) before repo and pm.ysh.
COPY tests/fixtures/sources /home/kominka/sources
COPY tests/fixtures/repo /packages

RUN find /packages -name build -exec chmod +x {} + && \
    find /packages -name post-install -exec chmod +x {} +

RUN mkdir -p /kominka-root/var/db/kominka/installed /kominka-root/var/db/kominka/choices

ENV KOMINKA_PATH=/packages \
    KOMINKA_ROOT=/kominka-root \
    KOMINKA_COMPRESS=gz \
    KOMINKA_COLOR=0 \
    KOMINKA_PROMPT=0 \
    KOMINKA_STRIP=0 \
    KOMINKA_FORCE=1 \
    LOGNAME=root \
    HOME=/root \
    CC=gcc \
    CXX=g++ \
    PKG_CONFIG_PATH=/kominka-root/usr/lib/pkgconfig \
    CPPFLAGS="-I/kominka-root/usr/include" \
    LDFLAGS="-L/kominka-root/usr/lib"

WORKDIR /home/kominka

# pm.ysh last — changes most often, only invalidates the build step.
COPY pm.ysh /usr/bin/pm
RUN chmod +x /usr/bin/pm

# Build minimal bootable system: baselayout + musl + busybox
# (linux-headers and make are build-time deps for busybox)
RUN ysh /usr/bin/pm b baselayout musl linux-headers make busybox

FROM alpine:latest

RUN apk add --no-cache \
    e2fsprogs dosfstools sgdisk util-linux

# ysh binary + libs are stable (pinned oils version) — copy first.
COPY --from=ysh-builder /usr/local/bin/oils-for-unix /ysh-bin/oils-for-unix
COPY --from=ysh-builder /lib/ld-musl-aarch64.so.1 /ysh-libs/ld-musl-aarch64.so.1
COPY --from=ysh-builder /usr/lib/libstdc++.so.6 /ysh-libs/libstdc++.so.6
COPY --from=ysh-builder /usr/lib/libgcc_s.so.1 /ysh-libs/libgcc_s.so.1
COPY --from=ysh-builder /usr/lib/libreadline.so.8 /ysh-libs/libreadline.so.8
COPY --from=ysh-builder /usr/lib/libncursesw.so.6 /ysh-libs/libncursesw.so.6

# Rootfs changes when packages or pm.ysh change.
COPY --from=pkg-builder /kominka-root /rootfs

# build_image.sh changes most often during dev.
COPY build_image.sh /build_image.sh
