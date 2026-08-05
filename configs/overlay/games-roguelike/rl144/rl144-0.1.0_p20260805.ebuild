# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="rl144 — a deterministic, integer-only roguelike built for the 486DX"
HOMEPAGE="https://github.com/tuckermclean/rl144"

# Pinned to a specific commit (no release tag yet). As of this sync master and
# feature/happy-valley have converged, so this HEAD carries both the 486 target
# spec/design docs AND the LICENSE. GitHub's per-commit archive is the DIST
# tarball; the Manifest pins its exact bytes. If GitHub's archive gzip ever
# drifts and the hash mismatches, host the tarball in the project's own S3 and
# repoint SRC_URI.
COMMIT="f33a80efc4b0b02ce72e708182594b84695e742d"
SRC_URI="https://github.com/tuckermclean/rl144/archive/${COMMIT}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/rl144-${COMMIT}"

# rl144 is MIT-licensed; the LICENSE file is present in this commit's tree (the
# earlier happy-valley/master split is resolved now that they've converged), so
# the shipped source carries it and src_install dodoc's it below.
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

# build-std compiles Rust's std itself, which pulls std's own pinned crate deps
# (libc, object, gimli, ...) from crates.io during src_compile. Allow it out of
# the network sandbox; the versions are pinned by the nightly's rust-src
# Cargo.lock, so the fetched content is deterministic. Future hardening: vendor
# these into the builder image so this build is fully offline.
RESTRICT="network-sandbox"

# The Rust toolchain is provided by the builder image via rustup (see Dockerfile),
# NOT by portage: nightly + -Zbuild-std for a custom JSON target is a rustup
# workflow, and i486 has no prebuilt Rust std. This pin MUST match the
# Dockerfile's RUST_NIGHTLY.
RUST_NIGHTLY="nightly-2026-07-15"
RUST_TARGET="i486-unknown-linux-musl"

src_compile() {
	local target_json="${FILESDIR}/${RUST_TARGET}.json"
	[[ -f "${target_json}" ]] || die "target spec missing: ${target_json}"

	# The rustup toolchain lives system-wide in the builder image; give cargo its
	# own writable CARGO_HOME/target inside the build dir. Re-export RUSTUP_HOME
	# and PATH here in case portage's env filtering dropped them.
	export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
	export CARGO_HOME="${T}/cargo"
	export CARGO_TARGET_DIR="${WORKDIR}/cargo-target"
	export PATH="/opt/cargo/bin:${PATH}"

	# Link the custom i486 target with the crossdev musl gcc — the same toolchain
	# that builds the rest of the ISO. CHOST is i486-linux-musl under cross-emerge,
	# so ${CHOST}-gcc is i486-linux-musl-gcc. cargo derives the env-var target name
	# from the JSON filename stem (i486-unknown-linux-musl).
	export "CARGO_TARGET_I486_UNKNOWN_LINUX_MUSL_LINKER=${CHOST}-gcc"

	# Diagnostics: confirm CHOST/linker resolve as expected and show where the
	# crossdev musl gcc driver actually finds its crt objects (crtend.o/crtn.o),
	# in case the crossdev sysroot layout is nonstandard.
	einfo "CHOST=${CHOST}  linker=${CARGO_TARGET_I486_UNKNOWN_LINUX_MUSL_LINKER}"
	i486-linux-musl-gcc -print-file-name=crtn.o || true
	i486-linux-musl-gcc -print-file-name=crtend.o || true
	i486-linux-musl-gcc -print-search-dirs || true

	# link-self-contained=no: by default rustc links "self-contained" —
	# passes -nostartfiles -nodefaultlibs, supplies its own bare
	# crt1.o/crti.o/crtbegin.o/crtend.o/crtn.o, and only -L's its own
	# rustlib self-contained dir (empty for this custom target; those
	# objects live in the crossdev toolchain, not rustc's sysroot). This
	# was the source of "cannot find crtend.o/crtn.o". Disabling
	# self-contained linking lets the i486-linux-musl-gcc driver supply
	# its own crt objects/libs from paths it already knows (confirmed via
	# -print-file-name above: crtn.o under /usr/i486-linux-musl/usr/lib/,
	# crtend.o under /usr/lib/gcc/i486-linux-musl/15/).
	#
	# The target spec itself now sets "panic-strategy": "abort" (see
	# files/i486-unknown-linux-musl.json), matching rl144's Cargo.toml
	# profile.release panic="abort" all the way down through build-std.
	# That does NOT remove the -lunwind reference on its own — std's
	# backtrace support still references _Unwind_* symbols regardless of
	# panic strategy, so rustc still links -lunwind. The crossdev
	# musl/gcc toolchain has no standalone libunwind at all; the unwinder
	# lives in libgcc. Alias libgcc's unwinder archive as libunwind.a so
	# the link resolves against the real _Unwind_* symbols it provides.
	local _unwind
	_unwind=$("${CHOST}-gcc" -print-file-name=libgcc_eh.a)
	[[ -f "${_unwind}" ]] || _unwind=$("${CHOST}-gcc" -print-file-name=libgcc.a)
	mkdir -p "${T}/unwindlib"
	ln -sf "${_unwind}" "${T}/unwindlib/libunwind.a"
	einfo "aliased libunwind -> ${_unwind}"
	export RUSTFLAGS="-Clink-self-contained=no -Clink-arg=-L${T}/unwindlib ${RUSTFLAGS}"

	einfo "Cross-compiling rl144 for ${RUST_TARGET} (nightly build-std, backend-term)"
	cargo "+${RUST_NIGHTLY}" \
		-Z build-std=std,panic_abort \
		-Z json-target-spec \
		build --release \
		--no-default-features --features backend-term \
		--target "${target_json}" \
		--manifest-path "${S}/Cargo.toml" \
		|| die "cargo build failed"
}

src_install() {
	local bin="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/rl144"
	[[ -x "${bin}" ]] || die "rl144 binary not found at ${bin}"

	# The rootfs is all-static and i486: a dynamic or wrong-arch binary would
	# fail at boot. Verify before shipping (readelf reads the ELF header
	# arch-independently on the x86_64 host).
	if command -v readelf >/dev/null 2>&1; then
		readelf -l "${bin}" 2>/dev/null | grep -q 'INTERP' \
			&& die "rl144 is dynamically linked (needs crt-static)"
		readelf -h "${bin}" 2>/dev/null | grep -qE 'Intel 80386|:.*386' \
			|| ewarn "rl144 ELF machine is not Intel 80386 — check the target spec"
	fi

	# Install to /usr/bin (on the default PATH) rather than /usr/games/bin,
	# which the rootfs does not add to PATH — mirrors where games-misc/bsd-games
	# land so `rl144` is runnable straight from the shell like the other games.
	exeinto /usr/bin
	doexe "${bin}"

	dodoc "${S}/LICENSE"
	dodoc "${S}/docs/design/486/2026-08-04-boot-on-a-486-scope.md" 2>/dev/null || true
}
