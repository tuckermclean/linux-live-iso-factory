# SP2 — Netfilter + nftables + monolith-router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make The Monolith a one-command IPv4 NAT router — netfilter/conntrack/NAT as Tier-2 modules, nftables userland, a `monolith-router` helper, and a real two-node (router+client) CI test.

**Architecture:** Kernel netfilter framework `=y` (gate only) with conntrack/NAT/nftables `=m` (load-on-demand). `net-firewall/nftables` in the image. A standalone, unit-tested `/usr/sbin/monolith-router` installs an nftables masquerade+forward ruleset and enables `ip_forward`. A new `boot-test.py` `nat` mode orchestrates two QEMU guests on a private socket segment; the client reaches a host `http.server` through the router's masquerade.

**Tech Stack:** Linux 6.12.80 kernel config, Gentoo crossdev, `net-firewall/nftables` (+libmnl/libnftnl), POSIX `/bin/sh`, Python 3 + pexpect, GitHub Actions.

## Global Constraints

- Rootfs scripts are **POSIX `/bin/sh`**, all-static. `nft`/`ip` come from `net-firewall/nftables` + `iproute2`.
- **Never ship firmware blobs** (no `CONFIG_EXTRA_FIRMWARE`).
- **Kernel `.config` changes REQUIRE a kernel ebuild revbump** (`-r5 → -r6`) + `versions.lock` pin — binpkg-cache trap.
- Kernel release string `uname -r` = `6.12.80-i486-monolith`; modules under `/lib/modules/6.12.80-i486-monolith/`.
- **Every new hand-authored rootfs file MUST be added to `configs/attestation/unowned-allowlist.yaml`** or the attestation Pillar-4 gate fails the build (the SP1 lesson).
- QEMU and the kernel build cannot run on the authoring machine — CI is authoritative for the two-node NAT path and the static-musl cross-build. Local gates are unit tests + `py_compile` + `bash -n` + YAML parse.
- `configs/` is mounted at `/configs` in the build container (`CONFIGS_DIR=/configs`).

---

## File Structure

- `configs/rootfs-overlay/usr/sbin/monolith-router` — **new**, standalone POSIX script; all NAT logic.
- `scripts/tests/monolith-router.test.sh` — **new**, stub-driven unit tests.
- `scripts/build-rootfs.sh` — **modify**, install `monolith-router`.
- `configs/attestation/unowned-allowlist.yaml` — **modify**, allowlist `usr/sbin/monolith-router`.
- `configs/kernel.config` — **modify**, netfilter gate + `=m` symbols.
- `configs/overlay/sys-kernel/monolith-kernel/…-r5.ebuild` → `-r6.ebuild` — **git mv**; `configs/portage/versions.lock` pin.
- `scripts/tests/verify-netfilter-config.sh` — **new**, intent check on kernel.config.
- `configs/portage/world` + `configs/portage/package.use/nftables` — **modify/new**, nftables userland.
- `scripts/boot-test.py` — **modify**, `nat` mode (two-child orchestration).
- `.github/workflows/boot-test.yml` — **modify**, `nat-router` job; `build.yml` — extend the `.ko` assertion list.

---

## Task 1: `monolith-router` script + unit tests

**Files:**
- Create: `configs/rootfs-overlay/usr/sbin/monolith-router`
- Test: `scripts/tests/monolith-router.test.sh`

**Interfaces:**
- Produces: executable `/usr/sbin/monolith-router` with subcommands `up` (default), `down`, `status`. `up` accepts `[<wan> <lan> [<lan-cidr>]]`; bare `monolith-router <wan> <lan> [<lan-cidr>]` also means up. Reads interfaces from `$MONOLITH_NET_SYSCLASS` (default `/sys/class/net`), ip_forward path from `$MONOLITH_IP_FORWARD` (default `/proc/sys/net/ipv4/ip_forward`), default LAN CIDR from `$MONOLITH_LAN_CIDR` (default `192.168.99.1/24`). Uses `nft` and `ip` from `$PATH`.

- [ ] **Step 1: Write the failing test** — `scripts/tests/monolith-router.test.sh`

