# Dockerfile for Gentoo-based i486-linux-musl cross-compilation
#
# Uses crossdev to build a complete i486-linux-musl toolchain
# for cross-compiling Gentoo packages as static binaries.
#
# Usage:
#   make build-image        # Build this image (includes toolchain, ~15 min first time)
#   make build-packages     # Cross-compile packages from world file
#   make extract            # Extract binpkgs to sysroot

FROM gentoo/stage3:latest

LABEL maintainer="linux-live-iso-factory"
LABEL description="Gentoo crossdev environment for i486-linux-musl"

# Target architecture
ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Directory layout
ENV CONFIGS_DIR=/etc/portage-cross
ENV SCRIPTS_DIR=/scripts
ENV OUTPUT_DIR=/output
# Note: Do NOT set SYSROOT here - Portage uses it and will fail during host package installs
# Scripts compute SYSROOT from CROSS_TARGET when needed: /usr/${CROSS_TARGET}

# Install required packages for crossdev and building
RUN emerge-webrsync && \
    emerge --noreplace \
        sys-devel/crossdev \
        app-portage/gentoolkit \
        app-portage/eix \
        sys-fs/squashfs-tools \
        app-arch/xz-utils \
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

# Accept all keywords for cross packages (crossdev writes to the
# "cross-i486-linux-musl" file with only stable arch keywords, which
# won't match musl's unstable ~x86 KEYWORDS; the ::repo qualifier
# in package.accept_keywords is unreliable, so use bare */* **)
RUN mkdir -p /etc/portage/package.accept_keywords && \
    echo '*/* **' > /etc/portage/package.accept_keywords/crossdev-all

# Create directory structure
RUN mkdir -p ${CONFIGS_DIR} ${SCRIPTS_DIR} ${OUTPUT_DIR}/packages ${OUTPUT_DIR}/sysroot ${OUTPUT_DIR}/logs

# Build the crossdev toolchain (cached as a Docker layer)
# musl is auto-detected from the target triple; --libc takes a VERSION not a name
# Nothing below this point affects the toolchain, so config/script edits won't
# bust this cache layer.
RUN emerge --sync 2>/dev/null || emerge-webrsync && \
    crossdev --target "${CROSS_TARGET}" --stable --portage --verbose && \
    rm -rf /var/cache/distfiles/*

# Copy scripts and configs (AFTER toolchain so edits don't force a rebuild)
COPY scripts/ ${SCRIPTS_DIR}/
RUN chmod +x ${SCRIPTS_DIR}/*.sh
COPY configs/make.conf ${CONFIGS_DIR}/
COPY configs/world ${CONFIGS_DIR}/
COPY configs/versions.lock ${CONFIGS_DIR}/
COPY configs/package.use/ ${CONFIGS_DIR}/package.use/
COPY configs/package.accept_keywords/ ${CONFIGS_DIR}/package.accept_keywords/
COPY configs/package.mask/ ${CONFIGS_DIR}/package.mask/
COPY configs/package.env/ ${CONFIGS_DIR}/package.env/
COPY configs/env/ ${CONFIGS_DIR}/env/

# Copy cross-portage configs into the sysroot
RUN SYSROOT="/usr/${CROSS_TARGET}" && \
    CROSS_PORTAGE="${SYSROOT}/etc/portage" && \
    mkdir -p "${CROSS_PORTAGE}"/{package.use,package.accept_keywords,package.mask,package.env,env} && \
    cp "${CONFIGS_DIR}/make.conf" "${CROSS_PORTAGE}/make.conf" && \
    for dir in package.use package.accept_keywords package.mask package.env; do \
        cp -r "${CONFIGS_DIR}/${dir}"/* "${CROSS_PORTAGE}/${dir}/" 2>/dev/null || true; \
    done && \
    cp -r "${CONFIGS_DIR}/env"/* "${CROSS_PORTAGE}/env/" 2>/dev/null || true

WORKDIR /
