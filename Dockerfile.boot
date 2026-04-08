# Multi-stage build: ysh -> Kominka packages -> disk image builder
#
# Stage 1: Build ysh from source
# Stage 2: Build Kominka rootfs (all core packages) with pm.ysh
# Stage 3: Assemble GPT disk image (rootfs only, no kernel)
#
# Kernel is built separately via Dockerfile.linux.
#
# Usage:
#   docker build -t kominka-boot -f Dockerfile.boot .
#   docker run --rm --privileged -v "$(pwd)":/out kominka-boot sh /build_image.sh

FROM debian:bookworm-slim AS ysh-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libreadline-dev curl ca-certificates tar && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fLo /tmp/oils.tar.gz \
        https://oils.pub/download/oils-for-unix-0.37.0.tar.gz && \
    cd /tmp && tar xzf oils.tar.gz && \
    cd oils-for-unix-* && \
    ./configure && \
    _build/oils.sh && \
    ./install

FROM debian:bookworm-slim AS pkg-builder

COPY --from=ysh-builder /usr/local/bin/oils-for-unix /usr/local/bin/oils-for-unix
RUN ln -s oils-for-unix /usr/local/bin/osh && \
    ln -s oils-for-unix /usr/local/bin/ysh

RUN apt-get update && apt-get install -y --no-install-recommends \
    coreutils findutils grep sed gawk diffutils \
    curl git ca-certificates openssl \
    build-essential gcc g++ libc6-dev linux-libc-dev \
    make patch bison flex m4 texinfo \
    cmake ninja-build golang pkg-config \
    perl gzip bzip2 xz-utils zlib1g-dev libzstd-dev \
    automake autoconf python3 \
    libgmp-dev libmpfr-dev libmpc-dev \
    tar && \
    rm -rf /var/lib/apt/lists/*

COPY tests/fixtures/repo /packages

RUN find /packages -name build -exec chmod +x {} + && \
    find /packages -name post-install -exec chmod +x {} +

RUN mkdir -p /kominka-root/var/db/kominka/installed /kominka-root/var/db/kominka/choices

# Register host-provided build tools so pm's dependency resolution
# finds them as already installed.
RUN for pkg in cmake go ninja glibc perl; do \
      mkdir -p "/kominka-root/var/db/kominka/installed/$pkg" && \
      echo "0 0" > "/kominka-root/var/db/kominka/installed/$pkg/version"; \
    done

# Add /kominka-root/usr/bin to PATH so packages built earlier
# (e.g. m4, make) are available to later builds (e.g. bison).
ENV PATH=/kominka-root/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    KOMINKA_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev \
    KOMINKA_PATH=/packages \
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

# Build all core packages in dependency order.
COPY tests/build_core.sh /home/kominka/build_core.sh
RUN chmod +x /home/kominka/build_core.sh && sh /home/kominka/build_core.sh

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    e2fsprogs dosfstools gdisk util-linux cpio gzip && \
    rm -rf /var/lib/apt/lists/*

# ysh binary + libs are stable (pinned oils version) — copy first.
COPY --from=ysh-builder /usr/local/bin/oils-for-unix /ysh-bin/oils-for-unix
COPY --from=ysh-builder /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 /ysh-libs/ld-linux-aarch64.so.1
COPY --from=ysh-builder /lib/aarch64-linux-gnu/libc.so.6 /ysh-libs/libc.so.6
COPY --from=ysh-builder /lib/aarch64-linux-gnu/libm.so.6 /ysh-libs/libm.so.6
COPY --from=ysh-builder /usr/lib/aarch64-linux-gnu/libstdc++.so.6 /ysh-libs/libstdc++.so.6
COPY --from=ysh-builder /lib/aarch64-linux-gnu/libgcc_s.so.1 /ysh-libs/libgcc_s.so.1
COPY --from=ysh-builder /lib/aarch64-linux-gnu/libreadline.so.8 /ysh-libs/libreadline.so.8
COPY --from=ysh-builder /lib/aarch64-linux-gnu/libtinfo.so.6 /ysh-libs/libtinfo.so.6

# Rootfs, package repo, pm, and pre-built tarballs.
COPY --from=pkg-builder /kominka-root /rootfs
COPY --from=pkg-builder /packages /packages
COPY --from=pkg-builder /usr/bin/pm /pm.ysh
COPY --from=pkg-builder /root/.cache/kominka/bin /tarball-cache

# build_image.sh changes most often during dev.
COPY build_image.sh /build_image.sh