```sh
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
[ "$1" = "-f" ] && [ "$2" = "-" ] && cat >> "$NFTLOG"
exit 0
STUB
    # stub ip: log argv; answer `route show default` from $DEFROUTE_DEV; emit no
    # inet for `-4 addr show dev` so the script always assigns the LAN address.
    cat > "$BIN/ip" <<'STUB'
#!/bin/sh
echo "ip $*" >> "$IPLOG"
[ "$1 $2 $3" = "route show default" ] && [ -n "${DEFROUTE_DEV:-}" ] && echo "default via 10.0.2.2 dev $DEFROUTE_DEV"
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
has 'delete table inet monolith_router' "$(cat "$NFTLOG")" "down deletes table"
has '0' "$(cat "$MONOLITH_IP_FORWARD")" "down disables ip_forward"
teardown
# 7. status: shows ip_forward + queries the table
setup; out=$(sh "$SCRIPT" status 2>&1)
has 'ip_forward' "$out" "status shows ip_forward"
has 'list table inet monolith_router' "$(cat "$NFTLOG")" "status queries the table"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/tests/monolith-router.test.sh`
Expected: FAIL (script does not exist).

- [ ] **Step 3: Write the implementation** — `configs/rootfs-overlay/usr/sbin/monolith-router`

```sh
#!/bin/sh
# monolith-router — turn the box into a one-command IPv4 NAT router.
#
# Enables ip_forward and installs an nftables masquerade+forward ruleset so a
# private LAN reaches a WAN. DHCP/DNS for LAN clients is separate (dnsmasq, SP3).
#
#   monolith-router [up] [<wan> <lan> [<lan-cidr>]]   bring NAT up
#   monolith-router down                              tear it down
#   monolith-router status                            show state
#
# With no <wan>/<lan>, WAN = the default-route interface and LAN = the single
# other non-lo interface. <lan-cidr> (default 192.168.99.1/24, or
# $MONOLITH_LAN_CIDR) is the router's own LAN address; clients use its host part
# as their gateway.
set -u

SYSCLASS="${MONOLITH_NET_SYSCLASS:-/sys/class/net}"
FORWARD_FILE="${MONOLITH_IP_FORWARD:-/proc/sys/net/ipv4/ip_forward}"
DEFAULT_LAN_CIDR="${MONOLITH_LAN_CIDR:-192.168.99.1/24}"
NFT_TABLE="monolith_router"

list_ifaces() {
    for d in "$SYSCLASS"/*; do
        [ -e "$d" ] || continue
        n=${d##*/}; [ "$n" = lo ] && continue
        echo "$n"
    done
}

default_route_iface() {
    ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Sets WAN and LAN. $1/$2 override; else autodetect.
resolve_ifaces() {
    if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then WAN=$1; LAN=$2; return 0; fi
    WAN=$(default_route_iface)
    [ -n "$WAN" ] || { echo "monolith-router: no default route — specify <wan> <lan>" >&2; return 1; }
    LAN=""
    for i in $(list_ifaces); do
        [ "$i" = "$WAN" ] && continue
        if [ -n "$LAN" ]; then
            echo "monolith-router: multiple candidate LAN interfaces — specify <wan> <lan>" >&2; return 1
        fi
        LAN=$i
    done
    [ -n "$LAN" ] || { echo "monolith-router: no LAN interface found — specify <wan> <lan>" >&2; return 1; }
}

valid_cidr() { echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; }

cmd_up() {
    resolve_ifaces "${1:-}" "${2:-}" || return 1
    cidr="${3:-$DEFAULT_LAN_CIDR}"
    valid_cidr "$cidr" || { echo "monolith-router: invalid lan-cidr '$cidr' (want A.B.C.D/prefix)" >&2; return 1; }
    if ! echo 1 > "$FORWARD_FILE" 2>/dev/null; then
        echo "monolith-router: cannot enable ip_forward ($FORWARD_FILE)" >&2; return 1
    fi
    ip link set "$LAN" up 2>/dev/null || true
    if ! ip -4 addr show dev "$LAN" 2>/dev/null | grep -q 'inet '; then
        ip addr add "$cidr" dev "$LAN" 2>/dev/null || true
    fi
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    nft -f - <<NFT
table inet $NFT_TABLE {
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
    echo "monolith-router: NAT up — LAN $LAN ($cidr) -> WAN $WAN (masquerade)"
}

cmd_down() {
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    echo 0 > "$FORWARD_FILE" 2>/dev/null || true
    echo "monolith-router: NAT down"
}

cmd_status() {
    printf 'ip_forward: %s\n' "$(cat "$FORWARD_FILE" 2>/dev/null || echo '?')"
    echo '--- interfaces ---'
    for i in $(list_ifaces); do
        printf '  %s: %s\n' "$i" "$(ip -4 addr show dev "$i" 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ')"
    done
    echo '--- nft ruleset ---'
    nft list table inet "$NFT_TABLE" 2>/dev/null || echo "  (no $NFT_TABLE table)"
}

case "${1:-}" in
    down)   cmd_down ;;
    status) cmd_status ;;
    up)     shift; cmd_up "$@" ;;
    "")     cmd_up ;;
    *)      cmd_up "$@" ;;   # bare: <wan> <lan> [<lan-cidr>]
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh scripts/tests/monolith-router.test.sh` → `ALL PASS`.

