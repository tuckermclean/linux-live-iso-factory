# Dockerfile for The Monolith
#
# Pure factory — Gentoo crossdev toolchain + ISO assembly tools.
# No sources baked in; all packages arrive via portage at build time.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile all packages (kernel, busybox, userland)
#   make iso                # Build initrd + rootfs + ISO from compiled packages

ARG STAGE3_DATE=20260304T170557Z
FROM gentoo/stage3:amd64-multilib-${STAGE3_DATE}

LABEL maintainer="monolith-builder"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Reproducibility: clamp all build output timestamps to the stage3 date
ENV SOURCE_DATE_EPOCH=1772643957

ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Sync portage and install all host tools
# cmake:   prevents BDEPEND from pulling in cmake-9999 (live ebuild)
# mandoc:  host makewhatis called by bashrc hook to build whatis DB in sysroot
# ncurses: host tic needed to install terminfo DB into sysroot during cross-compile
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

# Build the crossdev toolchain
# static-libs on cross-GCC: libatomic.a needed by packages that link statically (glib → irssi)
RUN crossdev --target "${CROSS_TARGET}" --stable --portage --verbose && \
    echo "cross-${CROSS_TARGET}/gcc static-libs" \
        > /etc/portage/package.use/cross-gcc-static && \
    emerge --update --newuse "cross-${CROSS_TARGET}/gcc" && \
    rm -rf /var/cache/distfiles/*

# Runtime environment
# Set AFTER all emerge steps — Portage eclasses (multilib-minimal) use BUILD_DIR and
# SYSROOT internally; setting them earlier causes sandbox violations.
ENV BUILD_DIR=/build
ENV CONFIGS_DIR=/configs
ENV OUTPUT_DIR=/output

RUN mkdir -p \
        /usr/${CROSS_TARGET}/etc/portage/{package.use,package.accept_keywords,package.mask,package.env,env} \
        ${BUILD_DIR} ${CONFIGS_DIR} ${OUTPUT_DIR} /initrd
