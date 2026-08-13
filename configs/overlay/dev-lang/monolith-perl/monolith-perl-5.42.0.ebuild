# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Static, -Uusedl Perl core (via arsv/perl-cross) for the Monolith"
HOMEPAGE="https://www.perl.org https://github.com/arsv/perl-cross"

# STRICT version pairing (spec D1): each perl-cross release ships a per-exact-
# version patchset (cnf/diffs/perl5-X.Y.Z/) for the perl versions it declares
# support for; using a perl release without a matching patchset risks silent
# "strangely broken" configure/miniperl failures per spec §5. Verified against
# the perl-cross upstream repo at release 1.6.4 (newest as of 2026-08-13,
# `gh api repos/arsv/perl-cross/releases`): 1.6.4's tree
# (cnf/diffs/perl5-5.42.0/, cnf/diffs/perl5-5.40.3/, ...) carries an explicit
# patchset for 5.42.0 — added one release earlier in 1.6.3 ("Much delayed
# release for perl 5.42.0", 2025-11-28) and still present/cumulative in 1.6.4
# — and 5.42.0 is the newest perl version with its own patchset directory in
# this release (5.42.0 > 5.40.3, the version 1.6.4's own release notes added).
# No 5.42.1/5.42.2/5.42.3/5.44.0 patchset exists yet in 1.6.4, so those are
# NOT "explicitly supported" by this rule even though newer tarballs exist on
# CPAN — pin the exact 5.42.0 + 1.6.4 pair recorded in versions.lock.
PC_PV="1.6.4"

SRC_URI="
	https://www.cpan.org/src/5.0/perl-${PV}.tar.xz
	https://github.com/arsv/perl-cross/releases/download/${PC_PV}/perl-cross-${PC_PV}.tar.gz
"
S="${WORKDIR}/perl-${PV}"

# Perl itself is dual Artistic/GPL-1+ (matches ::gentoo's dev-lang/perl LICENSE
# line verbatim). perl-cross is "free software licensed under the same terms
# as the original perl source" per its README, but it is a build-time-only
# overlay (configure/Makefile/cnf/*) that is never installed into DESTDIR —
# `emake install` only runs perl's own installperl/installman targets — so it
# needs no separate LICENSE/SRC_URI accounting here.
LICENSE="|| ( Artistic GPL-1+ )"
SLOT="0"
KEYWORDS="~amd64"

# Cannot run i486 target binaries in the (x86_64) build container, and
# perl-cross's own configure never runs target executables either (compile/
# link tests + hints only) — so there is nothing test-worthy that would even
# run natively. Acceptance is proven at boot-test time instead (spec §4).
RESTRICT="test"

src_prepare() {
	default

	# perl-cross's documented install method (its README's "Get perl and
	# perl-cross sources" section):
	#   tar -zxf perl-X.Y.Z.tar.gz && cd perl-X.Y.Z &&
	#   tar --strip-components=1 -zxf ../perl-cross-N.M.tar.gz
	# i.e. unpack perl-cross's tree directly OVER the vanilla perl source,
	# overwriting perl's own top-level Makefile/Makefile.SH machinery with
	# perl-cross's cross-aware configure + Makefile + cnf/. Portage's default
	# src_unpack has already extracted both SRC_URI tarballs into ${WORKDIR}
	# (perl-cross's release tarball has a single top-level perl-cross-${PC_PV}/
	# directory, confirmed via `tar tzf`), so `cp -a` of that already-extracted
	# tree's contents onto ${S} (cwd here) is the same operation as the
	# README's --strip-components=1 tar, just adapted to not re-extract.
	cp -a "${WORKDIR}/perl-cross-${PC_PV}/." . || die "perl-cross overlay onto perl source failed"
}