- [ ] **Step 5: Lint (if available)**

Run: `dash -n configs/rootfs-overlay/usr/sbin/monolith-router` (or `bash -n`). If `shellcheck` is present, `shellcheck -s sh` both files; if absent, note it.

- [ ] **Step 6: Commit**

```bash
git add configs/rootfs-overlay/usr/sbin/monolith-router scripts/tests/monolith-router.test.sh
git commit -m "feat(net): monolith-router one-command NAT + unit tests"
```

---

## Task 2: Install `monolith-router` + allowlist it

**Files:**
- Modify: `scripts/build-rootfs.sh` (install step near the `monolith-net` install, ~line 399)
- Modify: `configs/attestation/unowned-allowlist.yaml`

**Interfaces:**
- Consumes: `configs/rootfs-overlay/usr/sbin/monolith-router` (Task 1).
- Produces: `/usr/sbin/monolith-router` (0755) in the squashfs; an allowlist entry so attestation Pillar 4 passes.

- [ ] **Step 1: Write the failing test** — `scripts/tests/verify-router-wiring.sh`

```sh
#!/bin/sh
set -u
fails=0
grep -q 'rootfs-overlay/usr/sbin/monolith-router' scripts/build-rootfs.sh || { echo "FAIL: monolith-router not installed"; fails=1; }
grep -q '^\s*-\s*usr/sbin/monolith-router\s*$' configs/attestation/unowned-allowlist.yaml || { echo "FAIL: monolith-router not allowlisted"; fails=1; }
[ "$fails" -eq 0 ] && echo "ALL PASS" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/tests/verify-router-wiring.sh` → FAIL.

- [ ] **Step 3: Add the install step** to `scripts/build-rootfs.sh`, right after the `monolith-net` install block (search `rootfs-overlay/usr/bin/monolith-net`):

```bash
    # Install the monolith-router NAT helper (standalone, unit-tested;
    # see configs/rootfs-overlay/usr/sbin/monolith-router + scripts/tests/).
    install -D -m 0755 "${CONFIGS_DIR}/rootfs-overlay/usr/sbin/monolith-router" \
        "$ROOTFS_DIR/usr/sbin/monolith-router"
```

- [ ] **Step 4: Allowlist it.** In `configs/attestation/unowned-allowlist.yaml`, right after the SP1 `usr/bin/monolith-net` entry, add:

```yaml
  # ── NAT router helper (SP2) — pending monolith-base ebuild ──────────────────
  - usr/sbin/monolith-router
```

- [ ] **Step 5: Run test + syntax**

Run: `sh scripts/tests/verify-router-wiring.sh` → `ALL PASS`
Run: `bash -n scripts/build-rootfs.sh` → OK
Run: `python3 -c "import yaml; yaml.safe_load(open('configs/attestation/unowned-allowlist.yaml'))" ` → no error.

- [ ] **Step 6: Commit**

```bash
git add scripts/build-rootfs.sh configs/attestation/unowned-allowlist.yaml scripts/tests/verify-router-wiring.sh
git commit -m "feat(net): install monolith-router + allowlist it"
```

---

## Task 3: Kernel netfilter (`=m`) + revbump `-r6`

**Files:**
- Modify: `configs/kernel.config`
- Rename: `configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r5.ebuild` → `-r6.ebuild`
- Modify: `configs/portage/versions.lock`
- Create: `scripts/tests/verify-netfilter-config.sh`
- Modify: `.github/workflows/build.yml` (extend the `.ko`-ship `MODULES` array)

**Interfaces:**
- Produces: netfilter/conntrack/NAT/nftables modules under `/lib/modules/6.12.80-i486-monolith/`.

- [ ] **Step 1: Write the failing test** — `scripts/tests/verify-netfilter-config.sh`

```sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/tests/verify-netfilter-config.sh` → FAIL.

