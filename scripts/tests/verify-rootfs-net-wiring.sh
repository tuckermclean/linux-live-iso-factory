#!/bin/sh
set -u
f=scripts/build-rootfs.sh
fails=0
grep -q 'rootfs-overlay/usr/bin/monolith-net' "$f" || { echo "FAIL: monolith-net not installed by build-rootfs.sh"; fails=1; }
grep -q 'init.d/S35netprobe' "$f" || { echo "FAIL: S35netprobe not created"; fails=1; }
grep -q 'monolith-net autoprobe' "$f" || { echo "FAIL: S35netprobe does not call 'monolith-net autoprobe'"; fails=1; }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
