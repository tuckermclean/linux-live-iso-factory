# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Static, -Uusedl Perl (via arsv/perl-cross) + CGI.pm for the Monolith"
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

# CGI.pm rider (spec D5 / plan Task 4): removed from perl core in 5.22, and
# needed for the guestbook's param()/header(). D5's trap is real and CONFIRMED
# against the current CPAN release, not just a hypothetical: fetched
# raw.githubusercontent.com/leejo/CGI.pm/master/Makefile.PL for the newest
# release (CGI 4.72, LEEJO, 2026-05-05) and its PREREQ_PM lists
# 'HTML::Entities' => 3.69 as a hard runtime dependency. HTML::Entities.pm is
# itself pure-perl, but it ships INSIDE the HTML-Parser CPAN distribution
# alongside HTML::Parser's XS .xs/.c sources — one tarball, one Makefile.PL,
# one build; there is no way to pull in HTML::Entities without also building
# HTML-Parser's XS component, which needs a working dlopen/.so pipeline this
# -Uusedl all-static perl does not have. Walked CGI.pm's own Changes file:
# the HTML::Entities dependency was introduced in 4.11 (2014-12-02, "escapeHTML
# (and unescapeHTML) have been refactored to use the functions exported by the
# HTML::Entities module") — every 4.x release from 4.11 onward inherits it.
# 4.10 (2014-11-27, one release earlier) is the last version before that
# refactor; fetched ITS Makefile.PL too and confirmed PREREQ_PM is exactly
# Carp/Exporter/base/constant/overload/strict/utf8/warnings/File::Spec/if/
# parent/File::Temp — all of them core-perl, pure-perl modules already inside
# this same tree, none XS. Downloaded the actual CGI-4.10.tar.gz and grepped
# the full tarball listing for *.xs/*.c/*.h: none exist. So CGI.pm 4.10 is the
# pin: newest release that is provably pure-perl end to end. It predates a few
# post-2014 bugfixes/security hardenings unrelated to param()/header() (the
# only two APIs the guestbook needs, per spec D5's own framing: "a 1996
# guestbook needs param() and header(), not the kitchen sink") — noted as a
# risk below and in the P5 report, not hidden.
CGI_PV="4.10"

SRC_URI="
	https://www.cpan.org/src/5.0/perl-${PV}.tar.xz
	https://github.com/arsv/perl-cross/releases/download/${PC_PV}/perl-cross-${PC_PV}.tar.gz
	https://cpan.metacpan.org/authors/id/L/LE/LEEJO/CGI-${CGI_PV}.tar.gz
"
S="${WORKDIR}/perl-${PV}"

