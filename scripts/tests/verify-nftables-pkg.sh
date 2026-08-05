#!/bin/sh
set -u
grep -q '^net-firewall/nftables$' configs/portage/world || { echo "FAIL: nftables not in world"; exit 1; }
echo "ALL PASS"