- [ ] **Step 3: Edit `configs/kernel.config`.** Replace any `# CONFIG_X is not set` (or add the line) so these exist. Note `NF_TABLES_INET` and the two gates are **bools (`=y`)**; the rest are modules (`=m`). Grouping near the existing net options is preferred; `olddefconfig` normalizes ordering:

```
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=m
CONFIG_NF_NAT=m
CONFIG_NF_TABLES=m
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_CT=m
CONFIG_NFT_NAT=m
CONFIG_NFT_MASQ=m
CONFIG_NF_DEFRAG_IPV4=m
```

- [ ] **Step 4: Run verify test** → `ALL PASS`.
> The CI kernel build's `olddefconfig` is authoritative for symbol names/types in the 6.12 tree; if it drops one, the `.ko` assertion (Step 6) catches it. Drop any confirmed-absent symbol from both the config and this test.

- [ ] **Step 5: Revbump the kernel ebuild (MANDATORY)**

```bash
git mv configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r5.ebuild \
       configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r6.ebuild
```
Update the `sys-kernel/monolith-kernel:6.12.80-r5:0` line in `configs/portage/versions.lock` to `-r6`. Verify no stale `-r5` refs: `grep -rn 'monolith-kernel-6.12.80-r5' configs/ scripts/ || echo clean`.

- [ ] **Step 6: Extend the `.ko`-ship assertion** in `.github/workflows/build.yml` — add the netfilter modules to the existing `MODULES=(...)` array (from SP1):

```bash
        nf_conntrack nf_nat nf_tables nft_ct nft_nat nft_masq nf_defrag_ipv4
```

- [ ] **Step 7: Commit**

```bash
git add configs/kernel.config scripts/tests/verify-netfilter-config.sh \
    configs/overlay/sys-kernel/monolith-kernel configs/portage/versions.lock .github/workflows/build.yml
git commit -m "feat(kernel): netfilter/conntrack/NAT/nftables =m + revbump -r6"
```

---

## Task 4: nftables userland

**Files:**
- Modify: `configs/portage/world`
- Create: `configs/portage/package.use/nftables`

**Interfaces:**
- Produces: `nft` in the rootfs (used by `monolith-router` and the NAT test).

- [ ] **Step 1: Write the failing test** — `scripts/tests/verify-nftables-pkg.sh`

```sh
#!/bin/sh
set -u
grep -q '^net-firewall/nftables$' configs/portage/world || { echo "FAIL: nftables not in world"; exit 1; }
echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/tests/verify-nftables-pkg.sh` → FAIL.

- [ ] **Step 3: Add nftables to `configs/portage/world`** (in a sensible section, e.g. near the networking tools):

```
# Firewall / NAT (see monolith-router; SP2)
net-firewall/nftables
```

- [ ] **Step 4: Trim USE** — create `configs/portage/package.use/nftables`:

```
# Keep nftables lean for the static i486-musl image: no JSON output, no
# python bindings, no iptables-compat. readline for the interactive CLI.
net-firewall/nftables -json -python -xtables readline
```

- [ ] **Step 5: Run test** → `ALL PASS`.
> The static-musl cross-build of nftables + libmnl/libnftnl/gmp is CI-authoritative. If a dep needs a keyword or USE tweak to build, that surfaces as a red `build` job — fix in `package.accept_keywords`/`package.use` like any cross-compile wall.

- [ ] **Step 6: Commit**

```bash
git add configs/portage/world configs/portage/package.use/nftables scripts/tests/verify-nftables-pkg.sh
git commit -m "feat(net): add net-firewall/nftables (lean USE) to the image"
```

---

## Task 5: Two-node NAT boot-test (`nat` mode)

**Files:**
- Modify: `scripts/boot-test.py` (new `nat` mode: two builders, a runner spawning a second child, assertions, dispatch entries)
- Modify: `.github/workflows/boot-test.yml` (new `nat-router` job with a host http.server)

**Interfaces:**
- Consumes: `monolith-router` (Tasks 1–2), netfilter `=m` (Task 3), `nft` (Task 4). QEMU model `e1000` (coldplugs).
- Produces: `--mode nat` proving client-through-router-to-host-service.

- [ ] **Step 1: Add the two command builders** near the other `build_*_cmd` functions in `scripts/boot-test.py`. Uses a fixed socket port to link the two guests:

