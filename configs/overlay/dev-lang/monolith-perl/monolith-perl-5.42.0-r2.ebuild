# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Static, -Uusedl Perl (via arsv/perl-cross) + DBI/DBD::SQLite static_ext for the Monolith"
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

# DBI + DBD::SQLite (spec D4 / plan Task 3): current stable CPAN releases as
# of 2026-08-13 (`https://fastapi.metacpan.org/v1/release/DBI` and
# `.../release/DBD-SQLite`) — DBI 1.651 (HMBRAND, 2026-07-14) and DBD::SQLite
# 1.78 (ISHIGAKI, 2026-01-02). Both are baked into the perl binary via
# perl-cross's static_ext mechanism (see src_prepare/src_configure below) —
# there is no dynamic loader on this disc to `use DBI` a separate .so from.
DBI_PV="1.651"
DBD_SQLITE_PV="1.78"

SRC_URI="
	https://www.cpan.org/src/5.0/perl-${PV}.tar.xz
	https://github.com/arsv/perl-cross/releases/download/${PC_PV}/perl-cross-${PC_PV}.tar.gz
	https://www.cpan.org/authors/id/H/HM/HMBRAND/DBI-${DBI_PV}.tgz
	https://www.cpan.org/authors/id/I/IS/ISHIGAKI/DBD-SQLite-${DBD_SQLITE_PV}.tar.gz
"
S="${WORKDIR}/perl-${PV}"

# Perl itself is dual Artistic/GPL-1+ (matches ::gentoo's dev-lang/perl LICENSE
# line verbatim). perl-cross is "free software licensed under the same terms
# as the original perl source" per its README, but it is a build-time-only
# overlay (configure/Makefile/cnf/*) that is never installed into DESTDIR —
# `emake install` only runs perl's own installperl/installman targets — so it
# needs no separate LICENSE/SRC_URI accounting here. DBI and DBD::SQLite are
# both "the same terms as Perl itself" (Artistic/GPL-1+ dual license, per
# their own META.json `"license" : [ "perl_5" ]`) — no separate LICENSE line
# needed.
LICENSE="|| ( Artistic GPL-1+ )"
SLOT="0"
KEYWORDS="~amd64"

