# PERL FOR THE MONOLITH — IMPLEMENTATION SPEC

> Author: project owner. Grounded against the tree at commit 4285797 (2026-08).
> For Claude Code + subagents; house rules apply (verify tree state,
> Manifest-pin sources, revbump on change, TDD where testable, reports to
> `.batteries/reports/`).

## 0. GROUND TRUTH (verified, do not re-litigate)

- No dev-lang/perl, no dev-db/sqlite in world. irssi is USE=-perl with a
  comment establishing perl as build-host-only today.
- Static doctrine machinery: env/static.conf (-static, -no-pie,
  --disable-shared) + no dynamic loader on the disc AT ALL. Therefore:
  perl MUST be -Uusedl — no XS .so loading exists to fall back on. Every
  XS module ships inside the perl binary or not at all. Pure-perl
  modules are just files and carry no such constraint.
- Custom-overlay pattern exists (monolith-kernel, rl144): Manifest-
  pinned SRC_URI tarballs, toolchain quirks handled in-ebuild, pin
  comments in world. Perl uses this pattern — DO NOT fight Gentoo's
  dev-lang/perl ebuild, whose Configure is cross-hostile (runs target
  test programs); that path is a tarpit with prior art of failure.
- busybox httpd (CGI-capable) is already on the disc (#28): the CGI
  target exists. i486 8-byte-atomic issues are solved via the cross-gcc
  libatomic.a (#32) — and single-threaded perl shouldn't need it anyway.

## 1. DECISIONS (made; record deviations in DECISIONS.md)

D1. Route: perl-cross (arsv/perl-cross) driving vanilla perl source, as
    a custom overlay ebuild dev-lang/monolith-perl. perl-cross replaces
    Configure with a cross-aware configure; it is how Buildroot and
    OpenWrt cross-compile perl — steal their flag sets as prior art.
    VERSION PAIRING IS STRICT: each perl-cross release supports specific
    perl versions. Pick the newest perl the current perl-cross release
    explicitly supports (likely 5.40.x/5.42.x era); pin BOTH tarballs in
    Manifest; record the pair in versions.lock.
D2. Configuration: -Uusedl (mandatory — see §0) · -Uusethreads (single-
    user disc; smaller, faster, avoids musl+static+ithreads pain) ·
    -Duse64bitint (long-long on i486; DB/file-size sanity is worth the
    math cost) · -Duselargefiles · prefix=/usr, sitelib under
    /usr/lib/perl5 · man/pod installation OFF (mandoc disc has man-pages
    already; perl PODs cost tens of MB — keep `perldoc` functional
    against .pm PODs if free, else drop and note).
D3. SQLite: TWO consumers, ONE source. Add dev-db sqlite as a custom
    overlay ebuild (monolith-sqlite) built FROM THE AMALGAMATION
    (sqlite-autoconf tarball): one file, one hash, one SBOM line, no tcl
    BDEPEND risk (verify Gentoo's dev-db/sqlite BDEPENDs before
    considering it instead; if it drags tcl, the amalgamation ebuild
    wins). Flags: THREADSAFE=0, OMIT_LOAD_EXTENSION (no dlopen exists),
    FTS + JSON on, -Os. Ships: sqlite3 CLI (static) + libsqlite3.a +
    sqlite3.h into the cross sysroot for D4.
D4. XS bake list (compiled INTO perl via static_ext): DBI + DBD::SQLite,
    linked against the SYSTEM libsqlite3.a from D3 (DBD::SQLite supports
    external sqlite via SQLITE_INC/SQLITE_LIB env; its bundled
    amalgamation is the FALLBACK if external linking fights — if taken,
    record the second embedded sqlite version in an SBOM note, because
    the disc does not ship untracked code).
    Mechanism: unpack DBI and DBD-SQLite dists into the perl tree's
    ext/ (or the perl-cross-sanctioned location — read perl-cross docs
    for third-party static_ext, it documents this), add to
    --static-ext / -Dstatic_ext, let miniperl drive their Makefile.PLs
    during the perl build. This is the classic static-perl move; it is
    fiddly, not novel.
D5. Pure-perl riders (files, zero linking risk, installed to sitelib):
    CGI.pm (REQUIRED — removed from perl core in 5.22, and the kid's
    guestbook is the point of all this) + its dep HTML::Parser? NO:
    CGI.pm 4.x is pure-perl but check its dep tree (HTML::Entities/
    HTML::Parser is XS!) — if CGI.pm's current release requires XS deps,
    pin the newest CGI.pm release that runs pure-perl-only, or vendor
    the tiny needed subset; a 1996 guestbook needs param() and
    header(), not the kitchen. Each rider: Manifest-pinned dist
    tarball, license into SBOM.
D6. World entries: dev-lang/monolith-perl + dev-db/monolith-sqlite (or
    the names the implementer chooses in the overlay), with pin
    comments in the established world-file voice explaining -Uusedl,
    the static_ext bake, and the CGI.pm history note.

## 2. THE EBUILD (dev-lang/monolith-perl) — SHAPE

SRC_URI: perl-X.Y.Z.tar.xz + perl-cross-N.M.tar.gz + DBI-*.tar.gz +
DBD-SQLite-*.tar.gz + CGI-*.tar.gz (all Manifest-pinned; host in
project S3 if upstream archives ever drift, per the rl144 precedent).
DEPEND: dev-db/monolith-sqlite (static lib + headers in sysroot).
src_prepare: overlay perl-cross onto the perl tree (its documented
install method); place DBI/DBD source per D4 mechanism.
src_configure (representative — implementer verifies exact perl-cross
spelling):
  ./configure --target=${CHOST} --prefix=/usr \
    -Uusedl -Uusethreads -Duse64bitint -Duselargefiles \
    --static --all-static \
    -Dstatic_ext='DBI DBD::SQLite' \
    -Accflags="${CFLAGS}" -Aldflags="${LDFLAGS}" \
    (mandir/podless options per D2)
  NOTE: env/static.conf's EXTRA_ECONF (--disable-shared) targets
  autotools and may confuse perl-cross's configure — if it does, give
  perl its own env/perl-cross.conf overriding EXTRA_ECONF empty and
  carrying the static flags explicitly; package.env it. Do not weaken
  static.conf globally for perl's convenience.
src_test: SKIP target test suite (cannot run i486 binaries in the
build container natively; qemu-user in-container is optional stretch).
Testing happens at boot-test (§4).
src_install: perl binary + minimal lib tree; then PRUNE (see §3).

## 3. SIZE BUDGET & PRUNING

Budget: perl binary (static, -Os, stripped) ≤ 12 MB; installed
/usr/lib/perl5 tree ≤ 35 MB uncompressed (squashfs-gzip will roughly
third it). Measure and record both in the report; the ISO's boot-test
already fences total size regressions.
Prune from the installed tree (standard static-distro trims):
*.pod (unless perldoc kept per D2), unicore build droppings beyond
what utf8 runtime needs (careful: Unicode::* runtime NEEDS
lib/unicore tables — trim the build-only files, verify with the §4
smoke), CPAN/CPANPLUS toolchain dirs (no umbilical on the disc —
this is philosophy AND megabytes), Pod::*, ExtUtils::* and friends
NOT needed at runtime (keep enough for `perl -V`), h2ph output,
IO::Socket::IP stays (network knife), Encode's rare-encoding tables
optionally trimmed (keep utf8/latin1/ascii + document what was cut).
Every prune: one line in the report. When in doubt, keep — 5 MB of
squashfs is cheaper than a broken module at the kid's keyboard.

## 4. ACCEPTANCE (wire into boot-test smoke suite)

  perl -v (banner, version matches pin)
  perl -e 'use strict; use warnings; print "ok\n"'
  perl -Mutf8 -e '...' (unicore tables survived pruning)
  perl -MDBI -e 'my $dbh=DBI->connect("dbi:SQLite:dbname=:memory:");
    $dbh->do("create table t(a)"); $dbh->do("insert into t values(41+1)");
    print $dbh->selectrow_array("select a from t"),"\n"'  → 42
  sqlite3 :memory: 'select 41+1;'  → 42 (the CLI, from D3)
  perl -MCGI -e 'print CGI->new("x=1")->param("x")'  → 1
  echo of a minimal guestbook CGI under busybox httpd: POST via the
  boot-test's network path, assert the SQLite row — the LAMP invariant,
  now actually implementable since every part exists.
  BIOS job addition: all of the above ON THE 486 PROFILE (this is the
  slowest interpreter start on the disc; if perl start on -cpu 486
  is >5s, note it — do not gate on it, the DX2 is patient).

## 5. MILESTONES & FALLBACKS

P1 monolith-sqlite ebuild + CLI on disc + boot-test line. (Small,
   independent, lands first — it's also independently promised.)
P2 monolith-perl CORE ONLY (-Uusedl, no static_ext): perl -v green in
   boot-test. Proves the perl-cross pipeline before the fiddly part.
P3 static_ext bake (DBI + DBD::SQLite vs system libsqlite3.a) + DBI
   smoke green. FALLBACK: bundled-amalgamation DBD (SBOM note) →
   worst case, P3 defers and P2 ships (a perl without DBI is still
   perl; the world file comment records the debt).
P4 CGI.pm rider + pruning pass + guestbook boot-test.
P5 report: .batteries/reports/perl.md in the house style (the gdb/mtr
   reports are the register to match): what was pinned, what was
   pruned, what was deferred, the sizes, and the three worst fights.
Timebox rule (house standard): 45 min per blocked avenue, then the
ladder. perl-cross version pairing errors look like deep C failures —
if configure or miniperl breaks strangely, check the pairing FIRST.

## 6. WHAT NOT TO DO

No target dev-lang/perl from ::gentoo (tarpit). No threads. No dlopen
anything. No CPAN client on the disc. No enabling irssi's USE=perl in
this pass (its embed API vs static perl is a separate investigation;
leave the -perl comment in place). No unpinned dist tarballs. And no
weakening static.conf globally — perl adapts to the disc, not the
disc to perl.
