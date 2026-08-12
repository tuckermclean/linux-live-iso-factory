# Dockerfile for The Monolith
#
# Pure factory — Gentoo crossdev toolchain + ISO assembly tools.
# No sources baked in; all packages arrive via portage at build time.
#
# Usage:
#   make build-image        # Build this image (includes crossdev toolchain)
#   make build-packages     # Cross-compile all packages (kernel, busybox, userland)
#   make iso                # Build initrd + rootfs + ISO from compiled packages

# Two epochs, decoupled on purpose:
#   TOOLCHAIN_EPOCH pins the stage3 base image AND the baked portage tree used
#     to build the crossdev toolchain / host tools baked into this image.
#   BUILD_EPOCH pins the *runtime* package tree — the portage snapshot used to
#     resolve target-package versions for the ISO. It is NOT baked into this
#     image; scripts/sync-portage.sh injects it at build time. It also drives
#     SOURCE_DATE_EPOCH below so build output timestamps stay reproducible
#     against the runtime snapshot date.
# Keeping these independent means a pruned/rotated runtime snapshot doesn't
# force a toolchain image rebuild, and vice versa.
#
# TOOLCHAIN_EPOCH must be a date that has a PUBLISHED gentoo/stage3 image tag.
# Those are cut ~weekly (Mondays), NOT daily, so it will usually lag BUILD_EPOCH
# (which tracks the daily portage snapshot). 20260810 is the latest weekly stage3
# tag; 20260811 is the daily runtime snapshot. This intentional 1-day skew is the
# decoupling working as designed.
# Update with: make update-build-pins
ARG TOOLCHAIN_EPOCH=20260810
ARG BUILD_EPOCH=20260811
FROM gentoo/stage3:amd64-openrc-${TOOLCHAIN_EPOCH} AS base-tools

LABEL maintainer="monolith-builder"
LABEL description="Gentoo crossdev environment for i486-linux-musl + ISO tools"

# Reproducibility: clamp all build output timestamps to the runtime snapshot
# date (BUILD_EPOCH = 20260811 -> 2026-08-11T00:00:00Z)
ENV SOURCE_DATE_EPOCH=1786406400

ENV CROSS_TARGET=i486-linux-musl
ENV CROSS_COMPILE=i486-linux-musl-

# Re-declare so the values are available inside this stage (ARGs don't cross FROM)
ARG TOOLCHAIN_EPOCH
ARG BUILD_EPOCH

# Verify host gcc has 32-bit multilib support (gcc -m32).
#
# make.conf sets CFLAGS_FOR_BUILD="-O2 -m32" and configs/portage/bashrc's
# CC_FOR_BUILD hook uses it to compile nethack's build-host tools (makedefs,
# lev_comp, dgn_comp, dlb) as 32-bit x86 binaries. Those tools generate the
# DLB archive (nhdat) that is later read by the i486 target binary; the
# DLB entry struct uses a bare `long` (4 bytes on i486, 8 bytes on x86_64),
# so without -m32 support the archive index would be misread and nethack's
# dungeon data would be corrupted at runtime. Fail the image build early and
# loudly rather than letting that surface as a silent runtime bug days later.
RUN if ! (echo 'int main(void){return 0;}' | gcc -m32 -xc -o /tmp/m32check -); then \
        echo "ERROR: host gcc lacks -m32 multilib support." >&2; \
        echo "  CFLAGS_FOR_BUILD=-m32 (make.conf) requires it to compile" >&2; \
        echo "  nethack's DLB build tools with a 32-bit ABI. Install the" >&2; \
        echo "  multilib profile / 32-bit glibc, or patch nethack's DLB" >&2; \
        echo "  structs to use int32_t/int64_t instead of 'long' as a" >&2; \
        echo "  fallback (see RELEASE-READINESS.md)." >&2; \
        exit 1; \
    fi && /tmp/m32check && rm -f /tmp/m32check && echo "gcc -m32 multilib: OK"

