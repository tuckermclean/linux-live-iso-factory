# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="xcb-proto (data-only) — xcbgen + XML for cross-building libxcb without a target Python"
HOMEPAGE="https://gitlab.freedesktop.org/xorg/proto/xcbproto"
SRC_URI="https://xorg.freedesktop.org/archive/individual/proto/${P}.tar.xz"

# ::gentoo's x11-base/xcb-proto inherits python-r1: it RDEPENDs a target Python
# (dev-lang/python -> app-arch/zstd, MASKED here) and byte-compiles xcbgen with
# `python_optimize` (needs a real interpreter) and BDEPENDs dev-libs/libxml2
# (also MASKED). All fatal for the i486/musl no-target-Python cross env. But
# xcb-proto is just DATA: 32 protocol .xml files + the pure-Python `xcbgen`
# package that libxcb's build imports. So this overlay ebuild (priority 20 >
# ::gentoo) ships that data with NO python/libxml2 deps and NO byte-compile;
# libxcb runs the codegen with the HOST python at build time. Nothing python
# reaches the i486 disc. See the SP-GUI G2 client-lib notes.
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

# No-op flag: libxcb's BDEPEND is `$(python_gen_any_dep
# 'xcb-proto[${PYTHON_USEDEP}]')`, i.e. it wants xcb-proto[python_targets_python3_14].
# We declare (and default-enable) that flag so the USE-dep + python_check_deps
# has_version match this overlay build — it changes nothing else here.
IUSE="+python_targets_python3_14"

BDEPEND="virtual/pkgconfig"
RDEPEND=""

# Where we drop the pure-Python xcbgen package (a dir on the import path); the
# installed .pc's `pythondir` is rewritten to match so libxcb finds it via
# `pkg-config --variable=pythondir xcb-proto`.
XCBGEN_DIR="/usr/lib/xcb-proto"

src_configure() {
	# AM_PATH_PYTHON([2.5]) in configure.ac wants *a* python to compute pythondir;
	# PYTHON=true skips the version gate (the same trick ::gentoo uses). We never
	# actually run python — this build only installs data.
	PYTHON=true econf
}

src_compile() { :; }

src_install() {
	# xcb-proto.pc (top-level pkgconfig_DATA) + src/*.xml. SUBDIRS=src skips the
	# xcbgen subdir's install-pythonPYTHON target, which byte-compiles via
	# py-compile and would need a real interpreter.
	emake install DESTDIR="${D}" SUBDIRS=src

	# xcbgen as plain data (pure .py, no byte-compile) at a fixed import path.
	insinto "${XCBGEN_DIR}/xcbgen"
	doins "${S}"/xcbgen/*.py

	# Point the installed .pc's pythondir at where xcbgen actually landed so
	# libxcb's `pkg-config --variable=pythondir xcb-proto` resolves it (with the
	# cross sysroot prefix pkg-config prepends via ${pc_sysrootdir}).
	local pc="${ED}/usr/share/pkgconfig/xcb-proto.pc"
	[[ -f ${pc} ]] || die "xcb-proto.pc not installed where expected: ${pc}"
	sed -i -E "s|^pythondir=.*|pythondir=\\\${pc_sysrootdir}${XCBGEN_DIR}|" "${pc}" || die

	dodoc README.md NEWS
}
