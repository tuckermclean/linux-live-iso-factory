# Perl for the Monolith (SP5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a static, `-Uusedl` Perl (with DBI + DBD::SQLite baked in and CGI.pm) plus a static SQLite (CLI + `libsqlite3.a`) on the i486-linux-musl live disc, proven by a guestbook-CGI boot-test.

**Architecture:** Two custom overlay ebuilds under `configs/overlay/` (the monolith-kernel/rl144 pattern): `dev-db/monolith-sqlite` (built from the sqlite amalgamation) and `dev-lang/monolith-perl` (vanilla perl source driven by arsv/perl-cross, with DBI + DBD::SQLite compiled in via `static_ext` and CGI.pm dropped into sitelib). All tarballs Manifest-pinned. Acceptance is wired into `scripts/boot-test.py` as new `smoke_*` checks; the CI full-ci build is the test cycle for every task.

**Tech Stack:** Gentoo crossdev (`i486-linux-musl`), custom overlay ebuilds (EAPI 8), arsv/perl-cross, sqlite amalgamation, busybox httpd (CGI), pexpect boot-test.

## Global Constraints

- Static doctrine: no dynamic loader on the disc. Perl MUST be `-Uusedl`; every XS module is baked into the perl binary via `static_ext` or not shipped. (spec §0)
- Perl config (spec D2): `-Uusedl -Uusethreads -Duse64bitint -Duselargefiles`, `prefix=/usr`, sitelib under `/usr/lib/perl5`, man/pod install OFF.
- SQLite (spec D3): amalgamation source; `SQLITE_THREADSAFE=0`, `SQLITE_OMIT_LOAD_EXTENSION`, FTS + JSON on, `-Os`. Ships `sqlite3` CLI (static) + `libsqlite3.a` + `sqlite3.h` into the cross sysroot.
- All source tarballs Manifest-pinned (BLAKE2B + SHA512, like `configs/overlay/**/Manifest`); host in project S3 only if upstream drifts (rl144 precedent).
- Do NOT use `dev-lang/perl` / `dev-db/sqlite` from `::gentoo` (Configure cross-tarpit / tcl BDEPEND risk). Do NOT weaken `env/static.conf` globally — give perl its own `package.env` if its configure fights `EXTRA_ECONF`. (spec §2, §6)
- No threads, no dlopen, no CPAN client, no enabling irssi `USE=perl`. (spec §6)
- Size budget (spec §3): perl binary ≤ 12 MB stripped; `/usr/lib/perl5` ≤ 35 MB uncompressed. Measure + record.
- House rules: revbump on ebuild change, pin comments in `configs/portage/world` in the established voice, report to `.batteries/reports/perl.md`, record decision deviations in a `DECISIONS.md` alongside the report.
- Timebox: 45 min per blocked avenue, then the ladder/fallback. perl-cross version-pairing errors masquerade as deep C failures — check the pairing FIRST. (spec §5)

## File Structure

- `configs/overlay/dev-db/monolith-sqlite/monolith-sqlite-<ver>.ebuild` — builds sqlite CLI + static lib + header from the amalgamation.
- `configs/overlay/dev-db/monolith-sqlite/Manifest` — pins the sqlite-autoconf tarball.
- `configs/overlay/dev-lang/monolith-perl/monolith-perl-<ver>.ebuild` — perl-cross-driven static perl with the XS bake + CGI rider.
- `configs/overlay/dev-lang/monolith-perl/Manifest` — pins perl, perl-cross, DBI, DBD-SQLite, CGI tarballs.
- `configs/overlay/dev-lang/monolith-perl/files/` — any patches / a `perl-cross.conf` env file source if needed.
- `configs/portage/world` — add `dev-db/monolith-sqlite`, `dev-lang/monolith-perl` with pin comments.
- `configs/portage/package.env/cross-compile` + `configs/portage/env/perl-cross.conf` — ONLY if static.conf's EXTRA_ECONF fights perl-cross configure (spec §2 note).
- `configs/portage/bashrc` — a `dev-lang/monolith-perl` case ONLY if a per-package toolchain quirk needs it (kmod/libxml2 precedent).
- `configs/attestation/cpe-overrides.yaml` — CPE entries for perl + sqlite.
- `scripts/boot-test.py` — new `smoke_*` functions + wiring for the acceptance checks (spec §4).
- `.batteries/reports/perl.md` + `DECISIONS.md` — the deliverable report.

