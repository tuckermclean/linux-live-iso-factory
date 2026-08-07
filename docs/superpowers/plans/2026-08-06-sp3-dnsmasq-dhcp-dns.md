# SP3 — dnsmasq LAN DHCP+DNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `net-dns/dnsmasq` and fold opt-in, secure-by-default LAN DHCP+DNS into `monolith-router`, completing the NAT+DHCP+DNS home-router trifecta.

**Architecture:** One new static package (dnsmasq). `monolith-router` gains a `--dhcp` opt-in (plus `--domain` and `--yes`) that, after a fail-closed safety gate, writes an ephemeral dnsmasq config under `/run/monolith-router/` and launches dnsmasq bound to the LAN interface only. Unit tests stub `dnsmasq` on PATH the way `nft`/`ip` are already stubbed; the SP2 two-node CI test is extended so the client leases via DHCP and resolves a zone name through the box.

**Tech Stack:** POSIX `/bin/sh`, `net-dns/dnsmasq` (static musl), Gentoo Portage USE flags, pexpect/QEMU boot-test, `dhcpcd` (client), `nslookup`/`netstat` (assertions).

## Global Constraints

- **All-static rootfs** — every binary static musl; dnsmasq inherits the global `*/* static static-libs`. (See `configs/portage/package.use/static`.)
- **IPv4-only** — project-wide `-ipv6`; dnsmasq built and configured IPv4-only.
- **Attestation Pillar 4** — any rootfs file not owned by a package and not in `configs/attestation/unowned-allowlist.yaml` fails the build. Runtime files under `/run` (tmpfs) are NOT in the squashfs and need no entry; only build-time artifacts do.
- **Default LAN zone** = `home.arpa` (RFC 8375). Overridable via `--domain <zone>` / `$MONOLITH_LAN_DOMAIN`.
- **Default LAN CIDR** = `192.168.99.1/24` (`$MONOLITH_LAN_CIDR`); DHCP supported for `/24` only.
- **DHCP is off by default.** Enabled only by `--dhcp`, gated by a one-time lecture that **fails closed** non-interactively unless `--yes`.
- **Netboot/TFTP/PXE are out of scope** (deferred; dnsmasq built `-tftp`).
- **Merges are the user's** — land work as PRs; do not merge to master.
- Follow existing patterns: `monolith-router` is a standalone POSIX `/bin/sh` script with `$MONOLITH_*` env knobs; unit tests stub tools on PATH.

---

## File Structure

- `configs/portage/world` — add `net-dns/dnsmasq` (modify).
- `configs/portage/package.use/dnsmasq` — dnsmasq USE flags (create).
- `configs/rootfs-overlay/usr/sbin/monolith-router` — the `--dhcp` feature (modify).
- `scripts/tests/monolith-router.test.sh` — unit tests for the new behavior (modify).
- `scripts/boot-test.py` — extend `nat` mode with the DHCP client + asserts (modify).
- `configs/attestation/unowned-allowlist.yaml` — any dnsmasq build-time artifacts (modify, likely no-op).

---

## Task 1: Add net-dns/dnsmasq to the build

**Files:**
- Modify: `configs/portage/world`
- Create: `configs/portage/package.use/dnsmasq`
- Modify: `configs/attestation/unowned-allowlist.yaml` (only if the build flags anything)

**Interfaces:**
- Produces: a static `dnsmasq` binary in the rootfs, used by `monolith-router` (Task 2) and the CI test (Task 4).

No local unit test exists for a Portage config change; it is verified by the full CI build compiling dnsmasq static and the Task 4 two-node test exercising the binary. The steps below add the config and a grep sanity check.

- [ ] **Step 1: Add the USE-flag file**

Create `configs/portage/package.use/dnsmasq`:

```
# dnsmasq for the static i486-musl image: DHCP+DNS for the LAN (see
# monolith-router --dhcp). No dbus IPC surface, no lease-change script exec
# surface, no NLS, IPv4-only (project-wide), no DNSSEC (needs a trust anchor;
# deferred), no TFTP (netboot is deferred behind persistence + an initrd-mod
# selection UI). DHCP and the DNS forwarder/cache are built in by default.
net-dns/dnsmasq -dbus -script -nls -ipv6 -dnssec -tftp
```

