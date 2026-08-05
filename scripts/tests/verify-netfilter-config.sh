#!/bin/sh
set -u
cfg=configs/kernel.config
fails=0
for s in NETFILTER NETFILTER_ADVANCED NF_TABLES_INET; do
    grep -q "^CONFIG_$s=y$" "$cfg" || { echo "FAIL: CONFIG_$s not =y"; fails=$((fails+1)); }
done
for s in NF_CONNTRACK NF_NAT NF_TABLES NFT_CT NFT_NAT NFT_MASQ NF_DEFRAG_IPV4; do
    grep -q "^CONFIG_$s=m$" "$cfg" || { echo "FAIL: CONFIG_$s not =m"; fails=$((fails+1)); }
done
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