# Perl itself is dual Artistic/GPL-1+ (matches ::gentoo's dev-lang/perl LICENSE
# line verbatim). perl-cross is "free software licensed under the same terms
# as the original perl source" per its README, but it is a build-time-only
# overlay (configure/Makefile/cnf/*) that is never installed into DESTDIR —
# `emake install` only runs perl's own installperl/installman targets — so it
# needs no separate LICENSE/SRC_URI accounting here. CGI.pm is licensed
# "under the same terms as Perl itself" per its own META.yml/META.json
# (`"license" : [ "perl_5" ]`) — same Artistic/GPL-1+ dual license already
# declared below, no separate LICENSE line needed.
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

	# --- CGI.pm rider (spec D5 / plan Task 4) ---
	#
	# perl-cross's sanctioned mechanism for third-party CPAN modules is to
	# unpack them into cpan/<Some-Module> before configure runs (see the
	# module-naming convention documented at arsv.github.io/perl-cross/
	# modules.html and the DBI/DBD::SQLite precedent this ebuild carried
	# briefly on this branch — reverted, see world/comment below, but the
	# staging mechanism itself was sound and is reused here). Portage's
	# default src_unpack already extracted CGI-${CGI_PV}.tar.gz into
	# ${WORKDIR}/CGI-${CGI_PV}/ (single top-level dir, confirmed via
	# `tar tzf`); rename on copy into the cpan/CGI layout configure expects.
	#
	# Unlike the reverted DBI/DBD::SQLite bake, CGI.pm needs NO --static-ext
	# entry: perl-cross's own docs (modules.html) describe cnf/configure_mods.sh
	# classifying every cpan/ext/dist module into exactly one of $nonxs_ext
	# (no .xs/.c sources — CGI.pm's tarball has none, verified: `tar tzf
	# CGI-4.10.tar.gz | grep -E '\.xs$|\.c$|\.h$'` is empty) or $static_ext/
	# $dynamic_ext (XS modules). nonxs_ext modules skip compilation entirely —
	# miniperl runs their Makefile.PL, a normal Makefile is generated, and the
	# standard MakeMaker pm_to_blib step copies the .pm files into the lib
	# tree — with no static/dynamic distinction to make in the first place,
	# because there is no compiled artifact to link statically OR
	# dynamically. This is exactly the DBI-mechanism's chicken-and-egg
	# problem (a static_ext module needing an ALREADY-BUILT sibling module at
	# ITS OWN configure time) sidestepped: CGI.pm has no such dependency
	# (its own prereqs are all core perl already present in this same tree,
	# see the CGI_PV comment above), so plain nonxs_ext discovery is
	# sufficient and no perl-cross flag is needed at all.
	mkdir -p cpan/CGI || die
	cp -a "${WORKDIR}/CGI-${CGI_PV}/." cpan/CGI/ || die "staging CGI.pm into cpan/CGI failed"
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
	#
	# -DNO_LOCALE (appended to ccflags): perl-cross 1.6.4 hardcodes a glibc
	# locale profile — cnf/configure_misc.sh sets
	# d_perl_lc_all_uses_name_value_pairs='define' and leaves the positional
	# separator/category-position map empty, because it can't RUN a target probe
	# to learn musl's format. musl's setlocale(LC_ALL,"") returns a POSITIONAL
	# composite ("C.UTF-8;C;C;C;C;C" — musl only does UTF-8 for LC_CTYPE, the rest
	# stay C), so perl parsed it as name=value and panicked at boot in locale.c:
	# "'C.UTF-8;C;C;C;C;C' needs an '=' to split name=value". Undefining just the
	# name_value macro is NOT enough (the positional parser then has no separator
	# or position map), and perl-cross regenerates config.h from config.sh during
	# make, so post-configure file patches don't stick. -DNO_LOCALE is perl's
	# OWN sanctioned escape (documented in locale.c: "useful on platforms where
	# the libc setlocale() is buggy"): it compiles out the whole USE_LOCALE
	# machinery so perl never calls setlocale — no composite, no panic. It is
	# PERL-SCOPED (every other tool keeps its C.UTF-8, unlike a global LC_ALL=C),
	# and perl's internal Unicode (use utf8, -C IO layers, unicore uc()/lc()) is
	# independent of USE_LOCALE, so the utf8 acceptance smoke still passes. This
	# single-user disc has no need for locale-aware collation/number formatting.
	./configure \
		--target="${CHOST}" \
		--prefix=/usr \
		-Dcc="${CHOST}-gcc" \
		-Uusedl -Uusethreads -Duse64bitint -Duselargefiles \
		-Dman1dir=none -Dman3dir=none \
		-Accflags="${CFLAGS} -D_GNU_SOURCE -DNO_LOCALE" \
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

src_compile() {
	# perl-cross builds its own miniperl from source (host compiler for
	# host-side codegen; ${CHOST}-gcc for the target perl/extensions).
	emake

	# perl-cross's `all` target LINKS the perl binary (baking every static
	# extension's XS into libperl.a) but does NOT reliably run each static
	# extension's `pm_to_blib` — so installperl later ships a perl with the XS
	# baked in yet the modules' pure-perl .pm MISSING (Fcntl.pm, File::Spec,
	# Cwd, ... => "Can't locate X.pm in @INC" at runtime, which breaks
	# File::Temp and therefore CGI.pm). The Makefile's `modules` target
	# (modules -> extensions -> {nonxs,dynamic,static}_ext -> */pm_to_blib)
	# stages them; run it explicitly so `default`'s installperl has the .pm to
	# install. (Confirmed via a DIAG build: Fcntl.pm existed only at
	# ext/Fcntl/Fcntl.pm, never staged to any blib/.)
	emake modules
}

