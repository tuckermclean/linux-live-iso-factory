# Dockerfile for building minimal i486 Linux system
# Uses pre-built i486-linux-musl toolchain from musl.cc
#
# Target: Pentium-class machines (i486 instruction set for broader compatibility)
# Toolchain: i486-linux-musl (statically linkable, small binaries)

FROM debian:bookworm-slim

LABEL maintainer="linux-live-iso-factory"
LABEL description="Cross-compilation environment for minimal i486 Linux"

# Pin versions for reproducibility
ENV KERNEL_VERSION=6.12.11
ENV BUSYBOX_VERSION=1.36.1
ENV SYSLINUX_VERSION=6.03

# Toolchain target
ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Paths
ENV TOOLCHAIN_PATH=/opt/cross/i486-linux-musl-cross
ENV PATH="${TOOLCHAIN_PATH}/bin:${PATH}"
ENV SRC_DIR=/src
ENV BUILD_DIR=/build
ENV CONFIGS_DIR=/configs
ENV OUTPUT_DIR=/output

# Install build dependencies
# - build-essential: compilers, make, etc.
# - libncurses-dev: for menuconfig
# - flex, bison: kernel build requirements
# - bc: kernel build calculations
# - libelf-dev: kernel BTF support (optional but avoids warnings)
# - xz-utils: for kernel/initrd compression
# - cpio: for initramfs creation
# - isolinux, syslinux-common: for bootable ISO
# - wget, ca-certificates: for downloading sources
# - xorriso: for creating ISO images
# - mtools: for FAT filesystem manipulation (UEFI support)
# - dosfstools: for creating FAT filesystems
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libncurses-dev \
    flex \
    bison \
    bc \
    libelf-dev \
    xz-utils \
    cpio \
    isolinux \
    syslinux-common \
    syslinux-efi \
    wget \
    ca-certificates \
    xorriso \
    mtools \
    dosfstools \
    rsync \
    file \
    qemu-system-x86 \
    squashfs-tools \
    && rm -rf /var/lib/apt/lists/*

# Download pre-built musl cross-compiler from musl.cc
# This is WAY faster than building musl-cross-make from source
WORKDIR /opt/cross
RUN wget -q https://musl.cc/i486-linux-musl-cross.tgz && \
    tar xf i486-linux-musl-cross.tgz && \
    rm i486-linux-musl-cross.tgz

# Verify toolchain installation
RUN ${CROSS_COMPILE}gcc --version && \
    echo "Toolchain installed successfully"

# Download and extract sources to /src (immutable in image)
# These get rsync'd to /build (bind-mounted volume) on first run for incremental builds
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

# Copy build scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Copy rootfs skeleton (init script, etc.)
COPY rootfs/ /rootfs/

# Copy default configs
COPY configs/ /default-configs/

# The Makefile inside the container orchestrates builds
COPY container-Makefile /Makefile

WORKDIR /

# Default command shows help
CMD ["make", "help"]