- [ ] **Step 2: Add dnsmasq to `world`**

In `configs/portage/world`, under the "Firewall / NAT" / networking block (near `net-firewall/nftables`), add:

```
# DHCP + DNS for the LAN (see monolith-router --dhcp; SP3)
net-dns/dnsmasq
```

- [ ] **Step 3: Sanity-check the config**

Run:
```bash
grep -q '^net-dns/dnsmasq$' configs/portage/world && echo WORLD_OK
grep -q 'net-dns/dnsmasq .*-tftp' configs/portage/package.use/dnsmasq && echo USE_OK
```
Expected: `WORLD_OK` and `USE_OK`.

- [ ] **Step 4: Commit**

```bash
git add configs/portage/world configs/portage/package.use/dnsmasq
git commit -m "feat(sp3): add net-dns/dnsmasq (static, IPv4-only, minimal USE)"
```

- [ ] **Step 5: Attestation follow-up (resolved during CI-green, by the controller)**

dnsmasq owns `/etc/dnsmasq.conf`; the `dnsmasq` user comes from `acct-user/dnsmasq` and `/etc/passwd` is already allowlisted. If the first full CI build's Pillar-4 flags any dnsmasq-created rootfs path (e.g. a `/var/lib/misc` directory), add it to `configs/attestation/unowned-allowlist.yaml` under a new "dnsmasq" comment block, same as SP2's `/var/lib/nftables/rules-save`. Likely a no-op. This step is closed by observing a green `attestation` job, not by local action.

---

## Task 2: `monolith-router --dhcp` — safety gate, config, launch

**Files:**
- Modify: `configs/rootfs-overlay/usr/sbin/monolith-router`
- Test: `scripts/tests/monolith-router.test.sh`

**Interfaces:**
- Consumes: the static `dnsmasq` from Task 1.
- Produces (new env knobs + behavior later tasks/tests rely on):
  - Env: `MONOLITH_RUN_DIR` (default `/run/monolith-router`), `MONOLITH_LAN_DOMAIN` (default `home.arpa`), `MONOLITH_DNSMASQ_USER` (default `nobody`).
  - `cmd_up` accepts `--dhcp`, `--yes`/`--i-understand`, `--domain <z>` / `--domain=<z>` interspersed with the existing `<wan> <lan> [<cidr>]` positionals.
  - On `--dhcp`: writes `$MONOLITH_RUN_DIR/dnsmasq.conf` and runs `dnsmasq --conf-file=$MONOLITH_RUN_DIR/dnsmasq.conf`; writes a per-session `$MONOLITH_RUN_DIR/dhcp-lectured` flag after acknowledgement.
  - Config guarantees (asserted by tests + relied on by Task 4): `interface=<lan>`, `bind-interfaces`, `except-interface=<wan>`, `local-service`, `domain=<zone>`, `local=/<zone>/`, `interface-name=monolith.<zone>,<lan>`, `stop-dns-rebind`, `rebind-localhost-ok`, `domain-needed`, `bogus-priv`, `dhcp-authoritative`, `dhcp-range=<net>.50,<net>.200,12h`, `dhcp-option=option:router,<lanip>`, `dhcp-option=option:dns-server,<lanip>`, `pid-file=$RUNDIR/dnsmasq.pid`, `user=<user>`.

- [ ] **Step 1: Extend the test stub harness for dnsmasq**

In `scripts/tests/monolith-router.test.sh`, inside `setup()` (after the `ip` stub, before `chmod`), add a `dnsmasq` stub and the run-dir/log env. Add these lines:

```sh
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
```

(The existing `chmod +x "$BIN"/*` covers the new stub.)

- [ ] **Step 2: Write the failing tests for the config + gate**

Append to `scripts/tests/monolith-router.test.sh` before the final `echo; [ "$fails" -eq 0 ]` line:

