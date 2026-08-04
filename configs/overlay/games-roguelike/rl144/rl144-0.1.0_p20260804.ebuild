# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="rl144 — a deterministic, integer-only roguelike built for the 486DX"
HOMEPAGE="https://github.com/tuckermclean/rl144"

# Pinned to a specific commit on the feature/happy-valley branch (no release tag
# yet). GitHub's per-commit archive is the DIST tarball; the Manifest pins its
# exact bytes. If GitHub's archive gzip ever drifts and the hash mismatches,
# host the tarball in the project's own S3 and repoint SRC_URI.
COMMIT="e82e00e0aaa411fa44e879b065fecbca1be19553"
SRC_URI="https://github.com/tuckermclean/rl144/archive/${COMMIT}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/rl144-${COMMIT}"

# rl144 is MIT-licensed (LICENSE file committed on the repo's master branch).
# NOTE: the pinned commit is on feature/happy-valley (where the 486 target spec
# and design docs live), and master's LICENSE has not been merged there yet, so
# this commit's tree does not carry the LICENSE file. The declaration here is
# accurate; for full MIT compliance, merge the LICENSE onto the 486 branch (or
# cut a tag that has both) and re-pin so the shipped source includes it.
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

	# panic=immediate-abort (this nightly's replacement for the older
	# build-std-features=panic_immediate_abort spelling) drops the LLVM
	# libunwind dependency entirely — the crossdev toolchain only ships
	# libgcc's unwinder, not libunwind. It's an unstable panic strategy, so
	# it must go through RUSTFLAGS (applies to build-std's core too, not
	# just rl144's own crate) rather than a -Z build-std-features flag.
	# rl144's Cargo.toml already sets profile.release panic="abort"; this
	# overrides it to immediate-abort, which is intended.
	export RUSTFLAGS="-Zunstable-options -Cpanic=immediate-abort ${RUSTFLAGS}"

	einfo "Cross-compiling rl144 for ${RUST_TARGET} (nightly build-std, backend-term)"
	cargo "+${RUST_NIGHTLY}" \
		-Z build-std=std \
		-Z unstable-options \
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

	exeinto /usr/games/bin
	doexe "${bin}"

	dodoc "${S}/docs/design/486/2026-08-04-boot-on-a-486-scope.md" 2>/dev/null || true
}