```python
NAT_SOCKET_PORT = 12420  # private LAN link between the router and client guests

def build_nat_router_cmd(args):
    # BIOS/pc guest with TWO NICs: WAN via user-net (SLIRP gateway 10.0.2.2 is
    # the CI host), LAN via a socket segment the client connects to. -nic none
    # suppresses QEMU's default NIC so exactly these two exist (eth0=WAN, eth1=LAN).
    qemu = require_binary(args.qemu_i386)
    return [
        qemu, "-cdrom", args.iso, "-m", str(args.ram_mb), "-cpu", "486",
        "-boot", "d", "-nographic", "-serial", "mon:stdio", "-no-reboot",
        "-nic", "none",
        "-netdev", "user,id=wan", "-device", "e1000,netdev=wan",
        "-netdev", f"socket,id=lan,listen=:{NAT_SOCKET_PORT}", "-device", "e1000,netdev=lan",
    ]

def build_nat_client_cmd(args):
    # Single NIC on the router's LAN socket segment. No WAN, no default NIC.
    qemu = require_binary(args.qemu_i386)
    return [
        qemu, "-cdrom", args.iso, "-m", str(args.ram_mb), "-cpu", "486",
        "-boot", "d", "-nographic", "-serial", "mon:stdio", "-no-reboot",
        "-nic", "none",
        "-netdev", f"socket,id=lan,connect=127.0.0.1:{NAT_SOCKET_PORT}", "-device", "e1000,netdev=lan",
    ]
```

- [ ] **Step 2: Add the assertions + the runner.** `run_nat` gets the router as the main child and spawns the client itself:

```python
def _boot_isolinux_to_shell(child, args):
    select_isolinux_label(child, "serial")
    for ms, desc in [
        (MILESTONE_INIT_START, "initramfs /init started"),
        (MILESTONE_OVERLAY_READY, "squashfs+overlay mounted"),
        (MILESTONE_EXEC_INIT, "pivot_root complete, executing /sbin/init"),
        (MILESTONE_RCS_START, "sysvinit rcS started"),
        (MILESTONE_RCS_COMPLETE, "sysvinit rcS completed"),
    ]:
        expect_milestone(child, ms, args.boot_timeout, desc)
    wait_for_shell(child)
    # Serial warmup: the FIRST command after the shell appears can lose its
    # output to a serial-read race (observed intermittently on the storage
    # jobs — the boot succeeds but the first assertion's output is dropped).
    # A throwaway command absorbs that race so the first real assertion below
    # is reliable. Cheap; runs once per guest.
    run_check(child, "serial warmup", "true", exit_code_only())

def run_nat(child, args):
    # child == router (spawned by main via build_nat_router_cmd).
    results = []
    _boot_isolinux_to_shell(child, args)
    # Router: bring NAT up (eth0=WAN/user, eth1=LAN/socket), assert it took.
    results.append(("router: monolith-router up",
                    *run_check(child, "monolith-router eth0 eth1", "monolith-router eth0 eth1",
                               contains("NAT up"), timeout=60)))
    results.append(("router: nft masquerade present",
                    *run_check(child, "nft ruleset", "nft list ruleset",
                               contains("masquerade"))))
    results.append(("router: ip_forward=1",
                    *run_check(child, "ip_forward", "cat /proc/sys/net/ipv4/ip_forward",
                               regex_matches(r"^1", re.MULTILINE))))

    client = None
    try:
        client = pexpect.spawn(build_nat_client_cmd(args)[0], build_nat_client_cmd(args)[1:],
                               timeout=args.boot_timeout, encoding="utf-8", codec_errors="replace")
        if args.log_file:
            client.logfile = open(args.log_file + ".client", "w", encoding="utf-8", errors="replace")
        _boot_isolinux_to_shell(client, args)
        # Client: static LAN config, default route via the router.
        for cmd in ["ip addr add 192.168.99.2/24 dev eth0",
                    "ip link set eth0 up",
                    "ip route add default via 192.168.99.1"]:
            run_check(client, cmd, cmd, exit_code_only())
        # Positive: reach the host http.server THROUGH the router's masquerade.
        results.append(("client: curl host service through NAT",
                        *run_check(client, "curl via NAT", "curl -s -m 20 http://10.0.2.2:8000/probe.txt",
                                   contains("NAT_OK_marker"), timeout=40)))
        # Negative control: tear NAT down on the router, the client can no longer reach it.
        run_check(child, "monolith-router down", "monolith-router down", contains("NAT down"))
        neg_ok, neg_detail = run_check(client, "curl fails after NAT down",
                                       "curl -s -m 8 http://10.0.2.2:8000/probe.txt; echo RC=$?",
                                       contains("RC=28"), timeout=20)  # curl 28 = timeout
        results.append(("client: no route after NAT down (negative control)", neg_ok, neg_detail))
    finally:
        if client is not None:
            try: client.close(force=True)
            except Exception: pass

    ok = report_results(results)
    poweroff_and_wait(child)
    return ok
```

