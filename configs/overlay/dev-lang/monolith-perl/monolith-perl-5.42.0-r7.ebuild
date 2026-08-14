# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Static, -Uusedl Perl (via arsv/perl-cross) + CGI.pm + DBI/DBD::SQLite for the Monolith"
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

# DBI + DBD::SQLite un-defer (SP5 P3, was deferred at -r2/-r5 — see the
# reverted commit 3867320 and versions.lock's -r2 history note this replaces).
# Re-verified current as of 2026-08-14 (`fastapi.metacpan.org/v1/release/DBI`
# and `.../release/DBD-SQLite`): DBI 1.651 (HMBRAND, 2026-07-14) and
# DBD::SQLite 1.78 (ISHIGAKI, 2026-01-02) are STILL the newest CPAN releases
# — no version bump needed, the tarballs and their Manifest hashes below are
# byte-identical to the reverted attempt (re-fetched and re-hashed to
# confirm). Both are baked into the perl binary via perl-cross's static_ext
# mechanism (see src_prepare/src_configure below) — there is no dynamic
# loader on this disc to `use DBI` a separate .so from.
DBI_PV="1.651"
DBD_SQLITE_PV="1.78"

SRC_URI="
	https://www.cpan.org/src/5.0/perl-${PV}.tar.xz
	https://github.com/arsv/perl-cross/releases/download/${PC_PV}/perl-cross-${PC_PV}.tar.gz
	https://cpan.metacpan.org/authors/id/L/LE/LEEJO/CGI-${CGI_PV}.tar.gz
	https://www.cpan.org/authors/id/H/HM/HMBRAND/DBI-${DBI_PV}.tgz
	https://www.cpan.org/authors/id/I/IS/ISHIGAKI/DBD-SQLite-${DBD_SQLITE_PV}.tar.gz
"
S="${WORKDIR}/perl-${PV}"

# Perl itself is dual Artistic/GPL-1+ (matches ::gentoo's dev-lang/perl LICENSE
# line verbatim). perl-cross is "free software licensed under the same terms
# as the original perl source" per its README, but it is a build-time-only
# overlay (configure/Makefile/cnf/*) that is never installed into DESTDIR —
# `emake install` only runs perl's own installperl/installman targets — so it
# needs no separate LICENSE/SRC_URI accounting here. CGI.pm, DBI, and
# DBD::SQLite are all licensed "under the same terms as Perl itself" per
# their own META.yml/META.json (`"license" : [ "perl_5" ]`) — same
# Artistic/GPL-1+ dual license already declared below, no separate LICENSE
# line needed.
LICENSE="|| ( Artistic GPL-1+ )"
SLOT="0"
KEYWORDS="~amd64"

