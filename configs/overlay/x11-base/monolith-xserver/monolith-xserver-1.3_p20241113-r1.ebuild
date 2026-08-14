# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit autotools flag-o-matic

DESCRIPTION="TinyX/kdrive Xfbdev — static, framebuffer-native, zero-dlopen X server"
HOMEPAGE="https://github.com/tinycorelinux/tinyx"

# TinyX (kdrive) resurrected + maintained by the Tiny Core Linux folks: a
# xorg-server 1.2.0-era kdrive extraction, deliberately no xkb / no xinput /
# no GL / no dlopen (see README). This is the ONE X server that satisfies GUI
# spec §1 (static, framebuffer-native, ZERO loader on the disc). The fork's
# history is squash-merged with no release tags, so pin the exact commit and
# let GitHub's per-commit archive be the DIST tarball, Manifest-pinning its
# bytes — same pattern as games-roguelike/rl144. If GitHub's archive gzip ever
# drifts and the hash mismatches, host the tarball in the project's own S3 and
# repoint SRC_URI. Version = upstream's AC_INIT tinyx 1.3 + the commit date.
COMMIT="feab72ca891bc04b18763763e15ee4e532369cdf"
SRC_URI="https://github.com/tinycorelinux/tinyx/archive/${COMMIT}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/tinyx-${COMMIT}"

# Original kdrive code is MIT; the Tiny Core fork's own changes are GPL-3
# (README "Licensing" + COPYING). Ship both.
LICENSE="MIT GPL-3"
SLOT="0"
KEYWORDS="~amd64"

# Server-side X libraries + protocol headers, straight from tinyx configure.ac:
#   REQUIRED_MODULES = randrproto renderproto fixesproto damageproto xcmiscproto
#     xextproto xproto xf86bigfontproto scrnsaverproto bigreqsproto
#     resourceproto fontsproto inputproto kbproto   -> all in x11-base/xorg-proto
#   REQUIRED_LIBS   = xfont fontenc  -> x11-libs/libXfont (v1) + x11-libs/libfontenc
# xtrans is header-only transport glue; zlib comes in transitively via libXfont
# (gzipped bitmap fonts) but is named explicitly so the static Xfbdev link
# resolves gzopen. NO pixman: tinyx's 1.2.0-era fb does not PKG_CHECK it (the
# earlier recon guessed it would — configure.ac is the ground truth). NO libX11
# etc.: this is the SERVER; client libs are a separate (G2) concern.
DEPEND="
	x11-base/xorg-proto
	x11-libs/xtrans
	x11-libs/libXfont
	x11-libs/libfontenc
	sys-libs/zlib
"
RDEPEND=""
# tinyx ships only configure.ac + autogen.sh (no ./configure); eautoreconf
# regenerates it on the build host. configure.ac uses 16 XORG_* macros from
# x11-misc/util-macros and PKG_PROG_PKG_CONFIG from pkg-config.
BDEPEND="
	virtual/pkgconfig
	x11-misc/util-macros
"

src_prepare() {
	default
	eautoreconf

	# Vendored server-side X headers. tinyx (2007-era kdrive) reuses a handful
	# of CLIENT headers that ::gentoo ships only in libX11/libXext/libXau/
	# libXdmcp — the client stack the GUI spec keeps OUT of the minimal server.
	# Each is a self-contained struct/proto header whose sub-includes ALL resolve
	# from x11-base/xorg-proto (already a DEPEND); the server supplies the
	# implementations itself (or a `_*_SERVER_` guard blanks the client body), so
	# NOT ONE client library is linked (verified by the readelf check below and
	# by tinyx PKG_CHECK-ing only xfont/fontenc). We drop them on the -I../include
	# search path the tree already compiles with (belt-and-suspenders global -I in
	# src_configure). MIT-licensed, from libXext 1.3.7 / libXau 1.0.11 /
	# libXdmcp 1.1.5; XTest.h is a server-mode stub (see files/XTest.h).
	#   extensions/XShm.h  (libXext)  — mi/miscrinit.c    (#define _XSHM_SERVER_)
	#   extensions/sync.h  (libXext)  — Xext/sync.c
	#   extensions/XTest.h (stub)     — mi/miinitext.c    (#define _XTEST_SERVER_)
	#   Xauth.h            (libXau)   — os/auth.c, xauembed.c (xauembed = embedded
	#                                   Xau impl, so header-only, no libXau link)
	#   Xdmcp.h            (libXdmcp) — os/osdep.h (header-only; XDMCP disabled →
	#                                   xdmauth.c body is #ifdef HASXDMAUTH → no link)
	# Xpoll.h is deliberately absent: x11-base/xorg-proto generates and installs
	# it from Xpoll.h.in, so os/ finds it in the sysroot already.
	mkdir -p include/X11/extensions || die
	cp "${FILESDIR}"/XShm.h "${FILESDIR}"/sync.h "${FILESDIR}"/XTest.h \
		include/X11/extensions/ || die
	cp "${FILESDIR}"/Xauth.h "${FILESDIR}"/Xdmcp.h include/X11/ || die
}