- [ ] **Step 3: Wire dispatch + RAM.** Add to `MODE_BUILDERS`: `"nat": build_nat_router_cmd`; `MODE_RUNNERS`: `"nat": run_nat`; `MODE_DEFAULT_RAM`: `"nat": 256`. (No new arg needed.)

- [ ] **Step 4: Verify it compiles**

Run: `python3 -m py_compile scripts/boot-test.py && echo OK`
Run: `python3 scripts/boot-test.py --help 2>&1 | grep -o 'nat'` (confirm `nat` in `--mode` choices).

- [ ] **Step 5: Add the `nat-router` CI job** to `.github/workflows/boot-test.yml` (mirror the `toram-eject` job's ISO-restore/secret steps; the http.server + boot-test step is the new part):

```yaml
  nat-router:
    needs: expected-kernel
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - name: Install QEMU
        run: sudo apt-get update && sudo apt-get install -y qemu-system-x86
      - name: Install pexpect
        run: pip install pexpect
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_ACCESS_KEY_SECRET }}
          aws-region: ${{ secrets.AWS_REGION }}
      - name: Restore ISO from S3
        run: |
          mkdir -p output
          aws s3 cp "s3://${{ secrets.S3_BUCKET }}/themonolith-${{ inputs.build-version }}.iso" \
            "output/themonolith-${{ inputs.build-version }}.iso"
      - name: Start host http.server (the client reaches this through NAT)
        run: |
          mkdir -p /tmp/natsrv && echo NAT_OK_marker > /tmp/natsrv/probe.txt
          ( cd /tmp/natsrv && python3 -m http.server 8000 --bind 0.0.0.0 ) &
          echo "HTTP_PID=$!" >> "$GITHUB_ENV"
          sleep 2
      - name: Boot test — two-node NAT (router + client)
        run: |
          python3 scripts/boot-test.py \
            --iso "output/themonolith-${{ inputs.build-version }}.iso" \
            --mode nat \
            --kernel-version "${{ needs.expected-kernel.outputs.version }}" \
            --log-file "output/boot-test-nat.log"
      - name: Stop host http.server
        if: always()
        run: kill "${HTTP_PID}" 2>/dev/null || true
      - name: Upload serial console logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: boot-test-nat-${{ github.run_id }}
          path: output/boot-test-nat.log*
          if-no-files-found: warn
```
> Match the exact secret/credentials convention of the existing `toram-eject` job if it differs; don't introduce a second pattern.

- [ ] **Step 6: Commit**

```bash
git add scripts/boot-test.py .github/workflows/boot-test.yml
git commit -m "test(net): two-node NAT boot test (router+client through masquerade)"
```

---

## Self-Review

- **Spec coverage:** kernel netfilter `=m` + gates + revbump → Task 3; nftables userland + USE → Task 4; `monolith-router` (up/down/status, explicit + auto ifaces, optional `<lan-cidr>` positional + validation) → Task 1; install + allowlist → Task 2; two-node NAT test (router+client, socket segment, host http.server via 10.0.2.2, positive + negative control) → Task 5. All spec sections map.
- **Placeholder scan:** none — every step carries runnable code.
- **Type/name consistency:** `monolith-router` subcommands (`up`/`down`/`status`) + `<lan-cidr>` positional match across Tasks 1/2/5; the NAT test drives `monolith-router eth0 eth1` and `... down` exactly as implemented; `NFT_TABLE`/table name `monolith_router` consistent in script + `status` + test asserts; the `.ko` module names in Task 3 Step 6 (`nf_conntrack`…`nf_defrag_ipv4`) match the `=m` symbols; `NAT_SOCKET_PORT` shared by both builders.
- **Known soft spots (CI-authoritative):** nftables + libnftnl/libmnl static-musl cross-build; a 6.12-retired netfilter symbol; the two-guest QEMU socket orchestration + SLIRP host-reach at `10.0.2.2` working first-try (designed defensively — router-listens-before-client, negative control, both serial logs captured).