---

### Task 1 (P1): `dev-db/monolith-sqlite` — static CLI + lib

**Files:**
- Create: `configs/overlay/dev-db/monolith-sqlite/monolith-sqlite-<ver>.ebuild`
- Create: `configs/overlay/dev-db/monolith-sqlite/Manifest`
- Modify: `configs/portage/world` (add `dev-db/monolith-sqlite`)
- Modify: `scripts/boot-test.py` (add `smoke_sqlite_cli`)
- Modify: `configs/attestation/cpe-overrides.yaml` (`sqlite: cpe:2.3:a:sqlite:sqlite:*...`)

**Interfaces:**
- Produces (for Task 3): `/usr/lib/libsqlite3.a` + `/usr/include/sqlite3.h` in the cross sysroot (`ROOT=/usr/i486-linux-musl`), and `SQLITE_VERSION` recorded in the report; the CLI binary `/usr/bin/sqlite3` in the rootfs.

- [ ] **Step 1: Pick + pin the amalgamation.** From <https://sqlite.org/download.html> choose the current `sqlite-autoconf-NNNNNNN.tar.gz` (the amalgamation — one `sqlite3.c`, one `shell.c`, autotools). Record the exact version. Verify Gentoo's `dev-db/sqlite` BDEPENDs (`gh api repos/gentoo/gentoo/contents/dev-db/sqlite`) — confirm it drags `dev-lang/tcl` (this is why we use the amalgamation). Note the finding in the report.

- [ ] **Step 2: Write the failing boot-test check.** In `scripts/boot-test.py`, add (near `smoke_curl`, following its exact shape):
```python
def smoke_sqlite_cli(child):
    """sqlite3 CLI runs and computes — proves the static amalgamation build."""
    return run_check(
        child, "sqlite3 CLI evaluates in-memory SQL", "sqlite3 :memory: 'select 41+1;'",
        contains("42"))
```
Wire it into the smoke sequence where the other tool checks run (find where `smoke_curl(child)` is invoked and add `smoke_sqlite_cli(child)` alongside).

- [ ] **Step 3: Author the ebuild.** Model on `configs/overlay/games-roguelike/rl144/rl144-*.ebuild` (EAPI 8, `DESCRIPTION`, `HOMEPAGE`, `SRC_URI` → `${P}.tar.gz` rename if needed, `S=`, `LICENSE="public-domain"`, `SLOT="0"`, `KEYWORDS="~amd64"`). It is a plain autotools amalgamation. Configure with the spec D3 flags; the repo-wide `env/static.conf` catch-all already forces `-static --disable-shared --enable-static`, so DO NOT re-specify those. Set the amalgamation compile-time defines via `CPPFLAGS`:
```bash
src_configure() {
    append-cppflags -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1
    # -Os comes from the global CFLAGS; econf inherits EXTRA_ECONF (static) from
    # env/static.conf. Disable the optional readline/editline TUI (no such libs
    # wired here) and dynamic extensions.
    econf --disable-editline --disable-readline --disable-dynamic-extensions
}
```
`src_install` must install the CLI to `/usr/bin/sqlite3`, `libsqlite3.a` to `/usr/lib/`, and `sqlite3.h` to `/usr/include/` (autotools `emake install` normally does all three; verify `.a` and header land in the sysroot, since Task 3 links against them). `inherit flag-o-matic` for `append-cppflags`.

- [ ] **Step 4: Generate the Manifest.** After the ebuild + SRC_URI are set, the Manifest lines are `DIST sqlite-autoconf-NNNNNNN.tar.gz <size> BLAKE2B <b2b> SHA512 <sha512>`. Compute them from the fetched tarball (the same format as `configs/overlay/sys-kernel/monolith-kernel/Manifest`). If the CI builder regenerates Manifests, confirm the mechanism; otherwise write the file by hand from `b2sum`/`sha512sum` of the downloaded tarball.