src_configure() {
	# --disable-xvesa: Xvesa does BIOS int10 modesetting (vm86/x86emu) — we
	#   inherit vesafb instead, so we neither build it nor drag in asm/vm86.h.
	# --enable-kdrive / --enable-xfbdev: the one server we ship, over /dev/fb0.
	# The --disable-* set strips extensions we never use (smaller binary, fewer
	#   proto/lib deps; --disable-xdmcp drops the libXdmcp link entirely).
	# --disable-install-setuid: this rock boots as root; no setuid Xfbdev.
	# Static / -no-pie / --disable-shared arrive via env/static.conf (*/*).
	#
	# tinyx is 2007-era kdrive C. Modern GCC (14+) promotes several K&R-isms
	# from warnings to HARD ERRORS by default — independent of -Werror (we
	# already pass --disable-werror). Demote exactly those back to warnings so
	# the ancient-but-correct code compiles. The global -I keeps the vendored
	# server headers (staged in src_prepare) on the search path for every subdir
	# regardless of that subdir's own -I flags.
	append-flags -Wno-error=implicit-int -Wno-error=implicit-function-declaration
	append-flags -Wno-error=int-conversion -Wno-error=incompatible-pointer-types
	append-cppflags -I"${S}/include"

	# -DKDRIVESERVER: tinyx's shipped include/dix-config.h.in is STALE — it has
	# no `#undef KDRIVESERVER` placeholder, so configure's AC_DEFINE(KDRIVESERVER)
	# under --enable-kdrive silently never lands in dix-config.h (autoheader
	# doesn't regenerate it here). Without it, dix/dixfonts.c compiles out
	# `BuiltinRegisterFpeFunctions()`, so the libXfont "built-ins" FPE is never
	# registered — and the on-disk FontFile FPE then mis-claims the "built-ins"
	# path and dies "could not open default font 'fixed'". Force the define so
	# Xfbdev can start fontless via `-fp built-ins` (SP-GUI G1 Step 3). -r1 is a
	# pure revbump to rebuild against this (Step-2's binpkg predates the fix).
	append-cppflags -DKDRIVESERVER
	econf \
		--enable-kdrive \
		--disable-xvesa \
		--enable-xfbdev \
		--disable-install-setuid \
		--disable-xdmcp \
		--disable-xdm-auth-1 \
		--disable-xres \
		--disable-screensaver \
		--disable-dbe \
		--disable-xf86bigfont \
		--disable-dpms \
		--disable-werror
}

src_install() {
	default

	# The rootfs is all-static i486; a dynamic or wrong-arch server would fail
	# at boot. Verify the shipped Xfbdev before it reaches the squashfs.
	local xbin="${ED}/usr/bin/Xfbdev"
	[[ -x "${xbin}" ]] || die "Xfbdev not installed at /usr/bin/Xfbdev"
	if command -v readelf >/dev/null 2>&1; then
		readelf -l "${xbin}" 2>/dev/null | grep -q 'INTERP' \
			&& die "Xfbdev is dynamically linked (env/static.conf -static did not stick)"
		readelf -h "${xbin}" 2>/dev/null | grep -qE 'Intel 80386|:.*386' \
			|| ewarn "Xfbdev ELF machine is not Intel 80386 — check the cross toolchain"
	fi

	dodoc README COPYING
}
