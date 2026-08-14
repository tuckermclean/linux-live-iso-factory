#!/bin/sh
set -u
fails=0
# monolith-router is installed via the app-misc/monolith-base ebuild
# (Pillar 4), not a hand-install line in build-rootfs.sh; check the package
# owns it and that it is NOT (re-)allowlisted as unowned.
grep -q 'doexe "\${FILESDIR}/monolith-router"' configs/overlay/app-misc/monolith-base/*.ebuild \
    || { echo "FAIL: monolith-base ebuild does not install monolith-router"; fails=1; }
[ -f configs/overlay/app-misc/monolith-base/files/monolith-router ] \
    || { echo "FAIL: monolith-router source file missing from monolith-base FILESDIR"; fails=1; }
grep -q '^\s*-\s*usr/sbin/monolith-router\s*$' configs/attestation/unowned-allowlist.yaml && { echo "FAIL: monolith-router should be owned by monolith-base, not allowlisted"; fails=1; }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
