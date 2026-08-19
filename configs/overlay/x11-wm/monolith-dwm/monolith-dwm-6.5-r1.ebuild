# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit toolchain-funcs

DESCRIPTION="dwm (suckless dynamic window manager), ported off Xft/fontconfig to core X11 bitmap fonts"
HOMEPAGE="https://dwm.suckless.org"

SRC_URI="https://dl.suckless.org/dwm/dwm-6.5.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/dwm-6.5"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

# The disc forbids Xft/fontconfig/freetype entirely (GUI spec — bitmap fonts
# only) and ships no libXinerama. files/dwm-6.5-core-fonts.patch rewrites dwm's
# whole font/color/text layer (drw.c/drw.h) off Xft onto core X11
# (XLoadQueryFont / XFontStruct / XChar2b / XDrawString16 / XTextWidth16,
# XColor via XParseColor+XAllocColor) and drops the lone Xft include from dwm.c.
# Xinerama is compiled out at build time (XINERAMAFLAGS= below). Same de-Xft
# treatment as x11-terms/monolith-st; links ONLY libX11 (+ its transitive
# static xcb/Xau/Xdmcp), no Xft/Xinerama/Xext.
DEPEND="x11-libs/libX11"
RDEPEND="${DEPEND}"
# RUNTIME font is the libXfont builtin "fixed" the Xfbdev server carries via
# `-fp built-ins` — no font package needed (see monolith-st's note).
BDEPEND="virtual/pkgconfig"

PATCHES=( "${FILESDIR}/dwm-6.5-core-fonts.patch" )

src_prepare() {
	default
	# Point dwm's bar font (and the dmenu spawn cmd's -fn) at the builtin
	# "fixed" — the libXfont 6x13 the Xfbdev server already carries. The stock
	# config names "monospace:size=10", a fontconfig string this de-Xft build
	# cannot parse. dwm auto-generates config.h from config.def.h at build.
	sed -i \
		-e 's|^static const char \*fonts\[\][[:space:]]*=.*|static const char *fonts[] = { "fixed" };|' \
		-e 's|^static const char dmenufont\[\][[:space:]]*=.*|static const char dmenufont[]       = "fixed";|' \
		config.def.h || die "failed to repoint dwm fonts to the builtin 'fixed'"
	grep -q '{ "fixed" }' config.def.h || die "fonts sed did not take"
}

src_compile() {
	# config.mk defaults X11INC/X11LIB to legacy /usr/X11R6 paths absent from
	# this cross sysroot and hard-links -lXft -lfontconfig -lXinerama. Drive the
	# flags from the CROSS pkg-config instead, X11-only. `--static` on pkg-config
	# is required: a static libX11.a does NOT auto-pull its deps — --static emits
	# the full transitive set (-lX11 -lxcb -lXau -lXdmcp). XINERAMAFLAGS= drops
	# -DXINERAMA (no libXinerama on the disc). CC: the Makefile hardcodes `cc`
	# (the HOST x86-64 compiler); force the cross toolchain so dwm builds i486.
	#
	# -r1: FORCE `-static` on the link explicitly. dwm's Makefile hard-assigns
	# `LDFLAGS = ${LIBS}`, which SHADOWS the environment's injected -static
	# (env/static.conf */* → -static) — unlike st, whose Makefile references
	# $(LDFLAGS) and so keeps it. Without this override dwm links DYNAMIC and, on
	# the all-static rootfs (no ld.so / libc.so), fails at boot as `dwm: not
	# found` (exit 127) — the GUI boot-test's black screen, and the lone hit in
	# static-audit's "found 1 dynamically linked". Overriding LDFLAGS on the
	# emake command line wins over config.mk's assignment; carry the libs in it
	# too, since the link rule is `${CC} -o dwm ${OBJ} ${LDFLAGS}`.
	local pc="$(tc-getPKG_CONFIG)"
	local xlibs="$(${pc} --static --libs x11)"
	emake \
		CC="$(tc-getCC)" \
		INCS="$(${pc} --cflags x11)" \
		LIBS="${xlibs}" \
		LDFLAGS="-static ${xlibs}" \
		XINERAMAFLAGS=
}

src_install() {
	dobin dwm
	doman dwm.1
	dodoc README
}
