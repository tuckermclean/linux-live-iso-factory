# Copyright 2024 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Linux kernel cross-compiled for i486 live ISO"
HOMEPAGE="https://kernel.org"
SRC_URI="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PV}.tar.xz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"

BDEPEND="
    sys-devel/bc
    sys-devel/flex
    app-alternatives/lex
    sys-devel/bison
    dev-libs/elfutils
"

PATCHES=( "${FILESDIR}/linux-${PV%.*}-gcc15-std-gnu11.patch" )

src_configure() {
    # Load pinned config from bind-mounted /configs, fall back to allnoconfig
    if [[ -f "${CONFIGS_DIR}/kernel.config" ]]; then
        cp "${CONFIGS_DIR}/kernel.config" .config
        einfo "Loaded kernel config from ${CONFIGS_DIR}/kernel.config"
    else
        ewarn "No kernel.config found at ${CONFIGS_DIR}/kernel.config — using allnoconfig"
        make ARCH=i386 allnoconfig
    fi
    make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
}

src_compile() {
    emake ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" bzImage
}

src_install() {
    # Install kernel image to /output for ISO assembly
    insinto /output
    newins arch/x86/boot/bzImage vmlinuz
    # Save final config back to /configs
    cp .config "${CONFIGS_DIR}/kernel.config" || true
}

pkg_config() {
    # Run menuconfig interactively and save result back to /configs/kernel.config
    # Re-extracts source into T to avoid needing the build workdir to persist
    einfo "Setting up kernel source for menuconfig..."
    local src="${T}/linux-${PV}"
    mkdir -p "${src}"
    tar xf "${DISTDIR}/linux-${PV}.tar.xz" -C "${src}" --strip-components=1

    pushd "${src}" >/dev/null || die

    # Apply patches
    eapply "${FILESDIR}/linux-${PV%.*}-gcc15-std-gnu11.patch"

    # Load existing config
    if [[ -f "${CONFIGS_DIR}/kernel.config" ]]; then
        cp "${CONFIGS_DIR}/kernel.config" .config
    else
        make ARCH=i386 allnoconfig
    fi
    make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

    # Interactive menuconfig
    make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" menuconfig

    # Save result
    cp .config "${CONFIGS_DIR}/kernel.config" || die "Failed to save kernel config"
    einfo "Kernel config saved to ${CONFIGS_DIR}/kernel.config"

    popd >/dev/null || die
}
