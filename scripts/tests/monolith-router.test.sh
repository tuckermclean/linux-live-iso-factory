#!/bin/sh
# Unit tests for monolith-router. Stubs nft/ip on PATH, fixtures for sysfs and
# the ip_forward file — no root, no real netfilter.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/rootfs-overlay/usr/sbin/monolith-router"
fails=0
has() { if printf '%s' "$2" | grep -qF "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "$2"; fails=$((fails+1)); fi; }

setup() {
    TMP=$(mktemp -d); export SYS="$TMP/sys"; mkdir -p "$SYS/eth0" "$SYS/eth1"
    export MONOLITH_NET_SYSCLASS="$SYS"
    export MONOLITH_IP_FORWARD="$TMP/ip_forward"; echo 0 > "$MONOLITH_IP_FORWARD"
    export NFTLOG="$TMP/nft.log"; : > "$NFTLOG"
    export IPLOG="$TMP/ip.log"; : > "$IPLOG"
    BIN="$TMP/bin"; mkdir -p "$BIN"
    # stub nft: log argv; for `nft -f -`, append stdin (the ruleset) to the log.
    cat > "$BIN/nft" <<'STUB'
#!/bin/sh
echo "nft $*" >> "$NFTLOG"
if [ "$1" = "-f" ] && [ "$2" = "-" ]; then
    cat >> "$NFTLOG"
    [ -n "${NFT_FAIL:-}" ] && exit 1
fi
exit 0
STUB
    # stub ip: log argv; answer `route show default` from $DEFROUTE_DEV; for
    # `addr show`, emit $IP_EXISTING_INET if set (default none) so a test can
    # simulate the LAN already carrying an address (e.g. a zeroconf link-local).
    cat > "$BIN/ip" <<'STUB'
#!/bin/sh
echo "ip $*" >> "$IPLOG"
[ "$1 $2 $3" = "route show default" ] && [ -n "${DEFROUTE_DEV:-}" ] && echo "default via 10.0.2.2 dev $DEFROUTE_DEV"
case "$*" in *"addr show"*) [ -n "${IP_EXISTING_INET:-}" ] && echo "$IP_EXISTING_INET" ;; esac
exit 0
STUB
    export DNSMASQLOG="$TMP/dnsmasq.log"; : > "$DNSMASQLOG"
    export MONOLITH_RUN_DIR="$TMP/run"
    # stub dnsmasq: log argv and, for --conf-file=PATH, append the conf contents
    # so tests can assert on the generated configuration.
    cat > "$BIN/dnsmasq" <<'STUB'
#!/bin/sh
echo "dnsmasq $*" >> "$DNSMASQLOG"
for a in "$@"; do
    case "$a" in --conf-file=*) cat "${a#--conf-file=}" >> "$DNSMASQLOG" 2>/dev/null ;; esac
