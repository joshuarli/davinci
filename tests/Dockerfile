FROM alpine:latest

# pm runtime dependencies: a sha256 utility, a download utility, git, and
# standard POSIX tools.  Build-time dependencies for the KISS core packages
# themselves: C toolchain, make, patch, perl (openssl Configure), sed, etc.
RUN apk add --no-cache \
    coreutils findutils grep sed gawk diffutils \
    curl git \
    openssl \
    build-base gcc g++ musl-dev linux-headers \
    make patch bison flex m4 texinfo \
    perl gzip bzip2 xz zlib-dev zstd \
    automake autoconf python3 \
    gmp-dev mpfr-dev mpc1-dev \
    tar

# Install pm.
COPY pm /usr/bin/kiss
RUN chmod +x /usr/bin/kiss

# Copy in the vendored repo and sources.
COPY tests/fixtures/repo /home/kiss/repo
COPY tests/fixtures/sources /home/kiss/sources

# Ensure all build scripts are executable.
RUN find /home/kiss/repo -name build -exec chmod +x {} +
RUN find /home/kiss/repo -name post-install -exec chmod +x {} +

# Create the chroot target and its package database.
RUN mkdir -p /kiss-root/var/db/kiss/installed /kiss-root/var/db/kiss/choices

# Set up the KISS environment.
# Packages are built with the host toolchain but installed into /kiss-root.
# PKG_CONFIG_PATH, CPPFLAGS, and LDFLAGS point into the chroot so that
# configure scripts can find previously-installed KISS packages.
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

# Copy in the build/verify helper script.
COPY tests/build_core.sh /home/kiss/build_core.sh
RUN chmod +x /home/kiss/build_core.sh