# Task 1 (P1) produced /usr/${CHOST}/usr/{lib/libsqlite3.a,include/sqlite3.h}
# in the cross sysroot. DBD::SQLite does NOT currently link against them (see
# the src_prepare comment below — its Makefile.PL keeps the system-sqlite
# path behind a permanent upstream `if ( 0 )`), so this DEPEND is not
# load-bearing for the build today; kept so the sysroot ordering is correct
# if a future patch flips that dead code on, and to document the intended
# coupling (same rationale the reverted -r2 attempt recorded).
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

	# --- CGI.pm rider (spec D5 / plan Task 4) ---
	#
	# perl-cross's sanctioned mechanism for third-party CPAN modules is to
	# unpack them into cpan/<Some-Module> before configure runs (see the
	# module-naming convention documented at arsv.github.io/perl-cross/
	# modules.html; the DBI/DBD::SQLite bake below uses the same mechanism).
	# Portage's default src_unpack already extracted CGI-${CGI_PV}.tar.gz into
	# ${WORKDIR}/CGI-${CGI_PV}/ (single top-level dir, confirmed via
	# `tar tzf`); rename on copy into the cpan/CGI layout configure expects.
	#
	# Unlike the DBI/DBD::SQLite bake below, CGI.pm needs NO --static-ext
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
	# ITS OWN configure time, unblocked below) sidestepped: CGI.pm has no such
	# dependency (its own prereqs are all core perl already present in this
	# same tree, see the CGI_PV comment above), so plain nonxs_ext discovery
	# is sufficient and no perl-cross flag is needed at all.
	mkdir -p cpan/CGI || die
	cp -a "${WORKDIR}/CGI-${CGI_PV}/." cpan/CGI/ || die "staging CGI.pm into cpan/CGI failed"

	# --- DBI + DBD::SQLite bake (SP5 P3, un-deferred) ---
	#
	# Same cpan/<Some-Module> staging convention as CGI.pm above, but these
	# ARE static_ext (both ship .xs/.c: DBI.xs, and SQLite.xs + the bundled
	# sqlite3.c amalgamation — see the SQLite-amalgamation note further down).
	mkdir -p cpan/DBI cpan/DBD-SQLite || die
	cp -a "${WORKDIR}/DBI-${DBI_PV}/." cpan/DBI/ || die "staging DBI into cpan/DBI failed"
	cp -a "${WORKDIR}/DBD-SQLite-${DBD_SQLITE_PV}/." cpan/DBD-SQLite/ || die "staging DBD::SQLite into cpan/DBD-SQLite failed"

	# --- System libsqlite3.a vs bundled amalgamation ---
	#
	# Read DBD-SQLite-${DBD_SQLITE_PV}'s own Makefile.PL: the ENTIRE
	# system-sqlite code path is dead code upstream —
	#   my ($sqlite_local, $sqlite_base, $sqlite_lib, $sqlite_inc);
	#   if ( 0 ) { ...SQLITE_LOCATION/USE_LOCAL_SQLITE/SQLITE_INC/SQLITE_LIB... }
	#   else { $sqlite_local = 1; }  # Always the bundled one.
	# with the author's own comment above it: "This block is if ( 0 ) to
	# discourage casual users building against the system SQLite. We expect
	# that anyone sophisticated enough to use a system sqlite is also
	# sophisticated enough to have a patching system that can change the
	# if ( 0 ) to if ( 1 )." SQLITE_INC/SQLITE_LIB are therefore deliberately
	# left UNSET here: DBD::SQLite compiles its own vendored sqlite3.c exactly
	# as every other unpatched CPAN consumer does. Patching this Makefile.PL
	# to flip if(0)->if(1) is real engineering (the OBJECT list and final
	# link also need adjusting — see the reverted -r2 attempt's longer note
	# in git history) that is out of scope for this un-defer; the bundled
	# amalgamation is an explicitly sanctioned fallback per the plan (D4).
	#
	# SBOM note (the disc ships no untracked code): DBD::SQLite
	# ${DBD_SQLITE_PV}'s bundled sqlite3.h reports `#define SQLITE_VERSION
	# "3.51.1"` — this disc therefore ships TWO independently-built copies of
	# SQLite: Task 1's monolith-sqlite 3.53.4 (standalone `sqlite3` CLI +
	# libsqlite3.a) and this embedded 3.51.1 (compiled directly into the perl
	# binary, reachable only via `perl -MDBI`). Both are built THREADSAFE=0
	# (Task 1 sets it explicitly; DBD::SQLite's Makefile.PL sets it itself
	# whenever `!$Config{usethreads}`, true here: -Uusethreads above) and both
	# omit runtime extension loading (Task 1's explicit
	# -DSQLITE_OMIT_LOAD_EXTENSION=1; DBD::SQLite's Makefile.PL adds the same
	# define whenever `!$Config{usedl}`, true here: -Uusedl above) — the
	# disc's no-dynamic-loader doctrine falls out of DBD::SQLite's own
	# $Config-awareness for free.
	#
	# --- THE UNBLOCK: DBI_PUREPERL + pre-staging DBI's .pm/.h into lib/ ---
	#
	# DBD::SQLite's Makefile.PL needs an importable DBI at ITS OWN configure
	# time in two places: (1) a version gate — `require DBI; ... DBI->VERSION
	# < $DBI_required` (>= 1.57) — printed as a hard "please install DBI"
	# exit(0) [no Makefile generated] on failure; (2) its postamble() (package
	# MY) calls `require DBI::DBD; DBI::DBD::dbd_postamble(@_)`, which scans
	# @INC for an ALREADY-STAGED auto/DBI/Driver.xst (DBI's own Makefile.PL
	# post_initialize adds every top-level *.h/*.xst file it ships to the PM
	# hash, so pm_to_blib copies them into $(INST_ARCHAUTODIR) same as any
	# .pm — under PERL_CORE=1 that resolves to this tree's shared lib/auto/DBI/).
	#
	# Under miniperl (no dynamic loader, host-native binary, cannot dlopen a
	# target-arch .so and has no target XS baked in), a plain `require DBI`
	# hits DBI.pm's unconditional `XSLoader::load('DBI', $XS_VERSION)` at
	# require-time (DBI.pm, outside any DBI_PUREPERL check) and dies. DBI
	# ships its OWN sanctioned pure-perl fallback for exactly this situation:
	# DBI.pm reads `$ENV{DBI_PUREPERL}` — if truthy, `require DBI::PurePerl`
	# INSTEAD of XSLoader::load (DBI.pm: `if ($ENV{DBI_PUREPERL}) { ...;
	# require DBI::PurePerl if $@ or $ENV{DBI_PUREPERL} >= 2; } else {
	# XSLoader::load(...) }`). `$DBI::VERSION` ("1.651") is set unconditionally
	# at the TOP of DBI.pm, before that branch, so the version gate in (1)
	# passes regardless of which path loads.
	#
	# FIRST ATTEMPT (this ebuild's -r6, CI-tested and WRONG): exporting
	# DBI_PUREPERL=2 for the `emake` build plus an order-only Makefile rule
	# forcing `cpan/DBI/pm_to_blib` before `cpan/DBD-SQLite/Makefile`. CI's
	# actual result: DBI's `static` MakeMaker target compiled fine, but
	# DBD::SQLite's Makefile.PL STILL died with "DBI 1.57 is required" —
	# i.e. `require DBI` never even found DBI.pm to evaluate the
	# DBI_PUREPERL branch in the first place. Root cause: perl-cross invokes
	# every cpan/ Makefile.PL as `../../miniperl_top -I../../lib Makefile.PL`
	# — @INC is ONLY this tree's shared lib/ dir. DBI.pm doesn't land there
	# via `cpan/DBI/pm_to_blib` — that target, for a STATIC extension, is the
	# documented perl-cross bug this ebuild's src_compile already works
	# around for Fcntl/File::Spec/Cwd/CGI et al.: `$(static_modules): %/pm_to_blib:
	# | %/Makefile ...; $(MAKE) -C $(dir $@) ... static; @touch $@` — it only
	# runs the `static` target (compiles DBI.xs to .a) and then TOUCHES A
	# FAKE STAMP, it does not actually copy DBI.pm anywhere. The REAL
	# pm_to_blib re-run that stages .pm files (this ebuild's own src_compile
	# fix-up loop, `emake -C "${d}" PERL_CORE=1 pm_to_blib`) only happens
	# AFTER the top-level `emake` — i.e. after cpan/DBD-SQLite already tried
	# and failed to configure. The order-only Makefile rule was therefore
	# ordering against a stamp that never did the staging it looked like it did.
	#
	# THE ACTUAL FIX: since DBI.pm and its `lib/DBI/*.pm` siblings (DBI::DBD,
	# DBI::PurePerl, DBI::Const::*, ...) are plain FILES already present in
	# the pristine DBI-${DBI_PV} dist tree (no build step produces them),
	# copy them into this tree's shared lib/ DIRECTLY in src_prepare — before
	# configure or compile ever runs, so they are on miniperl's @INC for
	# EVERY subsequent Makefile.PL regardless of any build-order question.
	# Same reasoning for the *.h/*.xst files DBI::DBD::dbd_postamble()'s
	# dbd_dbi_arch_dir() greps @INC for (auto/DBI/Driver.xst) and that
	# DBD::SQLite's later C compile itself needs (`-I$(DBI_INSTARCH_DIR)` in
	# its Makefile.PL, pointing at this same lib/auto/DBI/ dir) — DBIXS.h,
	# Driver.xst, Driver_xst.h, dbd_xsh.h, dbi_sql.h, dbipport.h, dbivport.h
	# are the exact 7 top-level *.h/*.xst files in DBI-${DBI_PV} (verified via
	# `find . -maxdepth 1 \( -name '*.h' -o -name '*.xst' \)` on the fetched
	# tarball — matches DBI's own post_initialize's File::Find, which prunes
	# at depth 1 too); dbixs_rev.h is EXCLUDED deliberately — it's a
	# make-time-generated file (DBI's own `dbixs_rev.h: DBIXS.h Driver_xst.h
	# dbipport.h dbivport.h dbixs_rev.pl` rule) that doesn't exist in the
	# pristine tree and is DBI-internal, not `#include`d by DBD::SQLite's
	# SQLiteXS.h (checked directly).
	#
	# This pre-staged lib/DBI.pm (copied straight from cpan/DBI/DBI.pm, the
	# real dist file, not a stub) is also exactly what installperl ends up
	# shipping — cpan/DBI's own REAL pm_to_blib re-run in src_compile below
	# copies the identical content over it again later, a harmless no-op
	# overwrite. DBI_PUREPERL is still exported for the `emake` build
	# (src_compile) so `require DBI` — now able to actually LOAD DBI.pm from
	# lib/ — takes the DBI::PurePerl branch instead of XSLoader::load.
	# Build-time-ONLY: DBI_PUREPERL is not set in the live ISO's runtime
	# environment, so at boot the REAL compiled-in DBI XS loads via
	# XSLoader::load — which, for a perl-cross static_ext module, resolves
	# against the statically-linked bootstrap table (the same mechanism every
	# other static_ext module here, e.g. Fcntl/POSIX, already relies on) —
	# not a dlopen, so this all-static -Uusedl perl still has zero .so's.
	#
	# The now-pointless order-only Makefile rule (ordering against a fake
	# stamp accomplishes nothing here) is DROPPED, not kept as dead
	# belt-and-suspenders — a comment claiming it does something it
	# provably doesn't is worse than no comment.
	mkdir -p lib/auto/DBI || die
	cp cpan/DBI/DBI.pm lib/DBI.pm || die "pre-staging DBI.pm into lib/ failed"
	cp -a cpan/DBI/lib/DBI lib/ || die "pre-staging cpan/DBI/lib/DBI/ subtree into lib/DBI/ failed"
	cp cpan/DBI/DBIXS.h cpan/DBI/Driver.xst cpan/DBI/Driver_xst.h cpan/DBI/dbd_xsh.h \
		cpan/DBI/dbi_sql.h cpan/DBI/dbipport.h cpan/DBI/dbivport.h lib/auto/DBI/ \
		|| die "pre-staging DBI's auto/DBI headers into lib/auto/DBI/ failed"
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
	#
	# --static-ext=DBI,DBD-SQLite: belt-and-suspenders alongside --all-static
	# above. --all-static (cnf/configure_mods.sh: `elif [ "$1" = "xs" -a -n
	# "$allstatic" ]`) already forces every discovered XS module — including
	# third-party ones staged under cpan/ in src_prepare above — onto the
	# static_ext list, so this flag changes nothing functionally today. Added
	# anyway to document intent at the configure call site and to keep DBI +
	# DBD::SQLite static even if --all-static is ever narrowed later. Verified
	# spelling against cnf/configure_args.sh's option table:
	# `static-mod|static-ext|static-modules|static)` accepts a comma-separated
	# list, each entry run through the same modsymname() used for module
	# discovery — so "DBI" and "DBD-SQLite" (the cpan/ directory names, not
	# the "::"-form perl module names) are the correct tokens here.
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

