# Dockerfile for building minimal i486 Linux system
#
# Unified Gentoo-based image: crossdev toolchain + ISO tools.
# Pure factory — no sources baked in. Sources come via portage at build time.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile all packages (kernel, busybox, userland)
#   make iso                # Build initrd + rootfs + ISO from compiled packages

ARG STAGE3_DATE=20260304T170557Z
FROM gentoo/stage3:amd64-multilib-${STAGE3_DATE}

# Reproducibility: clamp all build output timestamps to the stage3 date
ENV SOURCE_DATE_EPOCH=1772643957

LABEL maintainer="monolith-builder"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Target architecture
ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Note: Do NOT set BUILD_DIR before emerge/crossdev steps.
# Portage eclasses (multilib-minimal) use BUILD_DIR internally, and
# setting it globally causes sandbox violations. Set later.

# Note: Do NOT set SYSROOT here - Portage uses it and will fail during host package installs
# Scripts compute SYSROOT from CROSS_TARGET when needed: /usr/${CROSS_TARGET}

# Install host tools needed for cross-compiling, kernel build, and ISO assembly
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

# Register the monolith overlay (configs bind-mounted at /configs at runtime)
# The overlay lives at /configs/overlay — registered here so portage finds it at runtime
RUN printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
    > /etc/portage/repos.conf/monolith.conf

# Accept all keywords for cross packages and monolith overlay
RUN mkdir -p /etc/portage/package.accept_keywords && \
    echo '*/* **' > /etc/portage/package.accept_keywords/crossdev-all && \
    echo 'sys-kernel/linux-live **' > /etc/portage/package.accept_keywords/monolith

# Disable Manifest verification for the monolith overlay (local overlay, no upstream signing)
RUN echo 'FEATURES="${FEATURES} -strict"' >> /etc/portage/make.conf

# Build the crossdev toolchain (cached as a Docker layer)
# Nothing below this point affects the toolchain, so config/script edits won't bust this cache.
RUN crossdev --target "${CROSS_TARGET}" --stable --portage --verbose && \
    rm -rf /var/cache/distfiles/*

# Add static-libs USE for the cross-GCC so that libatomic.a (and libgcc.a) are
# installed alongside the .so versions.  Without this, packages that need
# libatomic (glib → irssi) can't link statically.
# Placed AFTER the crossdev layer to preserve its build cache.
# Only recompiles the GCC runtime library archives, not the full toolchain.
RUN echo "cross-${CROSS_TARGET}/gcc static-libs" \
        > /etc/portage/package.use/cross-gcc-static && \
    emerge --update --newuse "cross-${CROSS_TARGET}/gcc" && \
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

# Create working directories
RUN mkdir -p ${BUILD_DIR} ${CONFIGS_DIR} ${OUTPUT_DIR} /initrd

# Pre-install host tools needed by cross-compilation builds:
#   cmake:      prevents BDEPEND from selecting cmake-9999 (live git ebuild), which
#               creates a circular dep via sphinx→pillow→libjpeg-turbo→cmake.
#   fortune-mod: cross-compile requires native 'strfile' binary in PATH.
#   mandoc:     host makewhatis used by bashrc pkg_postinst override to build whatis DB.
#   ncurses:    cross-compile requires native 'tic' (terminfo compiler) in PATH to
#               install the terminfo database (e.g. linux, vt100) into the sysroot.
#               Without it, tic is an i486 binary that can't run on the build host and
#               the terminfo database is never installed — breaking all ncurses programs.
# Must come after all crossdev steps to avoid busting the toolchain layer cache.
# Create groups needed by game package preinst phases (e.g. nethack fowners root:gamestat)
RUN groupadd -g 35 games 2>/dev/null || true && \
    groupadd -g 36 gamestat 2>/dev/null || true

RUN unset BUILD_DIR && \
    emerge --noreplace dev-build/cmake games-misc/fortune-mod app-text/mandoc \
        sys-libs/ncurses && \
    rm -rf /var/cache/distfiles/*

WORKDIR /
