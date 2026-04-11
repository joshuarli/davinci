# Kominka Linux base image (FROM scratch, ~57MB).
#
# Bootstrap: busybox:latest (4MB static musl) provides wget+tar+sh.
# ysh is static musl — runs directly on the busybox base.
# pm resolves and installs all packages from R2.
#
# Usage:
#   docker build -t kominka:core .
#   docker build --platform linux/amd64 -t kominka:core-amd64 .

FROM busybox:latest AS bootstrap

ARG R2_BASE=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev

# Bootstrap package versions — pinned to what exists on R2.
# These are ONLY used for the initial pm i core; rebuild-world replaces them.
COPY <<'PKGBUILDS' /bootstrap-packages/glibc/PKGBUILD.ysh
var name='glibc'; var ver='2.38'; var rel='3'; var deps=[]; var mkdeps=[]
var sources=['bootstrap']; var checksums=[]
PKGBUILDS
COPY <<'PKGBUILDS' /bootstrap-packages/busybox/PKGBUILD.ysh
var name='busybox'; var ver='1.34.1'; var rel='3'; var deps=['glibc']; var mkdeps=[]
var sources=['bootstrap']; var checksums=[]
PKGBUILDS
COPY <<'PKGBUILDS' /bootstrap-packages/zlib/PKGBUILD.ysh
var name='zlib'; var ver='1.2.11'; var rel='3'; var deps=['glibc']; var mkdeps=[]
var sources=['bootstrap']; var checksums=[]
PKGBUILDS
COPY <<'PKGBUILDS' /bootstrap-packages/curl/PKGBUILD.ysh
var name='curl'; var ver='7.80.0'; var rel='5'; var deps=['boringssl','zlib']; var mkdeps=[]
var sources=['bootstrap']; var checksums=[]
PKGBUILDS

# Detect architecture for R2 binary path.
RUN case "$(busybox uname -m)" in \
        x86_64)  echo "x86_64-linux-gnu" > /tmp/arch ;; \
        *)       echo "aarch64-linux-gnu" > /tmp/arch ;; \
    esac

# Get ysh (static musl binary — runs on any Linux, no glibc needed).
RUN busybox mkdir -p /usr/local/bin && \
    ARCH=$(busybox cat /tmp/arch) && \
    busybox wget --no-check-certificate -qO- "$R2_BASE/$ARCH/ysh/0.37.0-2.tar.gz" | \
    busybox tar xzf - -C / ./usr/local/bin/

# Install pm and package repo.
COPY pm.ysh /usr/bin/pm
RUN busybox chmod +x /usr/bin/pm
COPY --from=packages / /packages
RUN busybox find /packages -name build -exec busybox chmod +x {} + && \
    busybox find /packages -name post-install -exec busybox chmod +x {} +

RUN busybox mkdir -p /kominka-root/var/db/kominka/installed \
                     /kominka-root/var/db/kominka/choices

# pm installs the core metapackage — resolves all runtime deps from R2.
RUN KOMINKA_BIN_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev \
    KOMINKA_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev \
    KOMINKA_PATH=/bootstrap-packages:/packages \
    KOMINKA_ROOT=/kominka-root \
    KOMINKA_COMPRESS=gz \
    KOMINKA_COLOR=0 \
    KOMINKA_PROMPT=0 \
    KOMINKA_STRIP=0 \
    KOMINKA_FORCE=1 \
    KOMINKA_INSECURE=1 \
    LOGNAME=root \
    HOME=/root \
    ysh /usr/bin/pm i core

RUN busybox cp /usr/bin/pm /kominka-root/usr/bin/pm

FROM scratch

COPY --from=bootstrap /kominka-root /

ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/root \
    LOGNAME=root

CMD ["/bin/sh"]
