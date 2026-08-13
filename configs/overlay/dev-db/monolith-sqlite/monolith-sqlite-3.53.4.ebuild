# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit flag-o-matic

DESCRIPTION="SQLite (amalgamation) — static sqlite3 CLI + libsqlite3.a for the Monolith"
HOMEPAGE="https://sqlite.org"

# The amalgamation tarball, NOT ::gentoo's dev-db/sqlite: Gentoo's sqlite
# ebuild BDEPENDs dev-lang/tcl (its test/doc tooling), which is unnecessary
# cross-tarpit risk for a package we only want as one compiled C file. The
# "autoconf" bundle ships sqlite3.c/sqlite3.h/shell.c pre-amalgamated plus a
# small autosetup-driven ./configure — no tcl anywhere in its own dependency
# chain. SQLite encodes ${PV} (3.53.4) as 3530400 (X.YY.ZZ00) in its own
# filenames; that encoded string does not derive cleanly from ${PV} so it is
# spelled out literally here, current as of https://sqlite.org/download.html.
MY_PV="3530400"
SRC_URI="https://sqlite.org/2026/sqlite-autoconf-${MY_PV}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/sqlite-autoconf-${MY_PV}"

# SQLite is public domain (see the "The author disclaims copyright" blurb in
# sqlite3.c and https://sqlite.org/copyright.html) — not GPL/MIT/BSD.
LICENSE="public-domain"
SLOT="0"
KEYWORDS="~amd64"

src_configure() {
	# Amalgamation compile-time feature defines (spec D3): no threads (this
	# rootfs never runs sqlite from more than one thread at a time), no
	# runtime-loadable extensions (no dlopen on this all-static disc), and
	# FTS5 + JSON1 on for the guestbook-era consumers in monolith-perl.
	append-cppflags -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
		-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1

	# -Os comes from the global CFLAGS. econf inherits EXTRA_ECONF
	# ("--disable-shared --enable-static") from env/static.conf via the
	# */* catch-all in package.env/cross-compile — do NOT repeat those flags
	# here. Disable the optional readline/editline-backed CLI line editor (no
	# such libs wired into this cross sysroot) and dlopen-based extension
	# loading at the shell level (belt-and-suspenders with the CPPFLAGS above).
	econf --disable-editline --disable-readline --disable-dynamic-extensions
}

# src_compile/src_install: EAPI 8 defaults (emake / emake DESTDIR="${D}" install)
# are sufficient. The amalgamation's autosetup-generated Makefile chains
# install-lib (libsqlite3.a, gated on ENABLE_LIB_STATIC which --enable-static
# turns on), install-shell (the sqlite3 CLI binary), install-headers
# (sqlite3.h + sqlite3ext.h) and install-pc (pkg-config file) all into the
# top-level `install` target — verified by reading Makefile.in in this
# release's tarball, so no dolib.a/doheader override is needed here.