src_configure() {
	# perl-cross's arg parser (cnf/configure_args.sh) is a small hand-rolled
	# shell parser, NOT autotools/autoconf, and is invoked directly below
	# (never via the `econf` portage helper) — so env/static.conf's
	# EXTRA_ECONF ("--disable-shared --enable-static") is never appended to
	# this command line; EXTRA_ECONF is only ever consumed by `econf` itself.
	# Verified by reading configure_args.sh's option table: a bare
	# "--disable-shared" or "--enable-static" token matches none of its
	# recognised long options (with-*/set-*/use-*/host-*/static-mod=/
	# disable-mod=/all-static/...) and falls through to the final
	# `*) die "Unknown argument $a"` catch-all — so IF EXTRA_ECONF ever did
	# reach here (e.g. a future refactor routes this through econf), it would
	# hard-fail configure immediately and loudly, not silently misconfigure.
	# That is the #1 anticipated CI failure mode for this ebuild; the fix
	# (spec D1 Step 4) is env/perl-cross.conf overriding EXTRA_ECONF="" for
	# this package specifically, added ONLY after a real CI failure confirms
	# it's needed — not preemptively, per the plan.
	#
	# The static/no-PIE doctrine itself still applies: env/static.conf's
	# LDFLAGS ("-no-pie -static") and CFLAGS ("-no-pie -fno-pie") additions
	# are plain environment variables (not econf-gated) and are threaded
	# through explicitly via -Aldflags/-Accflags below.
	#
	# --all-static, NOT the design doc's literal "--static": verified against
	# `configure --help` and configure_args.sh's parsing table. A bare
	# "--static" token is treated as requiring a value (it is absent from the
	# parser's no-argument exception list, which is only
	# `help|regen*|mode|host|target|build|keeplog|[dehrsEKOSV]` and
	# `all-static|no-*`) — so with nothing attached, "--static" silently
	# swallows the NEXT command-line token as a bogus module-name list. Placed
	# where the design doc's representative snippet put it (immediately before
	# `-Accflags=...`/`-Aldflags=...`), that would have silently eaten our
	# CFLAGS and dropped it from the build with no error. "--all-static" is
	# the actually-documented flag ("Build all found XS modules as static
	# unless specified otherwise") and is in the no-argument exception list,
	# so it is safe to combine with any other flag in any order. It is also
	# the flag that does the work the global static doctrine needs here:
	# -Uusedl alone does NOT force perl's own core XS extensions (POSIX,
	# Fcntl, IO, Socket, ...) to build static — configure_mods.sh classifies
	# every XS-bearing ext/ dir as dynamic_ext by default regardless of
	# usedl, unless static_$sym or $allstatic is set. --all-static sets
	# $allstatic, which is exactly "every XS module baked in, none dynamic"
	# (global constraint) for the extensions bundled in perl core itself.
	#
	# -D_GNU_SOURCE (appended to ccflags): perl-cross link-detects memrchr,
	# setresuid, setresgid, eaccess (all present in musl) and sets their HAS_*
	# config symbols, but musl only DECLARES these GNU extensions when
	# _GNU_SOURCE is defined. On glibc perl adds -D_GNU_SOURCE itself (d_gnulibc);
	# musl isn't "gnulibc" so it doesn't — leaving perl.h/regcomp.c et al. with
	# implicit declarations, which GCC 14 treats as hard errors. Defining it is
	# the standard perl-on-musl fix (Buildroot/OpenWrt do the same).
	./configure \
		--target="${CHOST}" \
		--prefix=/usr \
		-Dcc="${CHOST}-gcc" \
		-Uusedl -Uusethreads -Duse64bitint -Duselargefiles \
		-Dman1dir=none -Dman3dir=none \
		-Accflags="${CFLAGS} -D_GNU_SOURCE" \
		-Aldflags="${LDFLAGS} -Wl,--allow-multiple-definition" \
		--all-static \
		|| die "perl-cross configure failed"

	# -Wl,--allow-multiple-definition (appended to ldflags): the `re` extension
	# recompiles parts of regcomp.c (as re_comp.c, with -DPERL_EXT_RE_BUILD) and
	# exports Perl_get_ANYOFHbbm_contents et al. — symbols also present in core
	# libperl.a(regcomp.o). In a normal -Dusedl perl `re` is a separate re.so, so
	# they never meet; under -Uusedl --all-static both land in one binary and
	# modern binutils rejects the duplicate strong symbols. The definitions come
	# from the SAME source, so taking the first is safe — this is the standard
	# static-perl workaround (Buildroot's static perl uses it too). Not put in
	# env/static.conf: it's a perl-static-`re` quirk, not a global doctrine.
}

# src_compile/src_install: EAPI 8 defaults (emake / emake DESTDIR="${D}"
# install) are sufficient — perl-cross ships a plain top-level GNU Makefile
# (overlaid in src_prepare) whose `install` target chains installperl +
# installman (skipped: man1dir/man3dir=none above) and honors $(DESTDIR),
# verified by reading Makefile directly. perl-cross builds its own miniperl
# from source (no pre-existing host perl required to bootstrap) using the
# build-host compiler for host-side codegen and ${CHOST}-gcc (set via -Dcc=
# above) for the target perl binary/extensions.
