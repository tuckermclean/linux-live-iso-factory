# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Stele — a finished document-web browser for the 486 (Rust, static, no JavaScript, direct framebuffer)"
HOMEPAGE="https://github.com/tuckermclean/stele-browser"

# Stele is under ACTIVE development (a moving target): this is pinned to a
# specific HEAD commit, NOT a release tag. REPIN EACH BUILD while it churns —
# bump COMMIT + the _pYYYYMMDD date (and -rN if repinning the same day, to bust
# the S3 --usepkg binpkg cache, see [[overlay-ebuild-revbump-busts-binpkg-cache]])
# and regenerate the Manifest. GitHub per-commit archive is the DIST tarball,
# Manifest-pinned (games-roguelike/rl144 precedent; S3 only if GitHub's gzip
# drifts). Version tracks Cargo.toml (0.1.0) + the commit date.
COMMIT="87d4df9469c4bdfa896bfe0d26d86ef62a8135a7"
SRC_URI="https://github.com/tuckermclean/stele-browser/archive/${COMMIT}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/stele-browser-${COMMIT}"

# License: GPL-3 (owner's choice, 2026-08-14). GPL-3 is in portage's @FREE set,
# so this declaration is what actually satisfies the Monolith's ACCEPT_LICENSE
# gate (unset → @FREE) — the emerge accepts it regardless of a repo file. The
# owner is adding a matching GPL-3 LICENSE file to the stele-browser repo (for
# legal correctness + the dodoc below); until it lands, dodoc LICENSE is guarded.
# The compiled-in 8x8 glyph atlas (src/text/glyphs.rs) is separately public-domain.
LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"

# build-std compiles std itself, pulling std's pinned crate deps AND Stele's own
# (gif/jpeg-decoder/png/taffy) from crates.io during src_compile. Cargo.lock is
# committed so the fetched set is deterministic; allow it out of the sandbox
# (rl144 precedent). Future hardening: vendor crates into the builder image.
RESTRICT="network-sandbox"

# The Rust toolchain comes from the monolith-builder image via rustup (see
# Dockerfile), NOT portage. This pin MUST match rust-toolchain.toml in the repo
# AND the Dockerfile's RUST_NIGHTLY (shared with rl144).
RUST_NIGHTLY="nightly-2026-07-15"
RUST_TARGET="i486-monolith-linux-musl"

src_compile() {
	# Stele ships its own i486 floor target spec in-tree (targets/*.json) — no
	# need to stage one from FILESDIR (unlike rl144).
	local target_json="${S}/targets/${RUST_TARGET}.json"
	[[ -f "${target_json}" ]] || die "target spec missing: ${target_json}"

	export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
	export CARGO_HOME="${T}/cargo"
	export CARGO_TARGET_DIR="${WORKDIR}/cargo-target"
	export PATH="/opt/cargo/bin:${PATH}"

	# Link with the crossdev musl gcc (same toolchain as the rest of the ISO).
	# cargo derives the linker env-var name from the JSON target's filename stem
	# (i486-monolith-linux-musl → I486_MONOLITH_LINUX_MUSL).
	export "CARGO_TARGET_I486_MONOLITH_LINUX_MUSL_LINKER=${CHOST}-gcc"

	# Stele DECISIONS D7 (same fix rl144 needs): even with panic=abort, std's
	# musl unwind crate references the _Unwind_* API, so rustc still links
	# -lunwind. The crossdev musl/gcc toolchain has no standalone libunwind — the
	# unwinder lives in libgcc — so alias libgcc_eh.a (fallback libgcc.a) as
	# libunwind.a and add its dir to the link path. The target spec sets
	# self-contained linking off, so the gcc driver supplies crt objects itself.
	local _unwind
	_unwind=$("${CHOST}-gcc" -print-file-name=libgcc_eh.a)
	[[ -f "${_unwind}" ]] || _unwind=$("${CHOST}-gcc" -print-file-name=libgcc.a)
	mkdir -p "${T}/unwindshim"
	ln -sf "${_unwind}" "${T}/unwindshim/libunwind.a"
	einfo "aliased libunwind -> ${_unwind}"
	export RUSTFLAGS="-L ${T}/unwindshim ${RUSTFLAGS}"

	einfo "Cross-compiling Stele for ${RUST_TARGET} (nightly build-std)"
	cargo "+${RUST_NIGHTLY}" \
		-Z build-std=std,panic_abort \
		-Z json-target-spec \
		build --release \
		--target "${target_json}" \
		--manifest-path "${S}/Cargo.toml" \
		|| die "cargo build failed"
}

src_install() {
	local bin="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/stele"
	[[ -x "${bin}" ]] || die "stele binary not found at ${bin}"

	# All-static i486 rootfs: a dynamic or wrong-arch binary would fail at boot
	# (Stele acceptance check A1). Verify before shipping.
	if command -v readelf >/dev/null 2>&1; then
		readelf -l "${bin}" 2>/dev/null | grep -q 'INTERP' \
			&& die "stele is dynamically linked (crt-static did not stick)"
		readelf -h "${bin}" 2>/dev/null | grep -qE 'Intel 80386|:.*386' \
			|| ewarn "stele ELF machine is not Intel 80386 — check the target spec"
	fi

	exeinto /usr/bin
	doexe "${bin}"

	# EAPI-8 dodoc die()s on a missing file (|| can't catch its internal die),
	# so only ship docs that actually exist. LICENSE is picked up automatically
	# once the owner adds the GPL-3 file to the repo; Stele has REPORT.md, not a
	# README. (The repo's stele-charter.md / build-brief are dev docs, skipped.)
	local d
	for d in LICENSE REPORT.md DECISIONS.md JOURNAL.md; do
		[[ -f "${S}/${d}" ]] && dodoc "${S}/${d}"
	done
	[[ -f "${S}/LICENSE" ]] || ewarn "no LICENSE file in the stele-browser repo yet (LICENSE=GPL-3 declared) — owner to add it"
}