```sh
# 9. --dhcp --yes writes a hardened dnsmasq config with the derived range + zone
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
# 10. --domain overrides the zone
setup
out=$(sh "$SCRIPT" up eth0 eth1 --domain home.example --dhcp --yes </dev/null 2>&1)
has 'domain=home.example'   "$(cat "$DNSMASQLOG")" "--domain overrides zone"
has 'local=/home.example/'  "$(cat "$DNSMASQLOG")" "--domain overrides local zone"
teardown
# 11. safety gate: non-interactive --dhcp WITHOUT --yes fails closed, starts nothing
setup
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: --dhcp without --yes fails closed" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started without consent"; fails=$((fails+1)); else echo "  ok: dnsmasq not started without consent"; fi
teardown
# 12. --dhcp --yes records the lecture flag and starts dnsmasq
setup
out=$(sh "$SCRIPT" up eth0 eth1 --dhcp --yes </dev/null 2>&1)
[ -f "$MONOLITH_RUN_DIR/dhcp-lectured" ] && echo "  ok: lecture flag recorded" || { echo "  FAIL: no lecture flag"; fails=$((fails+1)); }
has 'dnsmasq --conf-file=' "$(cat "$DNSMASQLOG")" "dnsmasq launched"
teardown
# 13. plain up (no --dhcp) never touches dnsmasq
setup
out=$(sh "$SCRIPT" up eth0 eth1 </dev/null 2>&1)
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started without --dhcp"; fails=$((fails+1)); else echo "  ok: no dnsmasq without --dhcp"; fi
teardown
# 14. non-/24 LAN with --dhcp is rejected before dnsmasq is invoked
setup
out=$(sh "$SCRIPT" up eth0 eth1 10.10.0.1/16 --dhcp --yes </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: non-/24 --dhcp rejected" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
if [ -s "$DNSMASQLOG" ]; then echo "  FAIL: dnsmasq started on non-/24"; fails=$((fails+1)); else echo "  ok: dnsmasq not started on non-/24"; fi
teardown
# 15. invalid --domain rejected
setup
out=$(sh "$SCRIPT" up eth0 eth1 --domain 'bad domain' --dhcp --yes </dev/null 2>&1); rc=$?
has 'invalid' "$out" "invalid domain surfaced"
[ "$rc" -ne 0 ] && echo "  ok: invalid domain exits non-zero" || { echo "  FAIL: rc=$rc"; fails=$((fails+1)); }
teardown
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `sh scripts/tests/monolith-router.test.sh`
Expected: the pre-existing tests still pass, and tests 9–15 FAIL (the script doesn't parse `--dhcp` yet, so it treats `--dhcp` as a positional and errors or ignores it; `$DNSMASQLOG` stays empty).

- [ ] **Step 4: Add the config/env constants**

In `configs/rootfs-overlay/usr/sbin/monolith-router`, after the existing `NFT_TABLE="monolith_router"` line, add:

```sh
RUNDIR="${MONOLITH_RUN_DIR:-/run/monolith-router}"
DEFAULT_LAN_DOMAIN="${MONOLITH_LAN_DOMAIN:-home.arpa}"
DNSMASQ_USER="${MONOLITH_DNSMASQ_USER:-nobody}"
```

- [ ] **Step 5: Add the validation + range + gate + start helpers**

In `monolith-router`, after the existing `valid_cidr()` line, add:

```sh
valid_domain() {
    echo "$1" | grep -qE '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
}

# Sets RANGE_START/RANGE_END from a /24 cidr; errors on any other prefix.
derive_dhcp_range() {
    _ip=${1%/*}; _prefix=${1#*/}
    if [ "$_prefix" != 24 ]; then
        echo "monolith-router: --dhcp needs a /24 LAN (got /$_prefix)" >&2; return 1
    fi
    _net=${_ip%.*}
    RANGE_START="$_net.50"; RANGE_END="$_net.200"
}