# Fetch the toolchain's baked portage tree using portage's own tooling.
# --revert pins to a specific date for reproducibility; emerge-webrsync handles
# GPG verification internally using its bundled Gentoo release signing key
# (DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D) — build fails if signature invalid.
# This tree is pinned to TOOLCHAIN_EPOCH, not BUILD_EPOCH: it only resolves
# host build tools and the crossdev toolchain baked into this image. It is
# NOT the runtime package tree used to build ISO packages — that tree is
# pinned to BUILD_EPOCH and injected separately by scripts/sync-portage.sh.
RUN emerge-webrsync --revert=${TOOLCHAIN_EPOCH}

# Install all host tools
# cmake:   prevents BDEPEND from pulling in cmake-9999 (live ebuild)
# mandoc:  host makewhatis called by bashrc hook to build whatis DB in sysroot
# ncurses: host tic needed to install terminfo DB into sysroot during cross-compile
#
# Version pinning: none of these packages carry an explicit version atom.
# They are host build tools (not shipped in the ISO) and are pinned
# *indirectly* via TOOLCHAIN_EPOCH: emerge-webrsync --revert=${TOOLCHAIN_EPOCH}
# above fixes the baked portage snapshot date, which in turn fixes which
# version of each package is "best visible" here. This is intentional and
# matches the crossdev toolchain's own pinning story (crossdev.lock +
# versions.lock still pin exact versions for the *target* toolchain and
# world packages — see configs/portage/versions.lock, managed by
# `make update-versions`).
# There is deliberately no per-atom pin (e.g. "=sys-boot/syslinux-6.03") for
# these host tools: that would fight the epoch model by letting a single
# tool drift ahead of/behind the snapshot it was validated against. If a
# specific host tool version ever needs to be held back independent of the
# epoch, add it to a package.mask file under configs/portage/ rather than
# an uninspected Dockerfile ENV var: a stale "ENV SYSLINUX_VERSION=6.03"
# previously lived here as pure documentation. It was never read by emerge
# and could silently drift from what actually got installed, so it has
# been replaced by this comment rather than reintroduced as a misleading pin.
RUN GRUB_PLATFORMS="efi-32 efi-64" emerge --noreplace \
        sys-devel/crossdev \
        app-portage/gentoolkit \
        app-portage/eix \
        sys-devel/flex \
        sys-devel/bison \
        sys-devel/bc \
        dev-libs/elfutils \
        sys-boot/syslinux \
        sys-boot/grub \
        dev-libs/libisoburn \
        sys-fs/mtools \
        sys-fs/dosfstools \
        sys-fs/squashfs-tools \
        app-arch/xz-utils \
        net-misc/rsync \
        sys-apps/file \
        dev-vcs/git \
        app-arch/cpio \
        dev-build/cmake \
        app-text/mandoc \
        sys-libs/ncurses && \
    eix-update && \
    rm -rf /var/cache/distfiles/*

# Attestation tools: Syft (SBOM generation) + Grype (CVE scanning) + pyyaml
# These are installed into the builder image so CI doesn't re-download them
# on every run. The Grype vulnerability database is stored in a separate
# Docker volume (monolith-grype-db) and updated via `make grype-db-update`.
RUN emerge dev-python/pyyaml && \
    for tool in syft grype; do \
        n=0; \
        until curl -sSfL "https://raw.githubusercontent.com/anchore/$tool/main/install.sh" \
                | sh -s -- -b /usr/local/bin; do \
            n=$((n+1)); \
            if [ "$n" -ge 6 ]; then \
                echo "FATAL: $tool install failed after 6 attempts (GitHub release API unreachable)" >&2; \
                exit 1; \
            fi; \
            echo "  $tool install failed (transient GitHub error?) — retry $n/6 in 30s..." >&2; \
            sleep 30; \
        done; \
    done && \
    rm -rf /var/cache/distfiles/*

# Rust toolchain for building games-roguelike/rl144 — a 486-class Rust roguelike.
# rl144 needs nightly + -Zbuild-std to compile Rust's std for the custom
# i486-unknown-linux-musl target (i486 has no prebuilt Rust std). Installed via
# rustup with a PINNED nightly (reproducibility, matching the BUILD_EPOCH spirit)
# and the rust-src component. System-wide under /opt so the portage build user
# can read it; the ebuild links with the crossdev i486-linux-musl-gcc. Kept out
# of portage on purpose — nightly + build-std for a custom JSON target is a
# rustup workflow, not dev-lang/rust. Pin MUST match the rl144 ebuild's
# RUST_NIGHTLY (configs/overlay/games-roguelike/rl144/*.ebuild).
ENV RUSTUP_HOME=/opt/rustup \
    PATH=/opt/cargo/bin:${PATH}
RUN export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo && \
    curl --proto '=https' --tlsv1.2 -sSfL https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal \
              --default-toolchain nightly-2026-07-15 --component rust-src && \
    chmod -R a+rX /opt/rustup /opt/cargo && \
    /opt/cargo/bin/rustc --version && \
    rm -rf /var/cache/distfiles/*

# Configure portage overlays and policy
RUN mkdir -p /var/db/repos/crossdev/{profiles,metadata} && \
    echo 'crossdev' > /var/db/repos/crossdev/profiles/repo_name && \
    echo 'masters = gentoo' > /var/db/repos/crossdev/metadata/layout.conf && \
    chown -R portage:portage /var/db/repos/crossdev && \
    mkdir -p /etc/portage/repos.conf && \
    printf '[crossdev]\nlocation = /var/db/repos/crossdev\npriority = 10\nmasters = gentoo\nauto-sync = no\n' \
        > /etc/portage/repos.conf/crossdev.conf && \
    printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
        > /etc/portage/repos.conf/monolith.conf && \
    mkdir -p /etc/portage/package.accept_keywords && \
    echo '*/* **' > /etc/portage/package.accept_keywords/crossdev-all && \
    echo 'sys-kernel/linux-live **' > /etc/portage/package.accept_keywords/monolith && \
    echo 'FEATURES="${FEATURES} -strict"' >> /etc/portage/make.conf && \
    mkdir -p /etc/portage/env /etc/portage/package.env && \
    printf '%s\n' \
        '# Force libatomic.a (and the other target runtime libs) to be built and' \
        '# installed statically for the cross-gcc. This is the toolchain-side twin' \
        '# of configs/portage/env/static.conf: static-libs is NOT a real USE flag on' \
        '# sys-devel/gcc (toolchain.eclass IUSE never defines it — the old' \
        '# package.use "static-libs" line was a silent no-op), so EXTRA_ECONF is the' \
        '# mechanism the eclass actually honors. Without libatomic.a, any package' \
        '# needing 8-byte atomics on -march=i486 (no cmpxchg8b) fails to link -static' \
        '# ("attempted static link of dynamic object libatomic.so") — iperf3,' \
        '# w3m (via boehm-gc), irssi (via glib). Baked here in base-tools so the' \
        '# crossdev toolchain build (make build-image) picks it up, and so editing' \
        '# it changes the Dockerfile hash -> REGISTRY_TAG -> forces the rebuild.' \
        'EXTRA_ECONF="--disable-shared --enable-static"' \
        > /etc/portage/env/cross-gcc-static.conf && \
    echo "cross-${CROSS_TARGET}/gcc cross-gcc-static.conf" \
        > /etc/portage/package.env/cross-gcc-static

# crossdev toolchain build and runtime setup are handled by `make build-image`.
# Running crossdev via `docker run` (not `docker build`) ensures all portage logs
# are captured to output/portage-logs/ on the host via LOGS_MOUNT.
