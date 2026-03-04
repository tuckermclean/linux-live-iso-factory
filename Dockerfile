# Dockerfile for building minimal i486 Linux system
#
# Unified Gentoo-based image: crossdev toolchain + kernel/busybox + ISO tools.
# Replaces both the old Debian-based Dockerfile and gentoo/Dockerfile.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile Gentoo packages
#   make iso                # Build kernel + busybox + initrd + rootfs + ISO

FROM gentoo/stage3:latest

LABEL maintainer="linux-live-iso-factory"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Pin versions for reproducibility
ENV KERNEL_VERSION=6.12.11
ENV BUSYBOX_VERSION=1.36.1
ENV SYSLINUX_VERSION=6.03

# Target architecture
ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Paths needed during image build (source downloads)
ENV SRC_DIR=/src

# Note: Do NOT set BUILD_DIR before emerge/crossdev steps.
# Portage eclasses (multilib-minimal) use BUILD_DIR internally, and
# setting it globally causes sandbox violations. Set later.

# Note: Do NOT set SYSROOT here - Portage uses it and will fail during host package installs
# Scripts compute SYSROOT from CROSS_TARGET when needed: /usr/${CROSS_TARGET}

# Install host tools needed for building kernel, busybox, ISO, and cross-compiling
RUN emerge-webrsync && \
    emerge --noreplace \
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
        dev-vcs/git && \
    eix-update && \
    rm -rf /var/cache/distfiles/*

# Create overlay for crossdev-generated ebuilds
RUN mkdir -p /var/db/repos/crossdev/{profiles,metadata} && \
    echo 'crossdev' > /var/db/repos/crossdev/profiles/repo_name && \
    echo 'masters = gentoo' > /var/db/repos/crossdev/metadata/layout.conf && \
    chown -R portage:portage /var/db/repos/crossdev

# Register the crossdev overlay
# Handle repos.conf being either a file or directory
RUN if [ -f /etc/portage/repos.conf ]; then \
        mv /etc/portage/repos.conf /etc/portage/repos.conf.bak && \
        mkdir -p /etc/portage/repos.conf && \
        mv /etc/portage/repos.conf.bak /etc/portage/repos.conf/gentoo.conf; \
    else \
        mkdir -p /etc/portage/repos.conf; \
    fi && \
    printf '[crossdev]\nlocation = /var/db/repos/crossdev\npriority = 10\nmasters = gentoo\nauto-sync = no\n' \
        > /etc/portage/repos.conf/crossdev.conf

# Accept all keywords for cross packages
RUN mkdir -p /etc/portage/package.accept_keywords && \
    echo '*/* **' > /etc/portage/package.accept_keywords/crossdev-all

# Build the crossdev toolchain (cached as a Docker layer)
# Nothing below this point affects the toolchain, so config/script edits won't bust this cache.
RUN crossdev --target "${CROSS_TARGET}" --stable --portage --verbose && \
    rm -rf /var/cache/distfiles/*

# Install cpio (needed for initramfs creation, after crossdev to preserve layer cache)
RUN emerge --noreplace app-arch/cpio

# Ensure sysroot portage dirs exist for runtime config sync
RUN mkdir -p /usr/${CROSS_TARGET}/etc/portage/{package.use,package.accept_keywords,package.mask,package.env,env}

# Runtime path env vars — set AFTER all emerge/crossdev steps to avoid
# leaking into Portage's eclass variables (BUILD_DIR, SYSROOT, etc.)
ENV BUILD_DIR=/build
ENV CONFIGS_DIR=/configs
ENV OUTPUT_DIR=/output

# Download and extract sources to /src (immutable in image)
# These get rsync'd to /build (volume) on first run for incremental builds
WORKDIR ${SRC_DIR}

# Download Linux kernel
RUN wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" && \
    tar xf "linux-${KERNEL_VERSION}.tar.xz" && \
    rm "linux-${KERNEL_VERSION}.tar.xz"

# Download BusyBox
RUN wget -q "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" && \
    tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2" && \
    rm "busybox-${BUSYBOX_VERSION}.tar.bz2"

# Create working directories
RUN mkdir -p ${BUILD_DIR} ${CONFIGS_DIR} ${OUTPUT_DIR} /initrd

# Copy default configs (kernel/busybox configs baked in as fallback)
COPY configs/kernel.config configs/busybox.config /default-configs/

# The Makefile inside the container orchestrates builds
COPY container-Makefile /Makefile

WORKDIR /

# Pre-install cmake on the host so BDEPEND resolution doesn't select cmake-9999
# (the live git ebuild), which creates a circular dep via sphinx→pillow→libjpeg-turbo→cmake.
# Must come after all crossdev steps to avoid busting the toolchain layer cache.
RUN emerge --noreplace dev-build/cmake && \
    rm -rf /var/cache/distfiles/*

# Default command shows help
CMD ["make", "help"]