# Task 1 (P1): need /usr/${CHOST}/usr/{lib/libsqlite3.a,include/sqlite3.h} in
# the cross sysroot before this package's src_prepare/src_configure run, in
# case a future patch flips DBD::SQLite over to linking the system library
# (see the src_prepare comment on DBD::SQLite's Makefile.PL — the system-link
# code path is upstream dead code as of 1.78, so this DEPEND is not currently
# load-bearing for the build itself, but it keeps the ordering correct for
# when it becomes load-bearing, and documents the intended coupling).
DEPEND="dev-db/monolith-sqlite"

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

	# --- Task 3 (P3): stage DBI + DBD::SQLite as perl-cross static_ext ---
	#
	# perl-cross's sanctioned mechanism for third-party (non-core) CPAN
	# modules, per its own docs (arsv.github.io/perl-cross/modules.html,
	# "Build process for perl modules" — no equivalent text in README.md):
	# "To add a module to your build, unpack it into cpan/ directory before
	# running configure. Check naming scheme there: a module called
	# Some::Module should be placed in cpan/Some-Module." Verified against
	# cnf/configure_mods.sh (`for d in ext cpan dist; do extdir $d; done` —
	# configure walks cpan/ alongside perl's own ext/ and dist/ looking for
	# *.xs/*.c files to classify as XS modules) and cnf/configure__f.sh's
	# modsymname() (strips a leading ext|cpan|dist|lib/ path component and
	# maps `-`/`:`/`/` to `_`, lowercased — i.e. cpan/DBD-SQLite becomes the
	# symbol "dbd_sqlite" that --static-ext=DBD-SQLite below also resolves
	# to). This must run AFTER the perl-cross overlay above: perl-cross's
	# tree only replaces perl's top-level Makefile/configure/cnf machinery,
	# never touches cpan/ (which still holds perl's OWN bundled CPAN
	# modules, e.g. cpan/Scalar-List-Utils) — placing DBI/DBD-SQLite here
	# afterwards is purely additive and cannot be clobbered by the overlay.
	#
	# Portage's default src_unpack already extracted both SRC_URI tarballs
	# into ${WORKDIR} as DBI-${DBI_PV}/ and DBD-SQLite-${DBD_SQLITE_PV}/
	# (both single-top-level-dir tarballs, confirmed via `tar tzf`); rename
	# on copy into the cpan/<Some-Module> layout perl-cross's configure
	# expects.
	mkdir -p cpan/DBI cpan/DBD-SQLite || die
	cp -a "${WORKDIR}/DBI-${DBI_PV}/." cpan/DBI/ || die "staging DBI into cpan/DBI failed"
	cp -a "${WORKDIR}/DBD-SQLite-${DBD_SQLITE_PV}/." cpan/DBD-SQLite/ || die "staging DBD::SQLite into cpan/DBD-SQLite failed"

	# --- System libsqlite3.a vs bundled amalgamation (spec Task 3 Step 5) ---
	#
	# The plan's default mechanism for pointing DBD::SQLite at Task 1's
	# system libsqlite3.a is SQLITE_INC/SQLITE_LIB. Read DBD-SQLite-${DBD_SQLITE_PV}'s
	# own Makefile.PL before wiring that up, and found the ENTIRE system-
	# sqlite code path is dead code upstream:
	#
	#   my ($sqlite_local, $sqlite_base, $sqlite_lib, $sqlite_inc);
	#   if ( 0 ) {
	#       ...SQLITE_LOCATION/USE_LOCAL_SQLITE/SQLITE_INC/SQLITE_LIB parsing...
	#   } else {
	#       # Always the bundled one.
	#       $sqlite_local = 1;
	#   }
	#
	# with the author's own comment directly above it: "Note to Downstream
	# Packagers: This block is if ( 0 ) to discourage casual users building
	# against the system SQLite. We expect that anyone sophisticated enough
	# to use a system sqlite is also sophisticated enough to have a patching
	# system that can change the if ( 0 ) to if ( 1 )." Three more findings
	# that matter for that patch: (1) the parser reads raw @ARGV tokens
	# ("SQLITE_INC=...") from the `perl Makefile.PL` command line, NOT
	# %ENV — so exporting SQLITE_INC/SQLITE_LIB as plain env vars (as the
	# plan's representative snippet suggested) would be silently ignored
	# even with if(1); (2) OBJECT is `$(O_FILES)` (includes the bundled
	# sqlite3.c's object) when $sqlite_local is true and only drops to
	# 'SQLite.o dbdimp.o' when false — so a correct system-link patch must
	# also flip OBJECT or the final link duplicate-defines every sqlite3_*
	# symbol against the system .a (this disc's `--allow-multiple-definition`
	# escape hatch, used for perl's own `re` extension, is a same-source
	# duplicate; two different sqlite3.c's is not the same case and hasn't
	# been vetted here); (3) this file read + version-number check runs
	# during miniperl's Makefile.PL execution, which DOES run on the build
	# host with the cross sysroot mounted, so it isn't blocked by the
	# "can't run target binaries" constraint — this is a real, fixable
	# upstream limitation, not a cross-compile wall.
	#
	# Patching Makefile.PL plus verifying the OBJECT-list + link-time
	# consequences is real engineering that this task's instructions
	# explicitly say not to validate here (no build is run in this step —
	# CI is the only validator, and a wrong guess burns a full CI cycle,
	# which has already happened twice on this branch per the revbump
	# history). Per plan Task 3 Step 5, falling back to DBD::SQLite's
	# bundled amalgamation is an explicitly sanctioned outcome, not a
	# failure — so that's the path taken here: SQLITE_INC/SQLITE_LIB are
	# deliberately left UNSET, DBD::SQLite compiles its own vendored
	# sqlite3.c exactly as every other unpatched CPAN consumer does.
	#
	# SBOM note (spec: "the disc ships no untracked code"): DBD::SQLite
	# ${DBD_SQLITE_PV}'s bundled sqlite3.h reports `#define SQLITE_VERSION
	# "3.51.1"` — this disc therefore ships TWO independently-built copies
	# of SQLite: Task 1's monolith-sqlite 3.53.4 (standalone `sqlite3` CLI +
	# libsqlite3.a) and this embedded 3.51.1 (compiled directly into the
	# perl binary, reachable only via `perl -MDBI`). Both are built
	# THREADSAFE=0 — Task 1 sets it explicitly via CPPFLAGS, and
	# DBD::SQLite's Makefile.PL sets -DTHREADSAFE=0 itself whenever
	# `!$Config{usethreads}` (true here: -Uusethreads above) — and both
	# effectively omit runtime extension loading: DBD::SQLite's Makefile.PL
	# adds -DSQLITE_OMIT_LOAD_EXTENSION whenever `!$Config{usedl}` (true
	# here: -Uusedl above), matching Task 1's explicit
	# -DSQLITE_OMIT_LOAD_EXTENSION=1 without any extra flag needed on our
	# side — the disc's no-dynamic-loader doctrine falls out of DBD::SQLite's
	# own $Config-awareness for free.
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
	# --static-ext=DBI,DBD-SQLite (spec/plan Task 3): explicit belt-and-
	# suspenders alongside --all-static above. --all-static (cnf/
	# configure_mods.sh: `elif [ "$1" = "xs" -a -n "$allstatic" ]`) already
	# forces every discovered XS module — including third-party ones staged
	# under cpan/ in src_prepare above — onto the static_ext list, so this
	# flag changes nothing functionally today. It is added anyway to
	# document intent directly at the configure call site and to keep DBI +
	# DBD::SQLite static even if --all-static is ever narrowed later.
	# Verified spelling against cnf/configure_args.sh's option table:
	# `static-mod|static-ext|static-modules|static)` accepts a
	# comma-separated list, each entry run through the same modsymname()
	# used for module discovery (see src_prepare) — so "DBI" and
	# "DBD-SQLite" (the cpan/ directory names, not the "::"-form perl
	# module names) are the correct tokens here.
	./configure \
		--target="${CHOST}" \
		--prefix=/usr \
		-Dcc="${CHOST}-gcc" \
		-Uusedl -Uusethreads -Duse64bitint -Duselargefiles \
		-Dman1dir=none -Dman3dir=none \
		-Accflags="${CFLAGS} -D_GNU_SOURCE -DNO_LOCALE" \
		-Aldflags="${LDFLAGS} -Wl,--allow-multiple-definition" \
		--all-static \
		--static-ext=DBI,DBD-SQLite \
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
