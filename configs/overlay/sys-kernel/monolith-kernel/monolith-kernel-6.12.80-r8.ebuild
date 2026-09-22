# Copyright 2024 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Linux kernel cross-compiled for i486 — The Monolith"
HOMEPAGE="https://kernel.org"
SRC_URI="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PV}.tar.xz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"

S="${WORKDIR}/linux-${PV}"

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
	# -j1: cross-gcc is memory-heavy; higher parallelism OOMs CI runners
	emake -j1 ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" bzImage modules
}

src_install() {
	insinto /boot
	newins arch/x86/boot/bzImage vmlinuz-${PV}
	dosym vmlinuz-${PV} /boot/vmlinuz

	# Install loadable kernel modules into the target sysroot. They ride into the
	# rootfs squashfs via build-rootfs.sh's `rsync -a sysroot/ rootfs/`, so the
	# booted system's coldplug can load exactly the drivers each machine has.
	# INSTALL_MOD_STRIP=1 keeps them small (486 disk + gzip-decompress budget).
	emake ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" \
		INSTALL_MOD_PATH="${D}" INSTALL_MOD_STRIP=1 modules_install

	# modules_install leaves build/ and source/ symlinks pointing at the
	# ephemeral build tree (dangling in the image). Drop them, then regenerate
	# modules.dep rooted at the image so on-target modprobe resolves deps.
	local krel
	krel="$(make -s ARCH=i386 kernelrelease)"
	rm -f "${D}/lib/modules/${krel}/build" "${D}/lib/modules/${krel}/source"
	depmod -b "${D}" "${krel}"

	# Ship the resolved (post-olddefconfig) .config as package content, gzipped
	# (486-minimalism — raw .config is ~100-250 KiB of dead weight on the ISO;
	# gzip -9 gets it down to kernel.org's own config.gz convention size).
	# Because it rides inside the binpkg's CONTENTS, it is installed identically
	# whether monolith-kernel is built from source or pulled from the binpkg
	# cache — unlike the old configs/kernel.config copy-back below, which is a
	# no-op on a cache hit because src_install never runs. This is what makes
	# scripts/verify-resolved-i2c-off.sh a real assertion on both CI paths
	# instead of a vacuous pass on the common cache-hit path (DCX-99).
	insinto /usr/share/monolith-kernel
	gzip -9c .config > "${T}/resolved-kernel.config.gz" || die "Failed to gzip resolved kernel config"
	doins "${T}/resolved-kernel.config.gz"

	# Save final config back to /configs for local `make kernel-config`
	# convenience. On a binpkg cache hit this copy never runs (src_install is
	# skipped), which is why scripts/build-packages.sh separately re-derives
	# this same file from the package artifact above on every run — that copy,
	# not this one, is what CI actually asserts against.
	# A failure here used to be silently swallowed (`|| true`); make it loud.
	cp .config "${CONFIGS_DIR}/kernel.config" || die "Failed to copy resolved kernel config back to ${CONFIGS_DIR}/kernel.config"
}

pkg_config() {
	# Run menuconfig interactively and save result back to /configs/kernel.config
	# Re-extracts source into T to avoid needing the build workdir to persist
	einfo "Setting up kernel source for menuconfig..."
	local src="${T}/linux-${PV}"
	mkdir -p "${src}"
	local distfiles
	distfiles=$(portageq distdir 2>/dev/null || echo "/var/cache/distfiles")
	tar xf "${distfiles}/linux-${PV}.tar.xz" -C "${src}" --strip-components=1

	pushd "${src}" >/dev/null || die

	# Apply patches — use EBUILD path since FILESDIR/DISTDIR aren't populated for pkg_* phases
	eapply "${EBUILD%/*}/files/linux-${PV%.*}-gcc15-std-gnu11.patch"

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
