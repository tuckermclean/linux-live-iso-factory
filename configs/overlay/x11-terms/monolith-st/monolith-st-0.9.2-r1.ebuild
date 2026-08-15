# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit toolchain-funcs

DESCRIPTION="st (suckless terminal), ported off Xft/fontconfig to core X11 bitmap fonts"
HOMEPAGE="https://st.suckless.org"

SRC_URI="https://dl.suckless.org/st/st-0.9.2.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/st-0.9.2"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

# The disc forbids Xft/fontconfig/freetype entirely (GUI spec — bitmap fonts
# only). files/st-0.9.2-core-fonts.patch replaces the ENTIRE Xft/fontconfig
# render layer in x.c with core X11 (XLoadQueryFont / XChar2b /
# XDrawImageString16) and repoints config.def.h's `font` at an XLFD instead
# of a fontconfig name string. See that patch's header comment + the
# feat/gui-g2 commit message for the full list of rendering-correctness
# simplifications made (single face for bold via "-medium-"->"-bold-" XLFD
# substitution with graceful fallback to regular, italic reuses the regular
# face, codepoints above U+FFFF draw as '?', ATTR_WIDE/CJK cells are not
# double-width-aware since the bitmap font has no wide glyphs).
DEPEND="
	x11-libs/libX11
	x11-libs/libXext
"
RDEPEND="
	${DEPEND}
"
# RUNTIME font (the iso10646-1 `fixed` XLFD in config): media-fonts/font-misc-misc.
# Added back once st's de-Xft cross+static COMPILE is validated in isolation —
# font-misc-misc is a separate cross concern (mkfontdir/font-util host tooling)
# and is not needed to build st, only to run it.
# RDEPEND+=" media-fonts/font-misc-misc"
BDEPEND="virtual/pkgconfig"

PATCHES=( "${FILESDIR}/st-0.9.2-core-fonts.patch" )

src_prepare() {
	default
	# Point st at the font NAME "fixed" — the libXfont builtin 6x13 the Xfbdev
	# server already carries via `-fp built-ins` (no font files on the disc).
	# The patch defaults to an iso10646-1 XLFD that only media-fonts/font-misc-misc
	# provides; "fixed" (iso8859-1/Latin-1) needs no font package and is plenty
	# for an ASCII/Latin TTY. -r1 revbump busts the -r0 binpkg cache.
	sed -i 's|^static char \*font = .*|static char *font = "fixed";|' config.def.h \
		|| die "failed to repoint st font to the builtin 'fixed'"
	grep -q 'char \*font = "fixed";' config.def.h || die "font sed did not take"
}

src_compile() {
	# config.mk's X11INC/X11LIB default to legacy /usr/X11R6/{include,lib}
	# paths that don't exist in this Gentoo cross sysroot. Drive the flags from
	# the CROSS pkg-config instead. Critically use `--static`: this rootfs links
	# everything static (env/static.conf */* → -static), and a static libX11.a
	# does NOT auto-pull its own deps — without Libs.private the link dies on
	# undefined xcb_*/Xau/Xdmcp symbols. `pkg-config --static --libs x11 xext`
	# emits the full transitive set (-lX11 -lxcb -lXau -lXdmcp -lXext ...).
	# Only X11/Xext + their deps — no -lXft, no fontconfig/freetype anywhere.
	# +openpty lives in musl libc but keep -lutil (empty musl compat stub).
	# st's config.mk hardcodes `CC = c99`, which resolves to the HOST compiler
	# (x86-64 default + -fcf-protection) and ignores the cross toolchain — it
	# dies "CPU does not support x86-64" on the -march=i486 CFLAGS. Force the
	# cross CC (i486-linux-musl-gcc) so st builds for the target.
	local pc="$(tc-getPKG_CONFIG)"
	emake \
		CC="$(tc-getCC)" \
		INCS="$(${pc} --cflags x11 xext)" \
		LIBS="$(${pc} --static --libs x11 xext) -lutil"
}

src_install() {
	dobin st
	doman st.1
	dodoc README
}