src_compile() {
	# DBI_PUREPERL=2: the build-time-only unblock for DBD::SQLite's
	# Makefile.PL `require DBI` (see the long src_prepare comment on the
	# DBI/DBD-SQLite bake for the full evidence trail — this env var ALONE
	# was not enough, per -r6's CI failure; it only matters once DBI.pm is
	# actually findable, which src_prepare's lib/ pre-staging now ensures).
	# Forces DBI.pm to `require DBI::PurePerl` instead of
	# `XSLoader::load('DBI', ...)` when miniperl (host-native, no target XS,
	# no dynamic loader) evaluates any cpan/ Makefile.PL during this build.
	#
	# `export` here, NOT an `emake VAR=val` make-macro assignment: this must
	# be a real process-environment variable so every child `miniperl_top
	# Makefile.PL` invocation spawned during `emake` inherits it via normal
	# Unix env inheritance — a make macro would only be visible to make's own
	# recipe expansion, not to a plain Perl `$ENV{DBI_PUREPERL}` read inside
	# the Makefile.PL script itself.
	#
	# Scoped to this emake invocation only — DBI_PUREPERL is NOT set in the
	# installed image's runtime environment, so the live ISO's perl loads the
	# REAL compiled-in DBI XS via the same static_ext bootstrap table every
	# other baked XS module (Fcntl, POSIX, ...) already uses.
	export DBI_PUREPERL=2

	# perl-cross builds its own miniperl from source (host compiler for
	# host-side codegen; ${CHOST}-gcc for the target perl/extensions).
	emake

	# Stage every extension's pure-perl .pm into its blib so `default`'s
	# installperl actually ships them.
	#
	# THE BUG: perl-cross builds each STATIC extension via MakeMaker's `static`
	# target (Makefile line: `$(MAKE) -C dir ... LINKTYPE=static static`), which
	# compiles the XS into a .a but does NOT run pm_to_blib (the step that copies
	# the module's .pm into blib/lib). perl-cross then `touch`es a fake
	# `<dir>/pm_to_blib` stamp, so make believes staging is done. In a normal
	# usedl=define build this is harmless — modules are DYNAMIC ext, and the
	# `dynamic` target DOES stage .pm. But this disc is -Uusedl, so EVERY module
	# is static ext, and NONE of their .pm get staged: installperl ships a perl
	# with all the XS baked into the binary yet Fcntl.pm / File::Spec / Cwd / ...
	# missing => "Can't locate X.pm in @INC" (breaks File::Temp, CGI.pm, and most
	# path/flag-handling perl). Confirmed by DIAG build: Fcntl.pm existed only at
	# ext/Fcntl/Fcntl.pm, never in any blib.
	#
	# FIX: drop the fake stamp and run each module's real MakeMaker `pm_to_blib`
	# target (a pure .pm copy — no recompile). installperl then finds them.
	local mk d
	while IFS= read -r -d '' mk; do
		d="${mk%/Makefile}"
		rm -f "${d}/pm_to_blib"
		emake -C "${d}" PERL_CORE=1 pm_to_blib || ewarn "pm_to_blib staging skipped for ${d#"${S}/"}"
	done < <(find "${S}/ext" "${S}/dist" "${S}/cpan" -maxdepth 2 -name Makefile -print0 2>/dev/null)
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

	# Verify the DBI/DBD::SQLite un-defer (SP5 P3) actually staged, same
	# hard-die-with-candidates diagnostic as the bootstrap check above — this
	# is the newest, least-proven part of this ebuild (the DBI_PUREPERL
	# unblock + the Makefile build-order rule in src_prepare), so a fast,
	# grep-able build-log failure here beats discovering it only at
	# boot-test's smoke_perl_dbi.
	for m in DBI.pm DBI/DBD.pm DBD/SQLite.pm; do
		if [[ ! -f "${privlib}/${m}" ]]; then
			eerror "MONOLITH-PERL DBI/DBD::SQLite backfill: ${m} still missing; build-tree candidates:"
			find "${S}" -name "$(basename "${m}")" -printf '  %p\n' 2>/dev/null | head -10
			die "DBI/DBD::SQLite backfill incomplete: ${m} still missing"
		fi
	done
	einfo "MONOLITH-PERL: DBI + DBD::SQLite .pm staged (static_ext bake)"

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
