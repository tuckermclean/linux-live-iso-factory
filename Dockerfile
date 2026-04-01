# Dockerfile for The Monolith
#
# Pure factory — Gentoo crossdev toolchain + ISO assembly tools.
# No sources baked in; all packages arrive via portage at build time.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile all packages (kernel, busybox, userland)
#   make iso                # Build initrd + rootfs + ISO from compiled packages

ARG STAGE3_DATE=20260323
# Portage snapshot date — must match an available gentoo-YYYYMMDD.tar.xz on distfiles.
# Pinned independently of STAGE3_DATE so both can be updated and attested separately.
# Verified at build time against Gentoo's release signing key (GPG).
# Update with: make update-build-pins
ARG PORTAGE_DATE=20260330
FROM gentoo/stage3:amd64-openrc-${STAGE3_DATE} AS base-tools

LABEL maintainer="monolith-builder"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Reproducibility: clamp all build output timestamps to the stage3 date
ENV SOURCE_DATE_EPOCH=1774224000

ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Re-declare so the value is available inside this stage
ARG PORTAGE_DATE

# Fetch pinned portage snapshot using portage's own tooling.
# --revert pins to a specific date for reproducibility; emerge-webrsync handles
# GPG verification internally using its bundled Gentoo release signing key
# (DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D) — build fails if signature invalid.
RUN emerge-webrsync --revert=${PORTAGE_DATE}

# Install all host tools
# cmake:   prevents BDEPEND from pulling in cmake-9999 (live ebuild)
# mandoc:  host makewhatis called by bashrc hook to build whatis DB in sysroot
# ncurses: host tic needed to install terminfo DB into sysroot during cross-compile
RUN emerge --noreplace \
        sys-devel/crossdev \
        app-portage/gentoolkit \
        app-portage/eix \
        sys-devel/flex \
        sys-devel/bison \
        sys-devel/bc \
        dev-libs/elfutils \
        sys-boot/syslinux \
        dev-libs/libisoburn \
        sys-fs/mtools \
        sys-fs/dosfstools \
        sys-fs/squashfs-tools \
        app-arch/xz-utils \
        net-misc/rsync \
        sys-apps/file \
        dev-vcs/git \
        app-arch/cpio \
        dev-build/cmake \
        app-text/mandoc \
        sys-libs/ncurses && \
    eix-update && \
    rm -rf /var/cache/distfiles/*

# Configure portage overlays and policy
RUN mkdir -p /var/db/repos/crossdev/{profiles,metadata} && \
    echo 'crossdev' > /var/db/repos/crossdev/profiles/repo_name && \
    echo 'masters = gentoo' > /var/db/repos/crossdev/metadata/layout.conf && \
    chown -R portage:portage /var/db/repos/crossdev && \
    mkdir -p /etc/portage/repos.conf && \
    printf '[crossdev]\nlocation = /var/db/repos/crossdev\npriority = 10\nmasters = gentoo\nauto-sync = no\n' \
        > /etc/portage/repos.conf/crossdev.conf && \
    printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
        > /etc/portage/repos.conf/monolith.conf && \
    mkdir -p /etc/portage/package.accept_keywords && \
    echo '*/* **' > /etc/portage/package.accept_keywords/crossdev-all && \
    echo 'sys-kernel/linux-live **' > /etc/portage/package.accept_keywords/monolith && \
    echo 'FEATURES="${FEATURES} -strict"' >> /etc/portage/make.conf

# crossdev toolchain build and runtime setup are handled by `make build-image`.
# Running crossdev via `docker run` (not `docker build`) ensures all portage logs
# are captured to output/portage-logs/ on the host via LOGS_MOUNT.
