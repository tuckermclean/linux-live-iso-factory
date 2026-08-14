#!/bin/sh
set -u
f=scripts/build-rootfs.sh
fails=0
# monolith-net is installed via the app-misc/monolith-base ebuild (Pillar 4)
# rather than a hand-install line in build-rootfs.sh; check the package owns
# it and is pulled into the sysroot instead.
grep -q 'exeinto /usr/bin' configs/overlay/app-misc/monolith-base/*.ebuild \
    || { echo "FAIL: monolith-base ebuild does not install to /usr/bin"; fails=1; }
grep -q 'doexe "\${FILESDIR}/monolith-net"' configs/overlay/app-misc/monolith-base/*.ebuild \
    || { echo "FAIL: monolith-base ebuild does not install monolith-net"; fails=1; }
[ -f configs/overlay/app-misc/monolith-base/files/monolith-net ] \
    || { echo "FAIL: monolith-net source file missing from monolith-base FILESDIR"; fails=1; }
grep -q '^app-misc/monolith-base$' configs/portage/world \
    || { echo "FAIL: app-misc/monolith-base not in configs/portage/world"; fails=1; }
grep -q 'init.d/S35netprobe' "$f" || { echo "FAIL: S35netprobe not created"; fails=1; }
grep -q 'monolith-net autoprobe' "$f" || { echo "FAIL: S35netprobe does not call 'monolith-net autoprobe'"; fails=1; }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