- [ ] **Step 5: Add to world + CPE override.** In `configs/portage/world`, under a `# Databases` section, add:
```
# sqlite — static SQLite (CLI + libsqlite3.a) from the amalgamation ebuild, not
# ::gentoo (which BDEPENDs tcl). THREADSAFE=0, no dlopen extensions, FTS5+JSON1.
# libsqlite3.a + sqlite3.h feed DBD::SQLite's static_ext bake in monolith-perl.
dev-db/monolith-sqlite
```
In `configs/attestation/cpe-overrides.yaml` add `sqlite: "cpe:2.3:a:sqlite:sqlite:*:*:*:*:*:*:*:*"` (verify the vendor/product against NVD).

- [ ] **Step 6: Validate via CI.** Push the branch, label `full-ci`, and drive to green. `smoke_sqlite_cli` must pass (sqlite3 CLI prints 42). Confirm in the build log that `libsqlite3.a` + `sqlite3.h` were installed to the sysroot (`/usr/i486-linux-musl/usr/lib/libsqlite3.a`). Re-run any known-flaky boot variant (nvme/nicless/ne2k_isa) per house practice.

- [ ] **Step 7: Commit.**
```bash
git add configs/overlay/dev-db/monolith-sqlite scripts/boot-test.py configs/portage/world configs/attestation/cpe-overrides.yaml
git commit -m "feat(sp5): dev-db/monolith-sqlite — static sqlite3 CLI + libsqlite3.a (amalgamation)"
```

---

### Task 2 (P2): `dev-lang/monolith-perl` — static perl CORE (no static_ext)

**Files:**
- Create: `configs/overlay/dev-lang/monolith-perl/monolith-perl-<ver>.ebuild`
- Create: `configs/overlay/dev-lang/monolith-perl/Manifest`
- Create (maybe): `configs/portage/env/perl-cross.conf` + `configs/portage/package.env/cross-compile` line
- Modify: `configs/portage/world` (add `dev-lang/monolith-perl`)
- Modify: `scripts/boot-test.py` (`smoke_perl_version`, `smoke_perl_basic`, `smoke_perl_utf8`)
- Modify: `configs/attestation/cpe-overrides.yaml` (`perl: cpe:2.3:a:perl:perl:*...`)

**Interfaces:**
- Consumes: nothing from Task 1 yet (core perl has no DB). 
- Produces (for Task 3): a working perl tree at `/usr/lib/perl5`, the perl-cross `configure` invocation and env known-good, so Task 3 only adds `static_ext`.

- [ ] **Step 1: Determine the version pairing (CRITICAL — spec D1).** Read arsv/perl-cross releases (`gh api repos/arsv/perl-cross/releases` or the README). Each perl-cross release lists the exact perl versions it supports. Pick the NEWEST perl that the current perl-cross explicitly supports (5.40.x/5.42.x era). Record the pair (perl X.Y.Z + perl-cross N.M) in the report and `configs/portage/versions.lock`. Note (spec §5): if configure/miniperl breaks "strangely," suspect the pairing before anything else.

- [ ] **Step 2: Write the failing boot-test checks.** In `scripts/boot-test.py`:
```python
def smoke_perl_version(child):
    return run_check(child, "perl runs and reports its version", "perl -e 'print $];'",
                     contains("5.0"))  # $] is e.g. 5.040002; tighten to the pinned major once known

def smoke_perl_basic(child):
    return run_check(child, "perl strict+warnings program runs",
                     "perl -e 'use strict; use warnings; print qq(ok\\n);'", contains("ok"))

def smoke_perl_utf8(child):
    # unicore tables survived pruning: uc() of a non-ASCII char needs Unicode data
    return run_check(child, "perl unicode/utf8 tables present",
                     "perl -Mutf8 -CS -e 'print uc(qq(\\x{e9}));'", exit_code_only())
```
Wire them into the smoke sequence. (They fail today: no perl on disc.)