# One-time-per-boot lecture. Fails closed when non-interactive without --yes.
dhcp_gate() {
    _lan="$1"; _yes="$2"
    [ -f "$RUNDIR/dhcp-lectured" ] && return 0
    cat >&2 <<LEC
monolith-router: enabling a DHCP server on $_lan. It will hand out IP leases
and DNS to everything on that segment. Do NOT do this on a network that already
has a DHCP server (office/dorm/home ISP router) — you will break it. Only
proceed if THIS box owns the LAN.
LEC
    if [ -n "$_yes" ]; then
        :
    elif [ -t 0 ]; then
        printf 'Type "yes" to proceed: ' >&2
        read -r _ans
        [ "$_ans" = yes ] || { echo "monolith-router: aborted." >&2; return 1; }
    else
        echo "monolith-router: refusing to enable DHCP non-interactively without --yes." >&2
        return 1
    fi
    mkdir -p "$RUNDIR" && : > "$RUNDIR/dhcp-lectured"
}

# Writes the hardened dnsmasq config and launches it. $1 lan $2 cidr $3 domain $4 yes
start_dhcp() {
    _lan="$1"; _cidr="$2"; _domain="$3"; _yes="$4"
    valid_domain "$_domain" || { echo "monolith-router: invalid --domain '$_domain'" >&2; return 1; }
    derive_dhcp_range "$_cidr" || return 1
    dhcp_gate "$_lan" "$_yes" || return 1
    _lanip=${_cidr%/*}
    mkdir -p "$RUNDIR"
    cat > "$RUNDIR/dnsmasq.conf" <<CONF
interface=$_lan
bind-interfaces
except-interface=$WAN
local-service
domain=$_domain
local=/$_domain/
expand-hosts
interface-name=monolith.$_domain,$_lan
stop-dns-rebind
rebind-localhost-ok
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=$RANGE_START,$RANGE_END,12h
dhcp-option=option:router,$_lanip
dhcp-option=option:dns-server,$_lanip
pid-file=$RUNDIR/dnsmasq.pid
user=$DNSMASQ_USER
CONF
    if ! dnsmasq --conf-file="$RUNDIR/dnsmasq.conf"; then
        echo "monolith-router: dnsmasq failed to start" >&2; return 1
    fi
    echo "monolith-router: DHCP+DNS up — serving $RANGE_START-$RANGE_END on $_lan, zone $_domain"
}
```

- [ ] **Step 6: Rewrite `cmd_up` to parse the flags and call `start_dhcp`**

Replace the entire existing `cmd_up() { ... }` (from `cmd_up() {` through its closing `}` and final `echo ... NAT up ...`) with:

```sh
cmd_up() {
    _wan=""; _lan=""; _cidr_arg=""; _want_dhcp=""; _yes=""; _domain="$DEFAULT_LAN_DOMAIN"; _np=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dhcp)            _want_dhcp=1 ;;
            --yes|--i-understand) _yes=1 ;;
            --domain)          shift; _domain="${1:-}" ;;
            --domain=*)        _domain="${1#--domain=}" ;;
            --*)               echo "monolith-router: unknown option '$1'" >&2; return 1 ;;
            *)
                _np=$((_np+1))
                case $_np in
                    1) _wan="$1" ;;
                    2) _lan="$1" ;;
                    3) _cidr_arg="$1" ;;
                    *) echo "monolith-router: too many arguments ('$1')" >&2; return 1 ;;
                esac ;;
        esac
        shift
    done
    resolve_ifaces "$_wan" "$_lan" || return 1
    cidr="${_cidr_arg:-$DEFAULT_LAN_CIDR}"
    valid_cidr "$cidr" || { echo "monolith-router: invalid lan-cidr '$cidr' (want A.B.C.D/prefix)" >&2; return 1; }
    if ! echo 1 > "$FORWARD_FILE" 2>/dev/null; then
        echo "monolith-router: cannot enable ip_forward ($FORWARD_FILE)" >&2; return 1
    fi
    ip link set "$LAN" up 2>/dev/null || true
    # A LAN NIC whose boot-time DHCP found no server commonly auto-assigns a
    # 169.254.0.0/16 zeroconf link-local; drop it, then ensure our CIDR is on
    # the interface (idempotent). See PR #18.
    for a in $(ip -4 -o addr show dev "$LAN" 2>/dev/null | awk '{print $4}'); do
        case "$a" in 169.254.*) ip addr del "$a" dev "$LAN" 2>/dev/null || true ;; esac
    done
    if ! ip -4 -o addr show dev "$LAN" 2>/dev/null | awk '{print $4}' | grep -qx "$cidr"; then
        ip addr add "$cidr" dev "$LAN" 2>/dev/null || true
    fi
    nft delete table ip "$NFT_TABLE" 2>/dev/null || true
    if ! nft -f - <<NFT
table ip $NFT_TABLE {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "$WAN" masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname "$LAN" oifname "$WAN" accept
    }
}
NFT
    then
        echo "monolith-router: nft apply failed" >&2
        return 1
    fi
    echo "monolith-router: NAT up — LAN $LAN ($cidr) -> WAN $WAN (masquerade)"
    if [ -n "$_want_dhcp" ]; then
        start_dhcp "$LAN" "$cidr" "$_domain" "$_yes" || return 1
    fi
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `sh scripts/tests/monolith-router.test.sh`
Expected: `ALL PASS` (pre-existing tests 1–8 plus new 9–15). Also run `bash -n configs/rootfs-overlay/usr/sbin/monolith-router` — expect no output.

- [ ] **Step 8: Commit**

```bash
git add configs/rootfs-overlay/usr/sbin/monolith-router scripts/tests/monolith-router.test.sh
git commit -m "feat(sp3): monolith-router --dhcp — gated, hardened dnsmasq LAN DHCP+DNS"
```

---

## Task 3: `down`/`status` dnsmasq integration

**Files:**
- Modify: `configs/rootfs-overlay/usr/sbin/monolith-router`
- Test: `scripts/tests/monolith-router.test.sh`

**Interfaces:**
- Consumes: `$RUNDIR/dnsmasq.pid` written by dnsmasq (Task 2).
- Produces: `down` stops dnsmasq (kill via pidfile) and clears `$RUNDIR`; `status` reports dnsmasq running/not-running.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tests/monolith-router.test.sh` before the final summary line:

```sh
# 16. down stops a running dnsmasq (via pidfile) and clears the run dir
setup
mkdir -p "$MONOLITH_RUN_DIR"
sleep 30 & _sp=$!; echo "$_sp" > "$MONOLITH_RUN_DIR/dnsmasq.pid"
: > "$MONOLITH_RUN_DIR/dnsmasq.conf"
out=$(sh "$SCRIPT" down 2>&1)
sleep 1
if kill -0 "$_sp" 2>/dev/null; then echo "  FAIL: dnsmasq pid still alive after down"; fails=$((fails+1)); kill "$_sp" 2>/dev/null; else echo "  ok: down killed dnsmasq"; fi
[ -f "$MONOLITH_RUN_DIR/dnsmasq.conf" ] && { echo "  FAIL: run dir not cleared"; fails=$((fails+1)); } || echo "  ok: down cleared run dir"
teardown
# 17. status reports dnsmasq running when the pid is alive
setup
mkdir -p "$MONOLITH_RUN_DIR"
sleep 30 & _sp=$!; echo "$_sp" > "$MONOLITH_RUN_DIR/dnsmasq.pid"
out=$(sh "$SCRIPT" status 2>&1)
has 'running' "$out" "status shows dnsmasq running"
kill "$_sp" 2>/dev/null
teardown
# 18. status reports not-running when there is no pidfile
setup
out=$(sh "$SCRIPT" status 2>&1)
has 'not running' "$out" "status shows dnsmasq not running"
teardown
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh scripts/tests/monolith-router.test.sh`
Expected: tests 16–18 FAIL (`down` doesn't touch dnsmasq yet; `status` prints no dnsmasq section).

- [ ] **Step 3: Add `stop_dhcp` and wire `down`/`status`**

In `monolith-router`, replace `cmd_down()` with:

```sh
stop_dhcp() {
    if [ -f "$RUNDIR/dnsmasq.pid" ]; then
        kill "$(cat "$RUNDIR/dnsmasq.pid")" 2>/dev/null || true
    fi
    rm -f "$RUNDIR/dnsmasq.conf" "$RUNDIR/dnsmasq.pid" "$RUNDIR/dhcp-lectured" 2>/dev/null || true
    rmdir "$RUNDIR" 2>/dev/null || true
}

cmd_down() {
    stop_dhcp
    nft delete table ip "$NFT_TABLE" 2>/dev/null || true
    echo 0 > "$FORWARD_FILE" 2>/dev/null || true
    echo "monolith-router: NAT down"
}
```

Then, in `cmd_status()`, before its final `nft list table` block, add a dnsmasq section:

```sh
    echo '--- dhcp/dns (dnsmasq) ---'
    if [ -f "$RUNDIR/dnsmasq.pid" ] && kill -0 "$(cat "$RUNDIR/dnsmasq.pid" 2>/dev/null)" 2>/dev/null; then
        echo "  running (pid $(cat "$RUNDIR/dnsmasq.pid"))"
    else
        echo "  (not running)"
    fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh scripts/tests/monolith-router.test.sh`
Expected: `ALL PASS`. Also `bash -n configs/rootfs-overlay/usr/sbin/monolith-router` — no output.

- [ ] **Step 5: Commit**

```bash
git add configs/rootfs-overlay/usr/sbin/monolith-router scripts/tests/monolith-router.test.sh
git commit -m "feat(sp3): monolith-router down/status manage the dnsmasq lifecycle"
```

---

## Task 4: Extend the two-node CI test — client leases via DHCP

**Files:**
- Modify: `scripts/boot-test.py` (the `run_nat` function)

**Interfaces:**
- Consumes: `monolith-router up ... --dhcp --yes` (Task 2) on the router; `dhcpcd`, `nslookup`, `netstat` in the rootfs.
- Produces: the `nat-router` CI job now proves DHCP leasing + DNS through the box, in addition to NAT.

This task has no local unit test; it is validated by the `nat-router` job in the full CI build. Reuse the existing `drain_router()` + `_diag` harness (do not remove them — see the load-bearing comment).

- [ ] **Step 1: Bring the router up with DHCP**

In `run_nat` (`scripts/boot-test.py`), change the first router assertion from the SP2 `monolith-router eth0 eth1` to enable DHCP:

```python
    results.append(("router: monolith-router up --dhcp",
                    *run_check(child, "monolith-router eth0 eth1 --dhcp --yes",
                               "monolith-router eth0 eth1 --dhcp --yes",
                               contains("DHCP+DNS up"), timeout=60)))
```

Keep the existing `nft masquerade present` and `ip_forward=1` assertions that follow.

- [ ] **Step 2: Add the secure-by-default bind assertion (router side)**

Immediately after the `ip_forward=1` assertion block, add:

```python
    # Secure by default: dnsmasq must be bound to the LAN address only, never
    # the WAN address or a wildcard. netstat (net-tools) is always present.
    results.append(("router: dnsmasq bound to LAN only",
                    *run_check(child, "dnsmasq bind",
                               "netstat -lnu | grep ':53 ' || true",
                               contains("192.168.99.1:53"))))
    results.append(("router: dnsmasq NOT on wildcard",
                    *run_check(child, "dnsmasq no wildcard",
                               "echo bind=$(netstat -lnu | grep -c '0.0.0.0:53')",
                               contains("bind=0"))))
```

- [ ] **Step 3: Replace the client's static config with DHCP**

In `run_nat`, replace the client static-config loop (the `for cmd in ["ip addr add 192.168.99.2/24 ...", ...]` block) with a DHCP lease step. Drain the router first (load-bearing) and give the client a hostname so it registers in the zone:

```python
        drain_router()
        run_check(client, "client hostname", "hostname natclient", exit_code_only())
        # Lease from the box's dnsmasq (one-shot, bounded). dhcpcd writes the
        # box as gateway + DNS into the client's resolv.conf.
        results.append(("client: DHCP lease from the box",
                        *run_check(client, "dhcpcd", "dhcpcd -1 -t 30 eth0",
                                   contains("leased"), timeout=45)))
```

- [ ] **Step 4: Assert the lease is in range and DNS resolves through the box**

Immediately after the DHCP step (still inside the `try`), before the existing positive-curl block, add:

```python
        drain_router()
        # Lease is inside the dnsmasq range 192.168.99.50-200.
        results.append(("client: leased address in DHCP range",
                        *run_check(client, "client addr",
                                   "ip -4 -o addr show dev eth0 | grep -oE '192\\\\.168\\\\.99\\\\.[0-9]+'",
                                   regex_matches(r"192\.168\.99\.(5[0-9]|[6-9][0-9]|1[0-9][0-9]|200)"),
                                   timeout=15)))
        # DNS through the box: resolve the router's own registered name. Proves
        # the client's resolv.conf points at the box and the .home.arpa zone works.
        results.append(("client: resolves monolith.home.arpa via the box",
                        *run_check(client, "nslookup",
                                   "nslookup monolith.home.arpa 192.168.99.1",
                                   contains("192.168.99.1"), timeout=20)))
```

If `regex_matches` is not already imported/available in `run_nat`'s scope, use the module's existing matcher used elsewhere (the SP2 code uses `contains`/`regex_matches` helpers defined in this file); if only `contains` is available, assert `contains("192.168.99.")` on the same command and rely on the NAT curl below as the working-lease proof.

- [ ] **Step 5: Keep the NAT positive + negative controls**

Leave the existing positive `curl ... NAT_OK_marker` retry block and the `monolith-router down` + negative-control block unchanged — they now run over the DHCP-obtained config. (`down` also stops dnsmasq via Task 3.)

- [ ] **Step 6: Verify the script parses and commit**

Run: `python3 -m py_compile scripts/boot-test.py` — expect no output.
Then commit:
```bash
git add scripts/boot-test.py
git commit -m "test(sp3): nat-router client leases via DHCP + resolves .home.arpa through the box"
```

- [ ] **Step 7: Full CI validation (controller, during CI-green)**

Push the branch, label `full-ci`, and confirm the `nat-router` job is green (lease + bind + DNS + NAT all pass) and `attestation` is green (Task 1 Step 5). Re-run `nat-router` 2–3× to confirm stability, applying the two-guest lessons ([[nat-router-linklocal-flake]]: instrument both sides; the link-local fix and `drain_router` are already in place).

---

## Self-Review

**1. Spec coverage:**
- §3 package (static, minimal USE, `-tftp`) → Task 1. ✓
- §4 `--dhcp`/`--domain`/`--yes`, lecture + fail-closed, ordering, runtime state in `/run`, `down`/`status` → Tasks 2 (up/gate) + 3 (down/status). ✓
- §5 all secure-by-default dnsmasq flags, zone `home.arpa`, range from /24, bound-to-LAN, privilege drop → Task 2 Step 5 config + tests. ✓
- §6 attestation → Task 1 Step 5. ✓
- §7 unit tests (config, gate, override, non-/24, down/status) → Tasks 2–3; two-node CI test (DHCP lease, bind assertion, zone resolution, NAT) → Task 4. ✓
- §2 non-goals (netboot/TFTP `-tftp`, IPv6, DNSSEC, non-/24) → honored in Task 1 USE + Task 2 range guard. ✓

**2. Placeholder scan:** No TBD/TODO. The two controller-resolved steps (Task 1 Step 5 attestation, Task 4 Step 7 CI) are explicitly build-environment steps closed by observing green CI, consistent with SP2 — not code placeholders. Task 4 Step 4 names a concrete fallback if `regex_matches` isn't in scope.

**3. Type/name consistency:** Env knobs (`MONOLITH_RUN_DIR`, `MONOLITH_LAN_DOMAIN`, `MONOLITH_DNSMASQ_USER`) and helper names (`valid_domain`, `derive_dhcp_range`/`RANGE_START`/`RANGE_END`, `dhcp_gate`, `start_dhcp`, `stop_dhcp`) are used identically across Tasks 2–3 and match the test assertions and the Task 4 config expectations. `$RUNDIR` files (`dnsmasq.conf`, `dnsmasq.pid`, `dhcp-lectured`) are consistent between write (Task 2), stop (Task 3), and stub (Task 2 Step 1).