src_install() {
	# `emake DESTDIR="${D}" install` — chains installperl + installman
	# (installman skipped: man1dir/man3dir=none in src_configure). This is
	# where CGI.pm's .pm files (staged into cpan/CGI, discovered as
	# $nonxs_ext by configure) land in the installed lib tree alongside
	# perl's own core modules — same installperl codepath, no separate step.
	default

	# --- Backfill baked-XS .pm that perl-cross omits ---
	#
	# perl-cross bakes several bootstrap/core XS extensions (Fcntl, Cwd &
	# File::Spec via PathTools, and likely others) into libperl.a but does NOT
	# install their pure-perl .pm into the target lib tree. Without the .pm,
	# `use Fcntl` / `use File::Spec` die "Can't locate ...", which breaks
	# File::Temp and therefore CGI.pm — and much path/flag-handling perl in
	# general. Each built extension staged its .pm under <ext>/blib/lib during
	# the build; copy every such tree into the install lib so all baked modules
	# are actually usable. Runs BEFORE the prune below, so any *.pod these
	# re-introduce get removed there.
	local privlib="${ED}/usr/lib/perl5/5.42.0"
	# perl stages every built module's .pm under ${S}/lib during the build
	# (core ext/ modules like Fcntl land here, not in a blib/lib); installperl
	# is meant to copy these to privlib but perl-cross's static install skips the
	# baked-XS ones. Backfill from BOTH the top-level staging lib and each
	# CPAN/dist extension's blib/lib to catch every layout.
	[[ -d "${S}/lib" ]] && cp -a "${S}/lib/." "${privlib}/"
	local blib
	while IFS= read -r -d '' blib; do
		cp -a "${blib}/." "${privlib}/" || die "backfilling ${blib} failed"
	done < <(find "${S}" -type d -path '*/blib/lib' -print0)
	# Verify the load-bearing bootstrap modules CGI.pm's File::Temp needs; on a
	# miss, print where the .pm actually lives in the build tree so the fix is
	# one targeted edit, not another blind cycle.
	local m
	for m in Fcntl.pm File/Spec.pm File/Spec/Unix.pm Cwd.pm; do
		if [[ ! -f "${privlib}/${m}" ]]; then
			eerror "MONOLITH-PERL backfill: ${m} still missing; build-tree candidates:"
			find "${S}" -name "$(basename "${m}")" -printf '  %p\n' 2>/dev/null | head -10
			die "backfill incomplete: ${m} still missing"
		fi
	done
	einfo "MONOLITH-PERL: backfilled baked-XS .pm (Fcntl, File::Spec, Cwd, ...) omitted by perl-cross"

	# --- Prune pass (spec §3 size budget) ---
	#
	# Budget: perl binary (static, -Os, stripped) <= 12 MiB; installed
	# /usr/lib/perl5 tree <= 35 MiB uncompressed (spec §3). "When in doubt,
	# keep" — every removal below targets a category that is either fully
	# unreachable on this disc (CPAN/CPANPLUS: no CPAN client, Global
	# Constraints) or has a working, already-shipped runtime replacement
	# (perl's own .pod/Pod::* doc-rendering pipeline vs. this disc's mandoc +
	# man-pages, proven live by smoke_man). lib/unicore is deliberately NOT
	# touched: smoke_perl_utf8 exercises uc() on a non-ASCII codepoint, which
	# reads unicore's runtime case-folding tables directly.
	local libdir="${ED}/usr/lib/perl5"
	if [[ -d "${libdir}" ]]; then
		# 1. *.pod — perl's OWN documentation source (perlfunc.pod,
		#    perlguts.pod, CGI.pm's own embedded POD, ...). man1dir/man3dir=
		#    none (src_configure) only stops installman from RENDERING man
		#    pages from these; installperl still copies the raw .pod source
		#    files into the lib tree regardless. Dropped: no perldoc/man
		#    pipeline consumes them here (mandoc + man-pages, a separate
		#    non-perl source, is this disc's man reader per smoke_man); `perl
		#    -V` reads compiled-in %Config, not .pod.
		find "${libdir}" -name '*.pod' -type f -delete

		# 2. CPAN/CPANPLUS client toolchain — dozens of .pm files
		#    implementing a package-fetching client this disc will never
		#    invoke (Global Constraints: "No CPAN client on the disc"; no
		#    persistent install target for it to manage anyway). Matched by
		#    directory name at any depth (core lib AND any site_perl/
		#    vendor_perl subtree could each carry a copy) plus the top-level
		#    CPAN.pm/CPANPLUS.pm entry-point files living as siblings, not
		#    inside those directories.
		find "${libdir}" -depth -type d \( -name CPAN -o -name CPANPLUS \) -exec rm -rf {} +
		find "${libdir}" -type f \( -name 'CPAN.pm' -o -name 'CPANPLUS.pm' \) -delete

		# 3. ExtUtils::* — the XS/Makefile.PL BUILD toolchain (MakeMaker,
		#    ParseXS, Manifest, Install, ...). This perl was built once,
		#    offline, at image-build time; it never runs `perl Makefile.PL`
		#    again, and there is no dlopen for any resulting .so even if it
		#    did (Global Constraints). Not needed by CGI.pm or the guestbook
		#    at runtime (CGI 4.10's own PREREQ_PM has no ExtUtils:: entry).
		find "${libdir}" -depth -type d -name ExtUtils -exec rm -rf {} +

		# 4. Pod::* — POD *processing* modules (Pod::Html, Pod::Man,
		#    Pod::Text, Pod::Perldoc, Pod::Usage, ...), distinct from the
		#    .pod *content* files removed in (1). Same rationale as (1): no
		#    perldoc, no CPAN, no man-rendering pipeline runs on this perl.
		#    Neither CGI.pm 4.10 nor the guestbook CGI use Pod:: at runtime.
		find "${libdir}" -depth -type d -name Pod -exec rm -rf {} +
	fi

	# 5. h2ph / h2xs — module-AUTHORING utility scripts (h2ph: C headers ->
	#    perl .ph; h2xs: scaffold a new XS module). Meaningless on a disc
	#    with no compiler-facing XS workflow at runtime (static, -Uusedl, no
	#    new modules are ever built here). Live in usr/bin, not the lib tree.
	rm -f "${ED}/usr/bin/h2ph" "${ED}/usr/bin/h2xs"

	# --- Size measurement (spec §3: "Measure and record both in the report") ---
	#
	# Grep-able MONOLITH-PERL-SIZE markers so these land in the CI build log
	# verbatim (spec instruction: "echo them during build ... so they land in
	# the build log").
	local perlbin="${ED}/usr/bin/perl"
	if [[ -L "${perlbin}" ]]; then
		# installperl conventionally installs the real ELF as a versioned
		# name (e.g. perl5.42.0) and symlinks the bare `perl` to it; resolve
		# so strip/measurement target the actual binary, not the symlink.
		local target
		target="$(readlink -f "${perlbin}")"
		[[ -f "${target}" ]] && perlbin="${target}"
	fi
	if [[ -f "${perlbin}" ]]; then
		# Explicitly strip here rather than relying solely on Portage's
		# post-src_install auto-strip pass (which runs AFTER this function
		# returns, via the QA instprep step) — otherwise the size logged
		# below would be the unstripped intermediate, not the true final
		# size. ${CHOST}-strip matches this ebuild's existing ${CHOST}-gcc
		# convention (bare-CHOST-tool style, no toolchain-funcs.eclass
		# inherit elsewhere in this overlay — see rl144's ${CHOST}-gcc use).
		"${CHOST}-strip" "${perlbin}" 2>/dev/null \
			|| ewarn "MONOLITH-PERL-SIZE: ${CHOST}-strip failed on ${perlbin}; size below may be unstripped"
		einfo "MONOLITH-PERL-SIZE: perl binary (stripped) $(basename "${perlbin}") = $(du -h "${perlbin}" | cut -f1) ($(stat -c%s "${perlbin}") bytes) — budget <=12MB"
	else
		ewarn "MONOLITH-PERL-SIZE: could not locate the installed perl binary to measure"
	fi

	if [[ -d "${libdir}" ]]; then
		einfo "MONOLITH-PERL-SIZE: /usr/lib/perl5 tree (post-prune) = $(du -sh "${libdir}" | cut -f1) — budget <=35MB"
	fi

}
