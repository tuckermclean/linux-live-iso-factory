# Dockerfile for The Monolith
#
# Pure factory — Gentoo crossdev toolchain + ISO assembly tools.
# No sources baked in; all packages arrive via portage at build time.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile all packages (kernel, busybox, userland)
#   make iso                # Build initrd + rootfs + ISO from compiled packages

# Single epoch pins the stage3 base image and portage snapshot to the same date.
# This is a policy choice for reproducibility and attestation: a single BUILD_EPOCH
# unambiguously identifies all build inputs (toolchain + ebuilds).
# Update with: make update-build-pins
ARG BUILD_EPOCH=20260420
FROM gentoo/stage3:amd64-openrc-${BUILD_EPOCH} AS base-tools

LABEL maintainer="monolith-builder"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Reproducibility: clamp all build output timestamps to the stage3 date
ENV SOURCE_DATE_EPOCH=1776643200

ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Re-declare so the value is available inside this stage
ARG BUILD_EPOCH

# Fetch pinned portage snapshot using portage's own tooling.
# --revert pins to a specific date for reproducibility; emerge-webrsync handles
# GPG verification internally using its bundled Gentoo release signing key
# (DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D) — build fails if signature invalid.
RUN emerge-webrsync --revert=${BUILD_EPOCH}

# Install all host tools
# cmake:   prevents BDEPEND from pulling in cmake-9999 (live ebuild)
# mandoc:  host makewhatis called by bashrc hook to build whatis DB in sysroot
# ncurses: host tic needed to install terminfo DB into sysroot during cross-compile
RUN GRUB_PLATFORMS="efi-32 efi-64" emerge --noreplace \
        sys-devel/crossdev \
        app-portage/gentoolkit \
        app-portage/eix \
        sys-devel/flex \
        sys-devel/bison \
        sys-devel/bc \
        dev-libs/elfutils \
        sys-boot/syslinux \
        sys-boot/grub \
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

# Attestation tools: Syft (SBOM generation) + Grype (CVE scanning) + pyyaml
# These are installed into the builder image so CI doesn't re-download them
# on every run. The Grype vulnerability database is stored in a separate
# Docker volume (monolith-grype-db) and updated via `make grype-db-update`.
RUN emerge dev-python/pyyaml && \
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
        | sh -s -- -b /usr/local/bin && \
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
        | sh -s -- -b /usr/local/bin && \
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
