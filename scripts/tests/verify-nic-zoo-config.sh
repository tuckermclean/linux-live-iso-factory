#!/bin/sh
# Intent check on configs/kernel.config (NOT the resolved .config — the CI build
# + boot-test are authoritative; this catches a dropped line early).
set -u
cfg=configs/kernel.config
fails=0
want_m="NE2000 WD80x3 ULTRA EL3 LANCE NE2K_PCI PCNET32 TULIP 8139TOO 8139CP \
E100 VIA_RHINE NATSEMI SIS900 E1000 E1000E IGB R8169 SKY2 VIRTIO_NET VMXNET3 HYPERV_NET"
want_gate="NET_VENDOR_8390 NET_VENDOR_AMD NET_VENDOR_3COM NET_VENDOR_INTEL \
NET_VENDOR_REALTEK NET_VENDOR_NATSEMI NET_VENDOR_SIS NET_VENDOR_VIA NET_VENDOR_MARVELL"
for s in $want_m; do
    grep -q "^CONFIG_$s=m$" "$cfg" || { echo "FAIL: CONFIG_$s is not =m"; fails=$((fails+1)); }
done
for s in $want_gate; do
    grep -q "^CONFIG_$s=y$" "$cfg" || { echo "FAIL: CONFIG_$s gate is not =y"; fails=$((fails+1)); }
done
# Covenant: never bake firmware blobs.
grep -q "^CONFIG_EXTRA_FIRMWARE=" "$cfg" && { echo "FAIL: CONFIG_EXTRA_FIRMWARE must not be set"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