- [ ] **Step 3: Author the ebuild — perl-cross overlay + configure.** EAPI 8. `SRC_URI` fetches BOTH `perl-X.Y.Z.tar.xz` and `perl-cross-N.M.tar.gz`. `S="${WORKDIR}/perl-X.Y.Z"`. In `src_prepare`, overlay perl-cross onto the perl tree per its documented method (`cp -a` the perl-cross tree contents over the perl source, or run its `configure` from the perl-cross dir against `--target-tree`; read perl-cross's README for the exact install step — record it in the report). `src_configure` (representative — verify exact perl-cross flag spelling from `./configure --help`):
```bash
src_configure() {
    ./configure --target="${CHOST}" --prefix=/usr \
        -Dcc="${CHOST}-gcc" \
        -Uusedl -Uusethreads -Duse64bitint -Duselargefiles \
        -Dman1dir=none -Dman3dir=none \
        -Accflags="${CFLAGS}" -Aldflags="${LDFLAGS}" \
        --static || die "perl-cross configure failed"
}
```
`src_compile`: `emake` (perl-cross builds miniperl on the HOST first, then the target perl). If the host miniperl link picks up `-static` from the cross env and breaks, that's the `EXTRA_ECONF`/env fight the spec warns about — see Step 4. `src_test`: skip (`RESTRICT="test"`; cannot run i486 binaries). `src_install`: `emake DESTDIR="${D}" install`.

- [ ] **Step 4: Handle the static.conf/EXTRA_ECONF fight (conditional).** If Step 3's configure/compile fails because `env/static.conf`'s `EXTRA_ECONF="--disable-shared --enable-static"` (autotools-shaped) confuses perl-cross's `./configure`: create `configs/portage/env/perl-cross.conf` with `EXTRA_ECONF=""` (and carry any needed static flags explicitly via the ebuild's own configure line, NOT globally), then map it in `configs/portage/package.env/cross-compile`:
```
# perl-cross's ./configure is not autotools; the global EXTRA_ECONF confuses it.
dev-lang/monolith-perl   perl-cross.conf
```
Only do this if it actually fails — capture the real error first (the build-log artifact is uploaded on failure).

- [ ] **Step 5: World entry + CPE.** In `configs/portage/world`, under `# Scripting languages` (near `dev-lang/lua`):
```
# perl — static, -Uusedl (no dynamic loader on the disc, so no XS .so loading;
# XS is baked into the binary via static_ext — see monolith-perl ebuild). Built
# with arsv/perl-cross driving vanilla perl (Gentoo's dev-lang/perl Configure is
# cross-hostile). No threads, no CPAN client. CGI.pm shipped separately (removed
# from perl core in 5.22) for the guestbook.
dev-lang/monolith-perl
```
Add `perl: "cpe:2.3:a:perl:perl:*:*:*:*:*:*:*:*"` to cpe-overrides.yaml.

