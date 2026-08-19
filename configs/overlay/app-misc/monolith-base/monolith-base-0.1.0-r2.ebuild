# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Hand-authored rootfs helpers for The Monolith (net/router/console, which, guestbook CGI, advisory banner, prompt)"
HOMEPAGE="https://github.com/tuckermclean/linux-live-iso-factory"

# No upstream source — every file here is hand-authored in-tree under
# FILESDIR (previously configs/rootfs-overlay/ + ad-hoc `install` lines in
# scripts/build-rootfs.sh; see git history). Nothing to fetch or unpack, so
# S is pinned to WORKDIR — EAPI 8's default S="${WORKDIR}/${P}" would not
# exist since there is no SRC_URI to create it.
S="${WORKDIR}"

# In-house scripts; no single upstream license file to point to.
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"

src_install() {
	# /usr/bin — monolith-net (SP1 ISA NIC probe helper) and the POSIX-sh
	# `which` (GNU sys-apps/which doesn't build against musl; busybox isn't
	# in this rootfs). Unit-tested standalone: scripts/tests/monolith-net.test.sh.
	exeinto /usr/bin
	doexe "${FILESDIR}/monolith-net"
	doexe "${FILESDIR}/which"
	# startx (SP-GUI G2): brings up Xfbdev (built-in fonts) + a terminal (st) on
	# the framebuffer. Hand-authored → owned here so it isn't an unowned rootfs
	# file (attestation Pillar 4). See files/startx.
	doexe "${FILESDIR}/startx"
	# monolith (Monolith UX Pass, Task 1): the front door — lists the helpers
	# and curated tools below instead of leaving them to tribal knowledge.
	# Unit-tested standalone: scripts/tests/monolith.test.sh.
	doexe "${FILESDIR}/monolith"

	# /usr/sbin — monolith-router (SP2/SP3 NAT + dnsmasq DHCP/DNS helper,
	# unit-tested: scripts/tests/monolith-router.test.sh), monolith-console
	# (lazy auto-login shell, see /etc/inittab), and the advisory-check
	# fetcher (runs from /etc/init.d/S50advisory).
	exeinto /usr/sbin
	doexe "${FILESDIR}/monolith-router"
	doexe "${FILESDIR}/monolith-console"
	doexe "${FILESDIR}/monolith-advisory-check"
	# monolith-time (UX Pass Task 2, the clock landmine): sets the clock
	# from an HTTP Date header, and monolith-time-check, the gate that
	# decides WHEN it's allowed to run (demonstrated ignorance only — see
	# the INVARIANT in monolith-time-check). Runs from
	# /etc/init.d/S45monolith-time. Unit-tested standalone:
	# scripts/tests/monolith-time.test.sh.
	doexe "${FILESDIR}/monolith-time"
	doexe "${FILESDIR}/monolith-time-check"

	# /usr/lib/cgi-bin — SP5 P4 LAMP-invariant guestbook fixture (perl +
	# CGI.pm + the sqlite3 CLI). Ships executable; perl reads its own
	# shebang. See scripts/boot-test.py smoke_guestbook.
	exeinto /usr/lib/cgi-bin
	doexe "${FILESDIR}/guestbook.cgi"

	# /usr/share/monolith — curated topic text for `monolith help <topic>` /
	# `monolith tools` (Task 1). Plain text, cat/pager'd, never generated.
	insinto /usr/share/monolith
	doins "${FILESDIR}/topics/"*.txt

	# /etc/profile.d — sourced by /etc/profile, not executed directly.
	insinto /etc/profile.d
	doins "${FILESDIR}/monolith-advisory.sh"
	doins "${FILESDIR}/monolith-time-hint.sh"

	# /etc/bash/bashrc.d — sourced from bash's bashrc.d chain; runs last
	# (after 10-gentoo-color.bash sets PS1) to prepend the dark-grey ■.
	insinto /etc/bash/bashrc.d
	doins "${FILESDIR}/99-monolith-square.bash"
}