done
exit 0
STUB
    chmod +x "$BIN"/*; export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; unset DEFROUTE_DEV; }

# 1. explicit up: masquerade on WAN, forward LAN->WAN, ip_forward=1
setup; out=$(sh "$SCRIPT" up eth0 eth1 2>&1)
has 'masquerade' "$(cat "$NFTLOG")" "up installs masquerade"
has 'oifname "eth0"' "$(cat "$NFTLOG")" "masquerade oifname is WAN"
has 'iifname "eth1" oifname "eth0" accept' "$(cat "$NFTLOG")" "forward LAN->WAN"
has '1' "$(cat "$MONOLITH_IP_FORWARD")" "ip_forward enabled"
teardown
# 2. bare form == up; custom lan-cidr applied to LAN
setup; out=$(sh "$SCRIPT" eth0 eth1 10.10.0.1/24 2>&1)
has 'addr add 10.10.0.1/24 dev eth1' "$(cat "$IPLOG")" "custom lan-cidr assigned to LAN"
teardown
# 3. malformed cidr -> error, exit non-zero
setup; out=$(sh "$SCRIPT" eth0 eth1 not-a-cidr 2>&1); rc=$?
has 'invalid' "$out" "malformed cidr rejected"
[ "$rc" -ne 0 ] && echo "  ok: malformed cidr exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown
# 4. auto-detect: WAN=default-route iface (eth0), LAN=the other (eth1)
setup; out=$(DEFROUTE_DEV=eth0 sh "$SCRIPT" 2>&1)
has 'oifname "eth0"' "$(cat "$NFTLOG")" "auto picks default-route iface as WAN"
teardown
# 5. ambiguous auto (3 non-lo ifaces, one WAN, two LAN candidates) -> error
setup; mkdir -p "$SYS/eth2"; out=$(DEFROUTE_DEV=eth0 sh "$SCRIPT" 2>&1); rc=$?
has 'multiple candidate' "$out" "ambiguous auto errors"
[ "$rc" -ne 0 ] && echo "  ok: ambiguous exits non-zero" || { echo "  FAIL"; fails=$((fails+1)); }
teardown
# 6. down: deletes table, ip_forward=0
setup; echo 1 > "$MONOLITH_IP_FORWARD"; out=$(sh "$SCRIPT" down 2>&1)
has 'delete table ip monolith_router' "$(cat "$NFTLOG")" "down deletes table"
has '0' "$(cat "$MONOLITH_IP_FORWARD")" "down disables ip_forward"
teardown
# 7. status: shows ip_forward + queries the table
setup; out=$(sh "$SCRIPT" status 2>&1)
has 'ip_forward' "$out" "status shows ip_forward"
has 'list table ip monolith_router' "$(cat "$NFTLOG")" "status queries the table"
teardown
# 8. nft apply failure -> up reports error, non-zero exit
setup; out=$(NFT_FAIL=1 sh "$SCRIPT" up eth0 eth1 2>&1); rc=$?
has 'nft apply failed' "$out" "nft failure surfaced"
[ "$rc" -ne 0 ] && echo "  ok: nft-fail exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown
# 9. LAN already carries a 169.254 zeroconf link-local (failed-DHCP fallback):
#    up must DROP it and still assign our CIDR. Regression: the old guard saw an
#    inet and skipped the assignment, so the router held no gateway address.
setup
out=$(IP_EXISTING_INET='3: eth1    inet 169.254.9.9/16 scope global eth1' \
      sh "$SCRIPT" up eth0 eth1 2>&1)
has 'addr del 169.254.9.9/16 dev eth1' "$(cat "$IPLOG")" "up removes stale 169.254 link-local"
has 'addr add 192.168.99.1/24 dev eth1' "$(cat "$IPLOG")" "up assigns LAN cidr despite existing link-local"
teardown
# 10. LAN already has exactly our CIDR -> idempotent, no duplicate add
setup
out=$(IP_EXISTING_INET='3: eth1    inet 192.168.99.1/24 scope global eth1' \
      sh "$SCRIPT" up eth0 eth1 2>&1)
if grep -qF 'addr add 192.168.99.1/24' "$IPLOG"; then
    echo "  FAIL: re-added an already-present CIDR"; fails=$((fails+1))
else echo "  ok: existing exact CIDR not re-added (idempotent)"; fi
teardown
# 11. --dhcp --yes writes a hardened dnsmasq config with the derived range + zone
setup
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp --yes </dev/null 2>&1)
cfg=$(cat "$DNSMASQLOG")
has 'interface=eth1'            "$cfg" "dhcp binds to LAN iface"
has 'bind-interfaces'          "$cfg" "dhcp bind-interfaces"
has 'except-interface=eth0'    "$cfg" "dhcp excludes WAN iface"
has 'local-service'            "$cfg" "dns local-service (no open resolver)"
has 'domain=home.arpa'         "$cfg" "default zone home.arpa"
has 'local=/home.arpa/'        "$cfg" "zone authoritative/not forwarded"
has 'interface-name=monolith.home.arpa,eth1' "$cfg" "router registers its own name"
has 'stop-dns-rebind'          "$cfg" "dns-rebind protection"
has 'domain-needed'            "$cfg" "no plain-name forwarding"
has 'bogus-priv'               "$cfg" "no private-reverse forwarding"
has 'dhcp-authoritative'       "$cfg" "authoritative dhcp"
has 'dhcp-range=192.168.99.50,192.168.99.200,12h' "$cfg" "range derived from /24"
has 'dhcp-option=option:router,192.168.99.1'      "$cfg" "gateway advertised = box"
has 'dhcp-option=option:dns-server,192.168.99.1'  "$cfg" "dns advertised = box"
has 'user=nobody'              "$cfg" "drops privileges"
teardown
# 12. --domain overrides the zone
setup
out=$(sh "$SCRIPT" up eth0 eth1 --domain home.example --dhcp --yes </dev/null 2>&1)
has 'domain=home.example'   "$(cat "$DNSMASQLOG")" "--domain overrides zone"
has 'local=/home.example/'  "$(cat "$DNSMASQLOG")" "--domain overrides local zone"
teardown
# 13. safety gate: non-interactive --dhcp WITHOUT --yes fails closed, starts nothing
setup
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: --dhcp without --yes fails closed" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started without consent"; fails=$((fails+1)); else echo "  ok: dnsmasq not started without consent"; fi
teardown
# 14. --dhcp --yes records the lecture flag and starts dnsmasq
setup
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp --yes </dev/null 2>&1)
[ -f "$MONOLITH_RUN_DIR/dhcp-lectured" ] && echo "  ok: lecture flag recorded" || { echo "  FAIL: no lecture flag"; fails=$((fails+1)); }
has 'dnsmasq --conf-file=' "$(cat "$DNSMASQLOG")" "dnsmasq launched"
teardown
# 15. plain up (no --dhcp) never touches dnsmasq
setup
out=$(sh "$SCRIPT" up eth0 eth1 </dev/null 2>&1)
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started without --dhcp"; fails=$((fails+1)); else echo "  ok: no dnsmasq without --dhcp"; fi
teardown
# 16. non-/24 LAN with --dhcp is rejected before dnsmasq is invoked
setup
out=$(sh "$SCRIPT" up eth0 eth1 10.10.0.1/16 --dhcp --yes </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: non-/24 --dhcp rejected" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started on non-/24"; fails=$((fails+1)); else echo "  ok: dnsmasq not started on non-/24"; fi
teardown
# 17. invalid --domain rejected
setup
out=$(sh "$SCRIPT" up eth0 eth1 --domain 'bad domain' --dhcp --yes </dev/null 2>&1); rc=$?
has 'invalid' "$out" "invalid domain surfaced"
[ "$rc" -ne 0 ] && echo "  ok: invalid domain exits non-zero" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
teardown
# 18. config-injection guard: a newline-bearing --domain is rejected, dnsmasq not started
setup
out=$(sh "$SCRIPT" up eth0 eth1 --domain "$(printf 'dhcp-range=1.2.3.4,1.2.3.9,1h\nhome')" --dhcp --yes </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: newline --domain rejected" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started on injected domain"; fails=$((fails+1)); else echo "  ok: dnsmasq not started on injected domain"; fi
teardown
# 19. consent enforced every time: even with the boot lecture flag already set, a
#     non-interactive --dhcp without --yes still fails closed (starts nothing)
setup
mkdir -p "$MONOLITH_RUN_DIR"; : > "$MONOLITH_RUN_DIR/dhcp-lectured"
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: consent still enforced after lecture cached" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started without consent (post-lecture)"; fails=$((fails+1)); else echo "  ok: dnsmasq not started (post-lecture, no --yes)"; fi
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
