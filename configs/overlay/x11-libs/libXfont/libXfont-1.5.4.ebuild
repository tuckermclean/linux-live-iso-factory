# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="libXfont v1 (bitmap-only, no freetype) — X font library for the TinyX server"
HOMEPAGE="https://gitlab.freedesktop.org/xorg/lib/libxfont"

# ::gentoo dropped x11-libs/libXfont (v1) in favour of libXfont2, but the
# TinyX/kdrive server (x11-base/monolith-xserver) is 1.2.0-era and links the
# v1 `xfont` pkg-config API, NOT libXfont2's incompatible `xfont2`. tinyx's own
# README points right here: "In case you can't find the sources for libXfont
# ver 1 or other libs: https://www.x.org/archive/individual/lib/". 1.5.4 is the
# last v1 release; the x.org release tarball ships a ready ./configure (no
# autoreconf needed). NOTE (CVE-gate): libXfont v1 carries historical CVEs that
# drove distros to libXfont2 — acceptable for this offline single-user rock, but
# flag it if the SBOM/CVE gate trips.
SRC_URI="https://www.x.org/archive/individual/lib/${P}.tar.gz"
S="${WORKDIR}/${P}"

# MIT/X11-style (see the COPYING file in the source tree).
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

# configure.ac: PKG_CHECK_MODULES(XFONT, [xproto xtrans fontsproto fontenc])
# (xproto+fontsproto live in x11-base/xorg-proto) plus AC_CHECK_LIB(z, gzopen)
# for gzipped bitmap fonts. Deliberately NO freetype — disabled below, which is
# the bitmap-only, no-freetype posture the GUI spec §0 demands.
DEPEND="
	x11-base/xorg-proto
	x11-libs/xtrans
	x11-libs/libfontenc
	sys-libs/zlib
"
RDEPEND="${DEPEND}"
BDEPEND="virtual/pkgconfig"

src_configure() {
	# --disable-freetype: drop the ONLY scalable rasterizer path (default
	#   enabled) — keeps freetype/fontconfig entirely off this disc.
	# --enable-pcfformat / --enable-bdfformat: the bitmap formats we actually
	#   serve (terminus PCF, misc-fixed BDF/PCF).
	# --disable-snfformat: obsolete Sun bitmap format, unused.
	# Static / -no-pie / --disable-shared come from env/static.conf via
	# package.env (*/* -> static.conf); do NOT repeat them here.
	econf \
		--disable-freetype \
		--enable-pcfformat \
		--enable-bdfformat \
		--disable-snfformat
}
