#!/bin/sh
set -u
fails=0
grep -q 'rootfs-overlay/usr/sbin/monolith-router' scripts/build-rootfs.sh || { echo "FAIL: monolith-router not installed"; fails=1; }
grep -q '^\s*-\s*usr/sbin/monolith-router\s*$' configs/attestation/unowned-allowlist.yaml || { echo "FAIL: monolith-router not allowlisted"; fails=1; }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