- [ ] **Step 6: Validate via CI.** Push, `full-ci`, drive green. `smoke_perl_version`/`smoke_perl_basic`/`smoke_perl_utf8` must pass. If the perl binary is huge, note the size (budget check happens in Task 4's prune). Capture the perl-cross build log for the report.

- [ ] **Step 7: Commit.**
```bash
git add configs/overlay/dev-lang/monolith-perl scripts/boot-test.py configs/portage/world configs/attestation/cpe-overrides.yaml
[ -f configs/portage/env/perl-cross.conf ] && git add configs/portage/env/perl-cross.conf configs/portage/package.env/cross-compile
git commit -m "feat(sp5): dev-lang/monolith-perl — static -Uusedl perl core via perl-cross"
```

---

### Task 3 (P3): Bake DBI + DBD::SQLite into perl (`static_ext`)

**Files:**
- Modify: `configs/overlay/dev-lang/monolith-perl/monolith-perl-<ver>.ebuild` (revbump: rename to `-r1`), add DBI + DBD-SQLite to SRC_URI + `static_ext`
- Modify: `configs/overlay/dev-lang/monolith-perl/Manifest` (add DBI, DBD-SQLite)
- Modify: `scripts/boot-test.py` (`smoke_perl_dbi`)

**Interfaces:**
- Consumes: Task 1's `/usr/i486-linux-musl/usr/lib/libsqlite3.a` + `sqlite3.h`; Task 2's working perl-cross configure.
- Produces: `perl -MDBI` and `DBD::SQLite` usable at runtime (compiled in).

- [ ] **Step 1: Pin DBI + DBD::SQLite.** From CPAN pick current `DBI-*.tar.gz` and `DBD-SQLite-*.tar.gz`; add to `SRC_URI` + Manifest. Add `dev-db/monolith-sqlite` to `DEPEND` (Task 1 must be installed in the sysroot first, so its `.a`/header are present).

- [ ] **Step 2: Write the failing DBI boot-test.**
```python
def smoke_perl_dbi(child):
    prog = ("my $d=DBI->connect('dbi:SQLite:dbname=:memory:'); "
            "$d->do('create table t(a)'); $d->do('insert into t values(41+1)'); "
            "print $d->selectrow_array('select a from t');")
    return run_check(child, "perl DBI + DBD::SQLite in-memory query",
                     f"perl -MDBI -e \"{prog}\"", contains("42"))
```
Wire it in after `smoke_sqlite_cli`.

- [ ] **Step 3: Add the static_ext bake.** Read perl-cross docs for the sanctioned location/mechanism for third-party `static_ext` (record it in the report). In `src_prepare`, unpack DBI and DBD-SQLite into the perl tree's `ext/` (or the perl-cross-documented location). In `src_configure`, add `-Dstatic_ext='DBI DBD::SQLite'` (verify exact perl-cross spelling; may be `--static-ext=`). Point DBD::SQLite at the SYSTEM sqlite via env so it does NOT compile its bundled amalgamation:
```bash
export SQLITE_INC="${SYSROOT}/usr/include" SQLITE_LOCATION="${SYSROOT}/usr"
export SQLITE_LIB="${SYSROOT}/usr/lib"   # link libsqlite3.a
```
(where `SYSROOT=/usr/${CHOST}`). Revbump the ebuild to `-r1`.

- [ ] **Step 4: Validate via CI.** Push, full-ci. `smoke_perl_dbi` must print 42. Confirm in the log that DBD::SQLite linked the SYSTEM `libsqlite3.a` (not its bundled copy) — grep the build log for `-lsqlite3` / the sysroot lib path.

- [ ] **Step 5: FALLBACK if external sqlite fights.** If DBD::SQLite refuses to link the external `.a` within the timebox (45 min), let it compile its BUNDLED amalgamation instead (drop the `SQLITE_*` env). Then record the second embedded sqlite version as an SBOM note in the report (the disc ships no untracked code). If DBI/DBD static_ext itself is intractable, DEFER P3: ship P2's core perl, add a `world` comment recording the DBI debt, and mark P3 deferred in the report. A perl without DBI still passes P2/P4-core.

- [ ] **Step 6: Commit.**
```bash
git add configs/overlay/dev-lang/monolith-perl scripts/boot-test.py
git commit -m "feat(sp5): bake DBI + DBD::SQLite into perl via static_ext (system libsqlite3.a)"
```

---

### Task 4 (P4): CGI.pm rider + pruning + guestbook boot-test

**Files:**
- Modify: `configs/overlay/dev-lang/monolith-perl/monolith-perl-<ver>.ebuild` (revbump `-r2`): CGI SRC_URI + install to sitelib + prune pass
- Modify: `configs/overlay/dev-lang/monolith-perl/Manifest` (add CGI)
- Modify: `scripts/boot-test.py` (`smoke_perl_cgi`, `smoke_guestbook`)
- Create: a minimal guestbook CGI fixture (in `configs/rootfs-overlay/` or generated in the boot-test) + its install/allowlist wiring

**Interfaces:**
- Consumes: Task 3's DBI/DBD (guestbook writes SQLite), busybox httpd (already on disc, #28).
- Produces: CGI.pm in sitelib; the LAMP invariant proven.

- [ ] **Step 1: Pin CGI.pm PURE-PERL (spec D5 trap).** CGI.pm 4.x is pure-perl but check its runtime deps: `HTML::Entities`/`HTML::Parser` is **XS**. Pick the newest `CGI-*.tar.gz` whose runtime path (`param()`, `header()`) needs no XS dep — or, if none, vendor only the needed pure-perl subset. Record the exact CGI version + the dep decision in the report. Add to SRC_URI + Manifest.

- [ ] **Step 2: Write the CGI boot-test.**
```python
def smoke_perl_cgi(child):
    return run_check(child, "CGI.pm param() works",
                     "perl -MCGI -e 'print CGI->new(q(x=1))->param(q(x));'", contains("1"))
```

- [ ] **Step 3: Install CGI.pm to sitelib.** In the ebuild, unpack CGI into the perl build and install its `.pm` files to `/usr/lib/perl5/site_perl/.../CGI.pm` (pure-perl → plain file copy; NO XS). Revbump to `-r2`.

- [ ] **Step 4: Prune the installed tree (spec §3).** In `src_install`, after install, remove: `*.pod` (unless keeping perldoc — decide + note), CPAN/CPANPLUS dirs, `ExtUtils::*`/`Pod::*` not needed at runtime (keep enough for `perl -V`), h2ph output, build-only unicore droppings (KEEP `lib/unicore` runtime tables — `smoke_perl_utf8` guards this), optionally rare Encode tables (keep utf8/latin1/ascii, document cuts). Every prune = one report line. Measure `du -sh` of the perl binary (stripped) and `/usr/lib/perl5`; assert against the budget (≤12 MB / ≤35 MB) and record.

- [ ] **Step 5: Guestbook CGI + LAMP boot-test.** Create a minimal guestbook CGI (perl, uses CGI.pm + DBI/DBD::SQLite to insert+read a row). Serve it via busybox httpd in the boot-test's network path (the nat-router/curl boot-test already exercises HTTP). Add `smoke_guestbook`: start `httpd -f -p 8080 -h <docroot>` on the guest, POST to the CGI, assert the returned/stored row. Follow the existing HTTP boot-test wiring (the client→httpd path in `smoke_curl`/nat-router). If the guestbook file is hand-authored in the rootfs, add it to `configs/attestation/unowned-allowlist.yaml` + install it in `build-rootfs.sh` (the `which`/monolith-console precedent).

- [ ] **Step 6: Validate via CI.** Push, full-ci. All new smokes green: `smoke_perl_cgi`, `smoke_guestbook`. Boot matrix + attestation green. Note the 486-profile perl start time (BIOS job) — record if >5s, do NOT gate on it.

- [ ] **Step 7: Commit.**
```bash
git add configs/overlay/dev-lang/monolith-perl scripts/boot-test.py configs/rootfs-overlay configs/attestation/unowned-allowlist.yaml scripts/build-rootfs.sh
git commit -m "feat(sp5): CGI.pm rider + prune pass + guestbook LAMP boot-test"
```

---

### Task 5 (P5): Report + decisions

**Files:**
- Create: `.batteries/reports/perl.md`
- Create: `docs/superpowers/plans/DECISIONS.md` (or alongside the report) — deviations from D1-D6

- [ ] **Step 1: Write `.batteries/reports/perl.md`** in the house register (match `.batteries/reports/gdb.md`/`mtr.md`): the pinned versions (perl, perl-cross, sqlite, DBI, DBD::SQLite, CGI), the exact static_ext + configure flags that worked, what was pruned (the per-line list from Task 4), the measured sizes vs budget, what was deferred/fell to a fallback, and the three worst fights.
- [ ] **Step 2: Record D1-D6 deviations** in DECISIONS.md (e.g. if DBD used its bundled amalgamation, if a perl-cross flag differed, if CGI.pm was vendored).
- [ ] **Step 3: Commit.**
```bash
git add .batteries/reports/perl.md docs/superpowers/plans/DECISIONS.md
git commit -m "docs(sp5): perl integration report + decisions"
```

---

## Self-Review notes

- **Spec coverage:** D1→Task2 (pairing) + Task3 (static_ext); D2→Task2 config + Task4 podless/prune; D3→Task1; D4→Task3; D5→Task4; D6→Task1/2 world entries. §2 ebuild shape→Task2/3. §3 budget→Task4 Step 4. §4 acceptance→smoke_* across Task1-4. §5 milestones→Task1-5 + fallbacks in Task3 Step 5. §6 constraints→Global Constraints.
- **Research-dependent steps are flagged** with their upstream source (perl-cross releases/README, sqlite download page, CPAN) because exact versions/flag spellings cannot be pinned without checking upstream and iterating — this is inherent to the domain (spec acknowledges "implementer verifies exact spelling").
- **Test cycle = CI full-ci build** (not a fast unit test): each task writes the boot-test smoke assertion FIRST (fails: tool absent), then implements the ebuild, then the build+boot proves it. This is the TDD analog for a cross-compiled-disc deliverable.
