#!/usr/bin/env python3
"""
boot-test.py — Automated QEMU boot verification for The Monolith live ISO.

This is the thing `make test` never was: proof, captured in a CI log, that the
ISO actually boots to a usable shell — not just that xorriso didn't crash.

Modes
-----
  bios    Boot via ISOLINUX (qemu-system-i386, BIOS/SeaBIOS), serial console.
  uefi    Boot via GRUB (qemu-system-x86_64 + OVMF), serial console.
  toram   Boot via ISOLINUX with the `toram` kernel parameter, verify the
          squashfs was copied into RAM, then eject the CD-ROM via the QEMU
          monitor and confirm the system keeps running.

Phase-2 Tier-1 module-regime variants — each boots the isohybrid ISO (it is
a valid raw disk image, not just a CD image) from a DIFFERENT emulated
storage controller via GRUB/UEFI, and asserts the matching kernel module
was coldplug-loaded from the initrd before the squashfs was mounted:
  ahci    SATA/AHCI (q35 + ich9-ahci), asserts `ahci` is loaded.
  nvme    NVMe namespace, asserts `nvme` is loaded.
  usb     USB mass storage on an xHCI controller, asserts `xhci_hcd` and
          `usb_storage` are both loaded (the modular HCD chain + disk driver).
  virtio  virtio-blk-pci, asserts `virtio_blk` is loaded.
  nicless Negative control: BIOS/ISOLINUX boot with `-nic none` (no NIC
          hardware at all), asserts `e1000` is NOT loaded — proving
          coldplug loads modules for hardware that's present, not
          unconditionally.

Ground truth this script is built against (re-check these if the boot
sequence ever changes — this script has no other source of truth):
  rootfs/init                 — initramfs init: mount sequence, log lines
  scripts/build-rootfs.sh     — /etc/inittab, /etc/init.d/rcS, /etc/passwd etc.
  scripts/build-iso.sh        — ISOLINUX + GRUB menu definitions

Two important, non-obvious facts about this ISO that shape this script:

1. There is no login prompt. /etc/inittab runs
     agetty -n -l /usr/sbin/monolith-console ...
   on every console (tty1, tty2, ttyS0) — `-n` skips the username/password
   prompt entirely. "Passwordless root" here means "no authentication step
   happens at all", not "empty password is accepted at a login: prompt". This
   script never sends a username. monolith-console is a lazy shell: a tiny dash
   that blocks on `read` and only becomes bash once the console is touched (so
   idle consoles keep no bash resident — RAM matters on a 486). wait_for_shell()
   below sends the waking newline before it expects a live shell.

2. BusyBox is initramfs-only. The main squashfs rootfs installs iproute2 +
   dhcpcd (see configs/portage/world, section "replaces BusyBox
   udhcpc/ifconfig") and does NOT include app-shells/busybox. `udhcpc` is
   therefore normally absent from the booted shell; DHCP already happened
   automatically at boot via /etc/init.d/S40network (`dhcpcd -b eth0`). This
   script probes for udhcpc and, if present, uses it; otherwise it falls back
   to asserting the DHCP lease dhcpcd already obtained at boot. Both paths
   prove the same thing: a live DHCP client got an address over QEMU
   user-mode networking.

Neither ISOLINUX nor GRUB defaults to a serial-visible boot entry:
  - isolinux.cfg: `DEFAULT fb800` (framebuffer, invisible over -nographic).
    We explicitly type the `serial` label (optionally with extra kernel
    params, e.g. `serial toram`) at the `boot:` prompt within the 5s timeout.
  - grub.cfg: `set default=0` (the plain entry, gfxterm-only, also
    invisible over -nographic/serial). We send two Down-arrows + Enter to
    select the "(serial)" entry (index 2) instead. GRUB has no `toram`-over-serial
    entry at all (its `(toram)` menuentry doesn't set console=ttyS0), so
    `toram` is only exercised via the BIOS/ISOLINUX path in this script,
    where the boot prompt lets us combine `serial toram` in one line.

This script cannot be exercised on the authoring machine (no qemu-system-*
here). It is written to be correct against the code above and is meant to be
proven out by CI logs, not by a local run.
"""

import argparse
import json
import os
import re
import shutil
import socket
import sys
import time
import uuid

try:
    import pexpect
except ImportError:
    sys.stderr.write(
        "boot-test.py requires pexpect (pip install pexpect). "
        "In CI this is installed as a workflow step.\n"
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Ground-truth anchors
#
# These strings are copied verbatim from rootfs/init and the /etc/inittab +
# /etc/init.d/rcS heredocs in scripts/build-rootfs.sh. If the boot sequence
# ever changes, update these to match — do not paraphrase, or the milestone
# matching silently stops proving anything.
# ---------------------------------------------------------------------------

MILESTONE_INIT_START = "[init] Starting init..."
MILESTONE_OVERLAY_READY = "[init] Overlay root ready"
MILESTONE_TORAM_EJECTABLE = "[init] Boot media can now be ejected"
MILESTONE_EXEC_INIT = "[init] Executing /sbin/init..."
MILESTONE_RCS_START = "Starting system initialization..."
MILESTONE_RCS_COMPLETE = "System initialization complete."

ISOLINUX_PROMPT = "boot:"

# GRUB menu order in scripts/build-iso.sh's GRUB_CFG heredoc (0-indexed):
#   0 plain(default)  1 framebuffer  2 serial  3 debug  4 rescue  5 toram
# We only ever need entry 2 ("(serial)"); toram is tested via ISOLINUX instead
# (see module docstring) because the GRUB toram entry has no console=ttyS0.
# default is entry 0, so reaching "(serial)" (entry 2) is two Down-arrows.
GRUB_SERIAL_ENTRY_DOWN_PRESSES = 2

DEFAULT_BOOT_TIMEOUT = 300  # generous: emulated i486 path is slow

OVMF_CODE_CANDIDATES = [
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/usr/share/edk2-ovmf/OVMF_CODE.fd",
]


class BootTestError(Exception):
    """Raised for any condition that should fail the CI job."""


def log(msg):
    print(f"[boot-test] {msg}", flush=True)


def find_ovmf_code(explicit):
    if explicit:
        return explicit
    for candidate in OVMF_CODE_CANDIDATES:
        if os.path.isfile(candidate):
            return candidate
    return None


def require_binary(name):
    path = shutil.which(name)
    if not path:
        raise BootTestError(
            f"required binary '{name}' not found on PATH — install it before running boot-test.py"
        )
    return path


# ---------------------------------------------------------------------------
# QEMU command construction
# ---------------------------------------------------------------------------

def build_bios_cmd(args):
    qemu = require_binary(args.qemu_i386)
    cmd = [
        qemu,
        "-cdrom", args.iso,
        "-m", str(args.ram_mb),
        "-cpu", "486",
        "-boot", "d",
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_uefi_cmd(args):
    qemu = require_binary(args.qemu_x86_64)
    ovmf = find_ovmf_code(args.ovmf_code)
    if not ovmf:
        raise BootTestError(
            "OVMF firmware not found. Install ovmf/edk2-ovmf, or pass --ovmf-code /path/to/OVMF_CODE.fd. "
            f"Checked: {', '.join(OVMF_CODE_CANDIDATES)}"
        )
    log(f"Using OVMF firmware: {ovmf}")
    cmd = [
        qemu,
        "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
        "-cdrom", args.iso,
        "-m", str(args.ram_mb),
        "-boot", "d",
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def _require_ovmf(args):
    ovmf = find_ovmf_code(args.ovmf_code)
    if not ovmf:
        raise BootTestError(
            "OVMF firmware not found. Install ovmf/edk2-ovmf, or pass --ovmf-code /path/to/OVMF_CODE.fd. "
            f"Checked: {', '.join(OVMF_CODE_CANDIDATES)}"
        )
    log(f"Using OVMF firmware: {ovmf}")
    return ovmf


def build_ahci_cmd(args):
    """
    Boot the isohybrid ISO from an emulated AHCI/SATA controller instead of
    the default -cdrom device: q35 + an explicit ich9-ahci controller, with
    the ISO attached as an AHCI CD-ROM behind it. Proves CONFIG_SATA_AHCI=m
    (ahci.ko) is coldplug-loaded from the initrd before the squashfs is
    mounted, for hardware where drive discovery genuinely goes through the
    AHCI driver rather than a legacy IDE emulation shortcut.
    """
    qemu = require_binary(args.qemu_x86_64)
    ovmf = _require_ovmf(args)
    cmd = [
        qemu,
        "-machine", "q35",
        "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
        "-device", "ich9-ahci,id=ahci",
        "-drive", f"id=cd,if=none,media=cdrom,file={args.iso}",
        "-device", "ide-cd,bus=ahci.0,drive=cd",
        "-boot", "d",
        "-m", str(args.ram_mb),
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_nvme_cmd(args):
    """
    Boot the isohybrid ISO as the backing file of an emulated NVMe namespace
    (not a CD-ROM at all — the ISO's own MBR/GPT hybrid layout makes it a
    valid raw disk image). Proves CONFIG_BLK_DEV_NVME=m (nvme.ko) is
    coldplug-loaded from the initrd in time to find and mount the root
    filesystem on NVMe-attached media.
    """
    qemu = require_binary(args.qemu_x86_64)
    ovmf = _require_ovmf(args)
    cmd = [
        qemu,
        "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
        "-drive", f"id=nvm,if=none,format=raw,file={args.iso}",
        "-device", "nvme,serial=cafe1234,drive=nvm",
        "-boot", "c",
        "-m", str(args.ram_mb),
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_usb_cmd(args):
    """
    Boot the isohybrid ISO as a USB mass-storage device behind an emulated
    xHCI host controller. Proves TWO Tier-1 modules are coldplug-loaded in
    the right order: xhci_hcd (the USB host controller itself) and
    usb_storage (the USB Mass Storage Class driver on top of it) — either
    one missing means no root filesystem to mount.
    """
    qemu = require_binary(args.qemu_x86_64)
    ovmf = _require_ovmf(args)
    cmd = [
        qemu,
        "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
        "-device", "qemu-xhci,id=xhci",
        "-drive", f"id=usbdisk,if=none,format=raw,file={args.iso}",
        "-device", "usb-storage,bus=xhci.0,drive=usbdisk",
        "-boot", "c",
        "-m", str(args.ram_mb),
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_virtio_cmd(args):
    """
    Boot the isohybrid ISO as the backing image of a virtio-blk-pci device —
    the paravirtualized block device most real-world cloud/VM deployments of
    this ISO would actually use. Proves CONFIG_VIRTIO_BLK=m (virtio_blk.ko)
    is coldplug-loaded from the initrd.
    """
    qemu = require_binary(args.qemu_x86_64)
    ovmf = _require_ovmf(args)
    cmd = [
        qemu,
        "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
        "-drive", f"id=vblk,if=none,format=raw,file={args.iso}",
        "-device", "virtio-blk-pci,drive=vblk",
        "-boot", "c",
        "-m", str(args.ram_mb),
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_nicless_cmd(args):
    """
    The negative control for the Tier-1 module regime: identical to
    build_bios_cmd's device set, except `-nic none` removes the emulated
    NIC entirely (QEMU's default `pc` machine would otherwise add an
    e1000 automatically). With no NIC hardware present at all, the
    initrd's modalias coldplug has nothing PCI-network-shaped to match —
    so e1000.ko must NOT appear in `lsmod`. This is the other half of the
    "refund is real" claim: modules load because hardware matched, not
    unconditionally.
    """
    qemu = require_binary(args.qemu_i386)
    cmd = [
        qemu,
        "-cdrom", args.iso,
        "-m", str(args.ram_mb),
        "-cpu", "486",
        "-boot", "d",
        "-nic", "none",
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]
    return cmd


def build_gui_cmd(args):
    """
    SP-GUI G1 Step 3: boot via BIOS/SeaBIOS (same i386/486 pc machine as
    build_bios_cmd) so SeaBIOS's VBE BIOS is present and the kernel's
    CONFIG_FB_VESA=y vesafb driver claims it, producing /dev/fb0 — the
    UEFI/GRUB path uses efifb instead, which this kernel does not carry, so
    this mode is BIOS-only.

    The serial boot path is BYTE-IDENTICAL to build_bios_cmd — `-nographic
    -serial mon:stdio` — for a reason: the ISO's isolinux.cfg has NO `SERIAL`
    directive, so ISOLINUX's `boot:` prompt only reaches the serial console via
    SeaBIOS's `-nographic` VGA-text-to-serial mirroring. Dropping `-nographic`
    (e.g. for `-display none`) hides that prompt, ISOLINUX auto-boots its
    default framebuffer label (no console=ttyS0), and pexpect sees nothing. So
    we keep the proven `-nographic` path and take the screendump over a SEPARATE
    QMP monitor socket (`-qmp unix:...`), which coexists fine with the HMP
    monitor that `-nographic` muxes onto serial stdio — QMP is an independent
    monitor channel, so it never touches the serial stream pexpect drives.
    `-vga std` provides the VBE device; `-nographic` opens no host window but the
    device's VRAM still holds the pixels Xfbdev paints, which QMP `screendump`
    dumps to a host-side PPM. (efifb/UEFI is avoided: this kernel has FB_VESA=y,
    not efifb, so /dev/fb0 needs the BIOS+vesafb path.)
    """
    qemu = require_binary(args.qemu_i386)
    sock = args.gui_screendump + ".qmp.sock"
    args.gui_monitor_sock = sock
    sock_dir = os.path.dirname(sock) or "."
    os.makedirs(sock_dir, exist_ok=True)
    # A stale socket file left behind by a killed prior run makes QEMU's
    # `server,nowait` bind fail with "Address already in use".
    if os.path.exists(sock):
        os.remove(sock)
    cmd = [
        qemu,
        "-cdrom", args.iso,
        "-m", str(args.ram_mb),
        "-cpu", "486",
        "-boot", "d",
        "-vga", "std",
        "-nographic",
        "-serial", "mon:stdio",
        "-qmp", f"unix:{sock},server,nowait",
        "-no-reboot",
    ]
    return cmd


def build_nic_cmd(args):
    # BIOS/ISOLINUX on the i440fx `pc` machine (has an ISA bus, needed for
    # ne2k_isa). Legacy -net form replaces QEMU's default NIC with exactly one
    # card of the requested model; works for pcnet/rtl8139/tulip/ne2k_pci/ne2k_isa.
    if not args.nic_model:
        raise BootTestError("--mode nic requires --nic-model")
    cmd = build_bios_cmd(args)
    cmd += ["-net", f"nic,model={args.nic_model}", "-net", "user"]
    return cmd


# Private LAN link between the router and client guests, carried as a
# connectionless UDP datagram pair on loopback. TCP `listen`/`connect` socket
# netdevs raced connection establishment between the two independently-spawned
# QEMU processes and left the link dead (client ARP 100% loss, `ip neigh`
# FAILED) on most runs. UDP has no handshake to lose: each guest binds its own
# local port and sends frames to the other's — order-independent, and by the
# time the test drives traffic both ends are bound, so datagrams flow.
NAT_ROUTER_PORT = 12420  # router binds this; client sends its frames here
NAT_CLIENT_PORT = 12421  # client binds this; router sends its frames here


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
        # LAN link: UDP datagram socket to the client (see the port constants).
        "-netdev",
        f"socket,id=lan,udp=127.0.0.1:{NAT_CLIENT_PORT},localaddr=127.0.0.1:{NAT_ROUTER_PORT}",
        "-device", "e1000,netdev=lan",
    ]


def build_nat_client_cmd(args):
    # Single NIC on the router's LAN socket segment. No WAN, no default NIC.
    qemu = require_binary(args.qemu_i386)
    return [
        qemu, "-cdrom", args.iso, "-m", str(args.ram_mb), "-cpu", "486",
        "-boot", "d", "-nographic", "-serial", "mon:stdio", "-no-reboot",
        "-nic", "none",
        # LAN link: UDP datagram socket to the router (mirror of the router's).
        "-netdev",
        f"socket,id=lan,udp=127.0.0.1:{NAT_ROUTER_PORT},localaddr=127.0.0.1:{NAT_CLIENT_PORT}",
        "-device", "e1000,netdev=lan",
    ]


# ---------------------------------------------------------------------------
# Boot-loader navigation
# ---------------------------------------------------------------------------

def select_isolinux_label(child, label_line, prompt_timeout=90):
    """
    Wait for ISOLINUX's `boot:` prompt (visible over serial thanks to
    SeaBIOS's -nographic VGA-text-to-serial mirroring, which covers the
    firmware + ISOLINUX real-mode text stage) and type the label.

    `label_line` may be "serial" or "serial toram" — SYSLINUX appends any
    text after the label name to that label's own APPEND line, which is how
    we exercise `toram` even though isolinux.cfg has no `toram` LABEL.
    """
    try:
        child.expect_exact(ISOLINUX_PROMPT, timeout=prompt_timeout)
        log(f"ISOLINUX prompt seen, sending label: {label_line!r}")
    except pexpect.TIMEOUT:
        log(
            f"WARNING: did not see ISOLINUX '{ISOLINUX_PROMPT}' prompt within "
            f"{prompt_timeout}s — sending label blindly as a fallback"
        )
    child.sendline(label_line)


def select_grub_serial_entry(child):
    """
    grub.cfg now mirrors the menu to serial (`terminal_output gfxterm serial`
    + `terminal_input console serial`), so instead of firing keystrokes blind
    we WAIT for the menu to render, then navigate interactively — which is
    reliable, unlike queuing bytes before GRUB opens the console.

    Menu order (grub.cfg, 0-indexed): 0 plain (default, `set default=0`),
    1 framebuffer, 2 serial, 3 debug, 4 rescue, 5 toram, 6 persistent.
    From the default we step down GRUB_SERIAL_ENTRY_DOWN_PRESSES times to the
    '(serial)' entry (which sets console=ttyS0) and boot it. The first key
    also cancels GRUB's `set timeout=5` countdown.
    """
    down = "\x1b[B"
    enter = "\r"
    # Wait for the menu to be on-screen over serial before sending anything.
    try:
        child.expect_exact("(serial)", timeout=180)
        log("  -> GRUB menu visible on serial; selecting the (serial) entry")
    except (pexpect.TIMEOUT, pexpect.EOF):
        log("  !! GRUB menu not observed on serial within 180s; navigating blind as fallback")
    time.sleep(0.5)
    child.send(down * GRUB_SERIAL_ENTRY_DOWN_PRESSES)
    time.sleep(0.5)
    child.send(enter)


# ---------------------------------------------------------------------------
# Milestone / shell interaction helpers
# ---------------------------------------------------------------------------

def expect_milestone(child, text, timeout, description=None):
    desc = description or text
    log(f"Waiting for milestone: {desc!r} (timeout {timeout}s)")
    try:
        child.expect_exact(text, timeout=timeout)
    except pexpect.TIMEOUT:
        raise BootTestError(
            f"Timed out waiting for milestone {desc!r}. This is exactly the kind of "
            f"failure a broken init script should produce — check the serial log."
        )
    except pexpect.EOF:
        raise BootTestError(
            f"QEMU exited before milestone {desc!r} was reached (unexpected EOF)."
        )
    log(f"  -> milestone reached: {desc!r}")


def wait_for_shell(child, timeout=60):
    """
    Confirm an interactive shell is actually reading our input.

    We do NOT try to match a PS1 prompt: PS1 content depends on Gentoo's
    /etc/bash/bashrc.d chain (colors, hostname, the dark-grey square prepended
    by 99-monolith-square.bash) and isn't worth hardcoding. Instead we
    repeatedly send a unique echo and wait for it to come back — this also
    absorbs the race where agetty flushes pending tty input right before it
    hands off to bash, which would otherwise silently eat an early command.

    The console runs the lazy /usr/sbin/monolith-console stub: a tiny dash that
    blocks on `read` and only execs bash once a line arrives. The bare newline
    below is that waking keypress; the stub consumes it (and, at worst, one echo
    line) and becomes bash, after which the retry loop's echo comes back.
    """
    marker = f"MONOLITH_SHELL_READY_{uuid.uuid4().hex[:8]}"
    # Wake the lazy console shell: this newline satisfies monolith-console's
    # `read`, so it exec's bash before we start looking for our echo.
    child.sendline("")
    deadline = time.time() + timeout
    while time.time() < deadline:
        child.sendline(f"echo {marker}")
        try:
            child.expect_exact(marker, timeout=3)
            log("Shell is interactive and echoing input.")
            return
        except pexpect.TIMEOUT:
            continue
        except pexpect.EOF:
            raise BootTestError("QEMU exited while waiting for an interactive shell.")
    raise BootTestError(f"Shell never became interactive within {timeout}s.")


def run_check(child, name, cmd, validator, timeout=30):
    """
    Run `cmd` in the guest shell, wrapped with a unique sentinel that carries
    the exit code, and hand (exit_code, output_text) to `validator`.

    Returns (ok: bool, detail: str). Never raises — callers collect results
    from every check so one failure doesn't hide the rest.
    """
    marker = f"MONOLITH_CHECK_{uuid.uuid4().hex[:8]}"
    child.sendline(f"{cmd}; echo {marker}:$?")
    try:
        child.expect(re.escape(marker) + r":(\d+)", timeout=timeout)
    except pexpect.TIMEOUT:
        return False, f"timed out after {timeout}s waiting for command to complete"
    except pexpect.EOF:
        return False, "QEMU exited unexpectedly while running this check"

    exit_code = int(child.match.group(1))
    output = child.before or ""
    try:
        ok, detail = validator(exit_code, output)
    except Exception as exc:  # validator bug shouldn't crash the whole suite
        return False, f"validator raised {exc!r}"
    return ok, detail


def contains(needle, ci=False):
    def _v(exit_code, output):
        hay = output.lower() if ci else output
        n = needle.lower() if ci else needle
        if exit_code != 0:
            return False, f"exit code {exit_code}, output: {output.strip()[-500:]}"
        if n not in hay:
            return False, f"expected {needle!r} in output, got: {output.strip()[-500:]}"
        return True, "ok"
    return _v


def regex_matches(pattern, flags=0):
    compiled = re.compile(pattern, flags)
    def _v(exit_code, output):
        if exit_code != 0:
            return False, f"exit code {exit_code}, output: {output.strip()[-500:]}"
        if not compiled.search(output):
            return False, f"expected /{pattern}/ to match output, got: {output.strip()[-500:]}"
        return True, "ok"
    return _v


def regex_absent(pattern, flags=0):
    """
    Inverse of regex_matches: passes only when `pattern` does NOT appear in
    the output. Used for negative proofs (e.g. "this driver did not load")
    where a positive regex_matches check can't express the assertion.
    """
    compiled = re.compile(pattern, flags)
    def _v(exit_code, output):
        if exit_code != 0:
            return False, f"exit code {exit_code}, output: {output.strip()[-500:]}"
        match = compiled.search(output)
        if match:
            return False, f"expected /{pattern}/ to NOT match output, but found: {match.group(0)!r}"
        return True, "ok"
    return _v


def exit_code_only():
    def _v(exit_code, output):
        if exit_code != 0:
            return False, f"exit code {exit_code}, output: {output.strip()[-500:]}"
        return True, "ok"
    return _v


# ---------------------------------------------------------------------------
# Smoke suite
# ---------------------------------------------------------------------------

def smoke_kernel_version(child, expected_kernel):
    return run_check(
        child, "uname -r matches expected kernel", "uname -r",
        contains(expected_kernel),
    )


def smoke_nic_is_module(child):
    """
    The kernel-module regime (Tier 1) makes the NIC driver loadable rather than
    built-in: kernel.config carries CONFIG_E1000=m, and QEMU's default `pc` NIC
    is an e1000. So a passing `lsmod | grep e1000` proves the whole refund chain
    end to end — the driver was compiled as a .ko, rode into the squashfs via
    modules_install, and rcS's modalias coldplug matched the PCI id and loaded
    it. If this passes but eth0 is down, networking broke; if this fails, the
    module pipeline itself is broken. Keeping the two checks distinct localizes
    the fault.
    """
    return run_check(
        child, "e1000 NIC driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^e1000\b", re.MULTILINE),
    )


def smoke_eth0_link(child):
    return run_check(
        child, "eth0 link is up", "ip link show eth0",
        regex_matches(r"eth0:.*\bUP\b"),
    )


def smoke_dhcp_lease(child, results):
    """
    Prefer udhcpc if it happens to be present (it normally isn't — see module
    docstring); otherwise assert the dhcpcd lease obtained automatically at
    boot by /etc/init.d/S40network. Either way this proves a live DHCP round
    trip happened over QEMU user-mode networking.
    """
    has_udhcpc, _ = run_check(
        child, "udhcpc present?", "command -v udhcpc >/dev/null 2>&1",
        exit_code_only(),
    )
    if has_udhcpc:
        ok, detail = run_check(
            child, "udhcpc -i eth0 obtains a lease",
            "udhcpc -i eth0 -n -q -t 5 -T 3",
            exit_code_only(), timeout=30,
        )
        results.append(("udhcpc -i eth0 obtains a lease", ok, detail))
    else:
        log(
            "udhcpc not present in the booted rootfs (expected — see module docstring); "
            "verifying the boot-time dhcpcd lease instead"
        )
        ok, detail = run_check(
            child, "eth0 has a DHCP-assigned IPv4 address (via boot-time dhcpcd)",
            "ip -4 addr show eth0",
            regex_matches(r"inet\s+\d+\.\d+\.\d+\.\d+"),
        )
        results.append(("eth0 has a DHCP-assigned IPv4 address (dhcpcd at boot)", ok, detail))


def smoke_curl(child):
    return run_check(
        child, "curl --version executes", "curl --version",
        contains("curl"),
    )


def smoke_sqlite_cli(child):
    """sqlite3 CLI runs and computes — proves the static amalgamation build."""
    return run_check(
        child, "sqlite3 CLI evaluates in-memory SQL", "sqlite3 :memory: 'select 41+1;'",
        contains("42"))


def smoke_perl_version(child):
    """perl runs and reports its version — proves the perl-cross build pipeline."""
    return run_check(child, "perl runs and reports its version", "perl -e 'print $];'",
                     contains("5.0"))  # $] is e.g. 5.042000; tighten to the pinned major once known


def smoke_perl_basic(child):
    """perl strict+warnings program runs — proves a sane, usable interpreter."""
    return run_check(child, "perl strict+warnings program runs",
                     "perl -e 'use strict; use warnings; print qq(ok\\n);'", contains("ok"))


def smoke_perl_utf8(child):
    """unicore tables survived pruning: uc() of a non-ASCII char needs Unicode data."""
    return run_check(child, "perl unicode/utf8 tables present",
                     "perl -Mutf8 -CS -e 'print uc(qq(\\x{e9}));'", exit_code_only())


def smoke_perl_cgi(child):
    """
    CGI.pm's param() parses a synthetic query string — proves the pure-perl
    CGI.pm 4.10 rider (staged into cpan/CGI, see the monolith-perl ebuild)
    actually landed in the installed /usr/lib/perl5 tree and is importable.
    """
    return run_check(
        child, "CGI.pm param() works",
        "perl -MCGI -e 'print CGI->new(q(x=42))->param(q(x));'",
        contains("42"))


def smoke_guestbook(child, results):
    """
    The LAMP invariant, via CLI (DBI/DBD::SQLite deferred — see
    configs/portage/world's monolith-perl comment): a guestbook CGI (perl +
    CGI.pm) shells out to the `sqlite3` CLI to INSERT a row and read it back.

    Two checks, not one: (1) invoke the CGI directly (the httpd-served +
    curl-POST form is the STRETCH goal per the plan; this direct invocation
    is the reliable form actually wired here) with a synthetic QUERY_STRING
    and assert its own response contains the round-tripped row: (2)
    independently re-query the SAME on-disc sqlite3 db file via the CLI,
    proving the row was genuinely persisted to disk by the CGI script and
    not merely echoed back from its own arguments.
    """
    # guestbook.cgi's own sqlite3_query1() uses -separator '|' too (see the
    # fixture), so its printed row is "Ada|Hello from 1996" — same shape as
    # the independent re-query below.
    ok1, detail1 = run_check(
        child, "guestbook.cgi inserts + reads back a row via sqlite3",
        "rm -f /tmp/guestbook.db; "
        "REQUEST_METHOD=GET QUERY_STRING='name=Ada&message=Hello+from+1996' "
        "perl /usr/lib/cgi-bin/guestbook.cgi",
        contains("Ada|Hello from 1996"),
    )
    results.append(("guestbook.cgi inserts + reads back a row via sqlite3", ok1, detail1))

    ok2, detail2 = run_check(
        child, "guestbook row independently verified via sqlite3 CLI",
        # -list is REQUIRED: sqlite 3.53's CLI defaults to "box" mode (a
        # UTF-8 ╭──┬──╮ table) when stdout is a tty — and the boot-test shell
        # IS a tty — so -separator alone (which only applies to list mode) is
        # ignored and the row prints as box art, not "Ada|Hello from 1996".
        # The guestbook.cgi's own query pipes sqlite3 (not a tty) so it gets
        # list mode implicitly; here we force it.
        "sqlite3 -list -separator '|' /tmp/guestbook.db "
        "\"select name, message from guestbook order by id desc limit 1;\"",
        contains("Ada|Hello from 1996"),
    )
    results.append(("guestbook row independently verified via sqlite3 CLI", ok2, detail2))


def smoke_overlay_mount(child):
    return run_check(
        child, "overlay root is mounted", "mount",
        regex_matches(r"\btype overlay\b"),
    )


def smoke_man(child):
    return run_check(
        child, "man ls renders via mandoc", "MANPAGER=cat PAGER=cat man ls 2>&1 | head -5",
        regex_matches(r"\bLS\b|\bls\b"),
        timeout=30,
    )


def smoke_ahci_is_module(child):
    """
    kernel.config carries CONFIG_SATA_AHCI=m, and the ahci mode boots the ISO
    behind an emulated ich9-ahci controller instead of a plain -cdrom. A
    passing `lsmod | grep ahci` proves ahci.ko rode into the initrd,
    modules_install'd, and the initrd's modalias coldplug matched the AHCI
    controller's PCI id and loaded it in time to find the boot media —
    exactly the same "reaches the boot media" mechanism smoke_nic_is_module
    proves for networking, applied to a storage controller instead.
    """
    return run_check(
        child, "ahci SATA driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^ahci\b", re.MULTILINE),
    )


def smoke_nvme_is_module(child):
    """
    kernel.config carries CONFIG_BLK_DEV_NVME=m, and the nvme mode attaches
    the ISO as an NVMe namespace instead of a CD-ROM. A passing
    `lsmod | grep nvme` proves nvme.ko was coldplug-loaded from the initrd
    before pivot_root — if this fails, the boot media itself would never
    have been found on NVMe-attached hardware.
    """
    return run_check(
        child, "nvme driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^nvme\b", re.MULTILINE),
    )


def smoke_xhci_hcd_is_module(child):
    """
    kernel.config carries CONFIG_USB_XHCI_HCD=m (usbcore itself stays built-in).
    The usb mode attaches the ISO behind an emulated xHCI host controller; the
    initrd coldplugs xhci-pci by the controller's PCI modalias, which pulls in
    xhci_hcd. Without it the USB bus never comes up and usb_storage has nothing
    to attach to — so this is the first link of the Tier-1 USB chain.
    """
    return run_check(
        child, "xhci_hcd USB host-controller driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^xhci_hcd\b", re.MULTILINE),
    )


def smoke_usb_storage_is_module(child):
    """
    kernel.config carries CONFIG_USB_STORAGE=m (module name usb-storage, which
    shows as usb_storage in lsmod). Second link of the Tier-1 USB chain: once
    the modular HCD above has enumerated the USB bus, the initrd coldplug loads
    usb-storage.ko onto the appearing disk in time to expose the ISO as a block
    device.
    """
    return run_check(
        child, "usb_storage driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^usb_storage\b", re.MULTILINE),
    )


def smoke_virtio_blk_is_module(child):
    """
    kernel.config carries CONFIG_VIRTIO_BLK=m. The virtio mode attaches the
    ISO via virtio-blk-pci — the paravirtualized disk most real deployments
    of this ISO under a VM would actually use. Proves virtio_blk.ko was
    coldplug-loaded from the initrd before the squashfs mount.
    """
    return run_check(
        child, "virtio_blk driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(r"^virtio_blk\b", re.MULTILINE),
    )


def smoke_nic_not_loaded(child):
    """
    Negative counterpart to smoke_nic_is_module. The nicless mode boots with
    `-nic none` — no emulated NIC of any kind — so the initrd's modalias
    coldplug has no PCI network device to match against. If `lsmod` still
    showed e1000 here, it would mean modules load unconditionally rather
    than by matching present hardware, silently defeating the whole point
    of the Tier-1 module regime (smaller initrd, nothing loaded for
    hardware that isn't there). A clean absence is the other half of the
    "refund is real" proof that smoke_nic_is_module only argues positively.
    """
    return run_check(
        child, "e1000 NIC driver is NOT loaded (no NIC hardware present)", "lsmod",
        regex_absent(r"^e1000\b", re.MULTILINE),
    )


# NIC-model matrix: QEMU emulates much of the zoo. Coldplug models assert the
# driver loads by modalias; the ISA model (ne2k_isa, no modalias) asserts the
# monolith-net probe path instead.
NIC_MODEL_MODULE = {
    "pcnet": r"^pcnet32\b",
    "rtl8139": r"^8139(too|cp)\b",
    "tulip": r"^tulip\b",
    "ne2k_pci": r"^ne2k_pci\b",
}

def smoke_nic_model_is_module(child, model):
    pattern = NIC_MODEL_MODULE[model]
    return run_check(
        child, f"{model} NIC driver is loaded as a module (coldplug)", "lsmod",
        regex_matches(pattern, re.MULTILINE),
    )

def smoke_isa_probe(child, results):
    """
    ne2k_isa has no modalias, so coldplug must NOT have loaded `ne`. Then
    `monolith-net probe` sweeps the common io= addresses (QEMU's ne2k_isa sits
    at the default 0x300), after which `ne` is resident and an interface exists.
    """
    results.append(("ne NOT auto-loaded for ISA card (no modalias)",
                    *run_check(child, "ne not coldplugged", "lsmod",
                               regex_absent(r"^ne\b", re.MULTILINE))))
    results.append(("monolith-net probe finds the ISA NE2000",
                    *run_check(child, "monolith-net probe", "monolith-net probe",
                               contains("found"), timeout=60)))
    results.append(("ne driver resident after probe",
                    *run_check(child, "ne loaded post-probe", "lsmod",
                               regex_matches(r"^ne\b", re.MULTILINE))))


def run_full_smoke_suite(child, expected_kernel):
    results = []
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, expected_kernel)))
    results.append(("e1000 NIC driver loaded as a module (coldplug)", *smoke_nic_is_module(child)))
    results.append(("eth0 link is up", *smoke_eth0_link(child)))
    smoke_dhcp_lease(child, results)
    results.append(("curl --version executes", *smoke_curl(child)))
    results.append(("sqlite3 CLI evaluates in-memory SQL", *smoke_sqlite_cli(child)))
    results.append(("perl runs and reports its version", *smoke_perl_version(child)))
    results.append(("perl strict+warnings program runs", *smoke_perl_basic(child)))
    results.append(("perl unicode/utf8 tables present", *smoke_perl_utf8(child)))
    results.append(("CGI.pm param() works", *smoke_perl_cgi(child)))
    smoke_guestbook(child, results)
    results.append(("overlay root is mounted", *smoke_overlay_mount(child)))
    results.append(("man ls renders (mandoc)", *smoke_man(child)))
    return results


def run_reduced_smoke_suite(child, expected_kernel):
    results = []
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, expected_kernel)))
    results.append(("e1000 NIC driver loaded as a module (coldplug)", *smoke_nic_is_module(child)))
    results.append(("eth0 link is up", *smoke_eth0_link(child)))
    results.append(("overlay root is mounted", *smoke_overlay_mount(child)))
    return results


def run_storage_smoke_suite(child, expected_kernel):
    # Post-boot checks for the Tier-1 storage variants: prove the boot completed
    # onto the right kernel and the overlay root is live. Deliberately NO
    # networking checks — that is covered by the bios/uefi/toram variants, and
    # the ahci variant in particular runs on q35, whose default NIC is e1000e (a
    # driver this kernel doesn't carry), so there is no eth0 to bring up here.
    results = []
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, expected_kernel)))
    results.append(("overlay root is mounted", *smoke_overlay_mount(child)))
    return results


def report_results(results):
    ok = True
    for name, passed, detail in results:
        status = "PASS" if passed else "FAIL"
        log(f"  [{status}] {name} — {detail}")
        if not passed:
            ok = False
    return ok


# ---------------------------------------------------------------------------
# Shutdown / eject
# ---------------------------------------------------------------------------

def poweroff_and_wait(child, timeout=90):
    log("Sending poweroff (exercises /etc/init.d/rcK: killall5, umount -a -r, sync)")
    child.sendline("poweroff")
    try:
        child.expect(pexpect.EOF, timeout=timeout)
    except pexpect.TIMEOUT:
        log("Graceful poweroff did not exit within timeout — sending poweroff -f as a fallback")
        try:
            child.sendline("poweroff -f")
            child.expect(pexpect.EOF, timeout=timeout)
        except pexpect.TIMEOUT:
            raise BootTestError(
                f"QEMU did not exit after poweroff within {2 * timeout}s total "
                "(CONFIG_ACPI=y is set, so ACPI S5 should terminate QEMU — this "
                "likely means the shutdown sequence hung, not that ACPI is unsupported)"
            )
    child.close()
    log(f"QEMU exited (status={child.exitstatus})")


def eject_cd_and_verify(child, cdrom_id, timeout=30):
    """
    Switch from the serial console to the QEMU monitor (Ctrl-A c — the same
    mux Makefile's `make test` documents as "Ctrl+A X to exit", confirming
    `-serial mon:stdio` is meant to expose the monitor this way), eject the
    CD-ROM, switch back, and confirm the guest is still alive.
    """
    log("Switching from serial console to QEMU monitor (Ctrl-A c)")
    child.send("\x01c")
    child.expect_exact("(qemu)", timeout=timeout)

    log(f"Ejecting CD-ROM (device id: {cdrom_id})")
    child.sendline(f"eject -f {cdrom_id}")
    child.expect_exact("(qemu)", timeout=timeout)

    log("Switching back to serial console (Ctrl-A c)")
    child.send("\x01c")
    child.sendline("")  # nudge the shell so we get fresh output to match against

    ok, detail = run_check(
        child, "shell survives CD eject", "uname -r",
        exit_code_only(), timeout=timeout,
    )
    return ok, detail


# ---------------------------------------------------------------------------
# GUI mode helpers (SP-GUI G1 Step 3): drive the QEMU HMP monitor over its
# own unix socket to take a screendump, then parse the resulting PPM
# host-side to prove the framebuffer isn't uniformly black.
# ---------------------------------------------------------------------------

def qemu_qmp_screendump(sock_path, out_path, timeout=25):
    """
    Take a framebuffer screendump over QEMU's QMP monitor (a dedicated unix
    socket, separate from the HMP monitor that `-nographic` muxes onto the
    serial stdio this boot test drives). QMP handshake per protocol: read the
    greeting, send `qmp_capabilities`, then `screendump` — which returns only
    after the PPM has been fully written host-side. Returns (ok, detail);
    never raises (a connect/timeout/protocol failure is a failed check, not a
    crashed run).
    """
    sock = None
    buf = b""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        deadline = time.time() + timeout
        sock.connect(sock_path)

        def recv_msg():
            # QMP messages are newline-terminated JSON objects; a single recv
            # may carry several (e.g. an async event before a return), so we
            # buffer across calls and hand back one parsed object at a time.
            nonlocal buf
            while True:
                nl = buf.find(b"\n")
                if nl != -1:
                    line = buf[:nl].strip()
                    buf = buf[nl + 1:]
                    if not line:
                        continue
                    try:
                        return json.loads(line.decode("utf-8", "replace"))
                    except ValueError:
                        continue  # skip any non-JSON noise
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                sock.settimeout(remaining)
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    return None
                if not chunk:
                    return None
                buf += chunk

        greeting = recv_msg()
        if not greeting or "QMP" not in greeting:
            return False, f"no QMP greeting within {timeout}s (got {greeting!r})"

        sock.sendall(b'{"execute":"qmp_capabilities"}\n')
        cap = recv_msg()
        if not cap or "return" not in cap:
            return False, f"qmp_capabilities did not return OK (got {cap!r})"

        sock.sendall(
            json.dumps({"execute": "screendump", "arguments": {"filename": out_path}}).encode("ascii")
            + b"\n"
        )
        # Read until the command's return/error (async QMP events may precede it).
        while True:
            msg = recv_msg()
            if msg is None:
                return False, f"no reply to 'screendump' within {timeout}s"
            if "error" in msg:
                return False, f"QMP screendump error: {msg['error']!r}"
            if "return" in msg:
                return True, f"screendump written: {out_path}"
            # otherwise an async event — keep reading
    except (OSError, socket.error) as exc:
        return False, f"QMP screendump failed: {exc!r}"
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def ppm_not_black(path, min_fraction=0.005, channel_threshold=16):
    """
    Parse a binary P6 PPM (no PIL dependency — QEMU's screendump output is a
    simple, well-formed P6 with no comments in practice, but comments are
    tolerated below anyway) and check that a meaningful fraction of pixels
    are non-black — proof Xfbdev actually painted its default gray-stipple
    root + cursor rather than leaving the framebuffer at its cleared/black
    power-on state.

    A pixel counts as "non-black" if ANY channel exceeds `channel_threshold`
    (default 16, out of 255) — this tolerates dark anti-aliasing/dithering
    noise near black without requiring bright content. `min_fraction`
    (default 0.5%) is deliberately low: the TinyX default root is a subtle
    gray stipple pattern (a sparse dither, not a solid fill), so most pixels
    can legitimately still be at or near black.

    Returns (ok: bool, detail: str). Never raises.
    """
    if not os.path.isfile(path):
        return False, f"screendump file not found: {path}"

    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as exc:
        return False, f"could not read screendump file {path}: {exc!r}"

    if len(data) < 2 or data[0:1] != b"P" or data[1:2] != b"6":
        return False, f"not a binary PPM (P6) file: {path} (first bytes: {data[:16]!r})"

    idx = 2
    tokens = []
    try:
        while len(tokens) < 3:
            while idx < len(data) and data[idx:idx + 1].isspace():
                idx += 1
            if idx < len(data) and data[idx:idx + 1] == b"#":
                while idx < len(data) and data[idx:idx + 1] != b"\n":
                    idx += 1
                continue
            start = idx
            while idx < len(data) and not data[idx:idx + 1].isspace():
                idx += 1
            if start == idx:
                return False, f"malformed PPM header in {path}: could not parse width/height/maxval"
            tokens.append(data[start:idx])
        width, height, maxval = (int(t) for t in tokens)
        idx += 1  # exactly one whitespace byte separates maxval from pixel data
    except (ValueError, IndexError) as exc:
        return False, f"malformed PPM header in {path}: {exc!r}"

    if width <= 0 or height <= 0:
        return False, f"malformed PPM header in {path}: non-positive dimensions {width}x{height}"

    pixel_bytes = data[idx:]
    expected = width * height * 3
    if len(pixel_bytes) < expected:
        return False, (
            f"truncated PPM {path}: expected {expected} pixel bytes for "
            f"{width}x{height}, got {len(pixel_bytes)}"
        )

    total = width * height
    nonblack = 0
    for i in range(0, expected, 3):
        if (pixel_bytes[i] > channel_threshold
                or pixel_bytes[i + 1] > channel_threshold
                or pixel_bytes[i + 2] > channel_threshold):
            nonblack += 1

    frac = nonblack / total if total else 0.0
    detail = f"non-black pixels: {frac * 100:.1f}% ({width}x{height})"
    return frac > min_fraction, detail


# ---------------------------------------------------------------------------
# Mode implementations
# ---------------------------------------------------------------------------

def run_bios(child, args):
    select_isolinux_label(child, "serial")
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)
    results = run_full_smoke_suite(child, args.kernel_version)
    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


def run_uefi(child, args):
    select_grub_serial_entry(child)
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)
    results = run_full_smoke_suite(child, args.kernel_version)
    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


def run_toram(child, args):
    select_isolinux_label(child, "serial toram")
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(
        child, MILESTONE_TORAM_EJECTABLE, args.boot_timeout,
        "squashfs copied to RAM (toram engaged)",
    )
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)

    results = run_reduced_smoke_suite(child, args.kernel_version)
    ok = report_results(results)

    eject_ok, eject_detail = eject_cd_and_verify(child, args.cdrom_monitor_id)
    log(f"  [{'PASS' if eject_ok else 'FAIL'}] system survives CD eject (toram) — {eject_detail}")
    ok = ok and eject_ok

    poweroff_and_wait(child)
    return ok


def run_uefi_driver_variant(child, args, driver_checks):
    """
    Shared UEFI/GRUB boot-and-verify path for the Tier-1 storage-controller
    variants (ahci, nvme, usb, virtio). Same milestone sequence as run_uefi,
    but runs `driver_checks` — the module-coldplug assertions specific to the
    storage controller under test — BEFORE the reduced smoke suite, so a
    driver failing to load is reported as its own distinct failure instead of
    being buried inside "did the shell come up at all". `driver_checks` is a
    list of (name, check_fn) pairs where check_fn(child) -> (ok, detail).
    """
    select_grub_serial_entry(child)
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)

    results = []
    for name, check_fn in driver_checks:
        results.append((name, *check_fn(child)))
    results.extend(run_storage_smoke_suite(child, args.kernel_version))

    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


def run_ahci(child, args):
    return run_uefi_driver_variant(
        child, args,
        [("ahci SATA driver is loaded as a module (coldplug)", smoke_ahci_is_module)],
    )


def run_nvme(child, args):
    return run_uefi_driver_variant(
        child, args,
        [("nvme driver is loaded as a module (coldplug)", smoke_nvme_is_module)],
    )


def run_usb(child, args):
    # The full USB host-controller chain (xHCI/EHCI/OHCI/UHCI) is Tier-1 modular
    # (usbcore stays built-in); the initrd coldplugs the HCD, the bus enumerates,
    # then usb-storage binds the disk. Assert both links of that chain.
    return run_uefi_driver_variant(
        child, args,
        [
            ("xhci_hcd USB host-controller driver is loaded as a module (coldplug)", smoke_xhci_hcd_is_module),
            ("usb_storage driver is loaded as a module (coldplug)", smoke_usb_storage_is_module),
        ],
    )


def run_virtio(child, args):
    return run_uefi_driver_variant(
        child, args,
        [("virtio_blk driver is loaded as a module (coldplug)", smoke_virtio_blk_is_module)],
    )


def run_nicless(child, args):
    """
    Negative control: boot via BIOS/ISOLINUX (same as run_bios) with no NIC
    hardware attached at all, then assert e1000 did NOT load. Skips the
    NIC-dependent parts of the smoke suite (eth0 link, DHCP) since there is
    deliberately no NIC to bring up — only uname and the overlay mount are
    checked alongside the negative lsmod assertion.
    """
    select_isolinux_label(child, "serial")
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)

    results = []
    results.append(("e1000 NIC driver NOT loaded (no NIC hardware present)", *smoke_nic_not_loaded(child)))
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, args.kernel_version)))
    results.append(("overlay root is mounted", *smoke_overlay_mount(child)))

    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


def run_gui(child, args):
    """
    SP-GUI G1 Step 3: boot via BIOS/ISOLINUX (same milestone sequence as
    run_nicless), start the TinyX Xfbdev server in the background on the
    booted shell against the vesafb framebuffer with ONLY the libXfont
    built-in fonts (`-fp built-ins`, no font files on disc), then prove two
    things: (1) the server is alive with no fatal error in its own log, and
    (2) a QEMU-monitor screendump of the framebuffer it's driving is not
    uniformly black — i.e. it actually painted its default gray-stipple root
    + cursor, not just opened the device and hung/crashed silently.

    No X client is involved anywhere in this check — the server paints its
    own root window on startup with no client connected.
    """
    select_isolinux_label(child, "serial")
    expect_milestone(child, MILESTONE_INIT_START, args.boot_timeout, "initramfs /init started")
    expect_milestone(child, MILESTONE_OVERLAY_READY, args.boot_timeout, "squashfs+overlay mounted")
    expect_milestone(child, MILESTONE_EXEC_INIT, args.boot_timeout, "pivot_root complete, executing /sbin/init")
    expect_milestone(child, MILESTONE_RCS_START, args.boot_timeout, "sysvinit rcS started")
    expect_milestone(child, MILESTONE_RCS_COMPLETE, args.boot_timeout, "sysvinit rcS completed")
    wait_for_shell(child)

    log("Starting Xfbdev in the background on /dev/fb0 (built-in fonts only, no font files on disc)")
    child.sendline("Xfbdev :0 -fbdev /dev/fb0 -fp built-ins >/tmp/xfbdev.log 2>&1 &")
    time.sleep(1)  # let the shell fork the background job before driving more commands over serial
    # Give Xfbdev a few seconds to open the framebuffer, init built-in fonts,
    # and paint its default root + cursor.
    run_check(child, "settle after backgrounding Xfbdev", "sleep 4", exit_code_only(), timeout=15)

    # Dump the log to the serial console unconditionally (exit code ignored)
    # so a failure is debuggable straight from the CI serial-log artifact,
    # without needing a separate mechanism to pull /tmp/xfbdev.log off the guest.
    run_check(child, "dump /tmp/xfbdev.log (debug)", "cat /tmp/xfbdev.log 2>&1; true", exit_code_only(), timeout=15)

    # A server that failed to open the framebuffer or the built-in fonts
    # exits immediately, so "is the process still alive" is the most robust
    # positive signal — corroborated by a negative scan of the log for the
    # error strings Xfbdev/libXfont actually emit on those failure paths.
    server_up = run_check(
        child, "Xfbdev process alive with no fatal error logged",
        "pgrep -x Xfbdev >/dev/null 2>&1 && "
        "! grep -Eq 'Fatal|could not open default font|giving up' /tmp/xfbdev.log",
        exit_code_only(), timeout=15,
    )

    log("Taking a QEMU QMP screendump of the framebuffer")
    screendump_out = os.path.abspath(args.gui_screendump)
    os.makedirs(os.path.dirname(screendump_out) or ".", exist_ok=True)
    dump_ok, dump_detail = qemu_qmp_screendump(args.gui_monitor_sock, screendump_out)
    if dump_ok:
        not_black_ok, not_black_detail = ppm_not_black(screendump_out)
    else:
        not_black_ok, not_black_detail = False, f"screendump failed: {dump_detail}"

    results = [
        ("Xfbdev starts and stays alive on /dev/fb0", *server_up),
        ("framebuffer screendump is not uniformly black", not_black_ok, not_black_detail),
    ]
    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


def run_nic(child, args):
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

    results = []
    if args.nic_model == "ne2k_isa":
        smoke_isa_probe(child, results)
    else:
        results.append((f"{args.nic_model} coldplug", *smoke_nic_model_is_module(child, args.nic_model)))
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, args.kernel_version)))
    results.append(("overlay root is mounted", *smoke_overlay_mount(child)))

    ok = report_results(results)
    poweroff_and_wait(child)
    return ok


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
    results.append(("router: monolith-router up --dhcp",
                    *run_check(child, "monolith-router eth0 eth1 --dhcp --yes",
                               "monolith-router eth0 eth1 --dhcp --yes",
                               contains("DHCP+DNS up"), timeout=60)))
    results.append(("router: nft masquerade present",
                    *run_check(child, "nft ruleset", "nft list ruleset",
                               contains("masquerade"))))
    # Emit a distinctive marker rather than the bare "1": bash's bracketed-paste
    # escape (\x1b[?2004l) prepends the value on its line, so a line-anchored
    # ^1 regex misses it. `contains("ipfwd=1")` is escape-tolerant like the other
    # NAT assertions.
    results.append(("router: ip_forward=1",
                    *run_check(child, "ip_forward",
                               "echo ipfwd=$(cat /proc/sys/net/ipv4/ip_forward)",
                               contains("ipfwd=1"))))
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

    client = None
    try:
        client = pexpect.spawn(build_nat_client_cmd(args)[0], build_nat_client_cmd(args)[1:],
                               timeout=args.boot_timeout, encoding="utf-8", codec_errors="replace")
        if args.log_file:
            client.logfile = open(args.log_file + ".client", "w", encoding="utf-8", errors="replace")
        _boot_isolinux_to_shell(client, args)

        # Defensive: drain the router child's serial so its pexpect pty can't
        # back up while we're busy driving the client. This is hygiene, NOT the
        # historical nat-router flake — that was a monolith-router bug (it skipped
        # assigning the LAN gateway CIDR when eth1 already carried a failed-DHCP
        # 169.254 link-local, so the router answered no ARP for the gateway). It's
        # fixed in monolith-router; these diagnostics are what localized it.
        def drain_router():
            try:
                while True:
                    child.read_nonblocking(size=65536, timeout=0)
            except Exception:
                pass  # pexpect TIMEOUT/EOF — nothing more queued

        # Localize any failure: L2 (dead inter-guest link) vs L3/NAT vs a router
        # mis-config. router-pre shows eth1's actual address + link/counters (this
        # is what caught the missing gateway CIDR); client pings the gateway;
        # router-post proves whether frames crossed (RX ticks, neighbour learned).
        # A REACHABLE gateway ping means the link + gateway addressing are good, so
        # a later curl failure is NAT/routing. exit_code_only never fails the run.
        def _diag(node, label, cmds):
            for d in cmds:
                run_check(node, f"{label}-diag: {d}", d, exit_code_only(), timeout=15)

        drain_router()
        # Set the client's name via busybox (the GNU rootfs has no standalone
        # `hostname` command; busybox is built CONFIG_HOSTNAME=y).
        run_check(client, "client hostname", "busybox hostname natclient", exit_code_only())
        # CRITICAL: a dhcpcd daemon is ALREADY running from boot (S40network runs
        # `dhcpcd -b eth0`) and it leased at boot WITHOUT a hostname. Re-invoking
        # `dhcpcd ... --hostname=natclient` then only sends a control command to
        # that running daemon ("sending commands to dhcpcd process") and the flag
        # is inert — which is why the lease hostname stayed "*". Stop the boot
        # daemon first, then start a FRESH one-shot client that actually sends the
        # hostname (DHCP option 12). dhcpcd honors --hostname when run as a fresh
        # manual client.
        run_check(client, "stop boot dhcpcd", "dhcpcd -x 2>/dev/null; dhcpcd -k eth0 2>/dev/null; sleep 1; true",
                  exit_code_only(), timeout=20)
        # Fresh lease WITH the hostname. `dhcpcd -1` exits 0 once configured with a
        # lease and non-zero on timeout/failure, so the exit code — not a log
        # string — is the reliable success signal. The in-range check corroborates.
        results.append(("client: DHCP lease from the box",
                        *run_check(client, "dhcpcd", "dhcpcd -1 -t 30 --hostname=natclient eth0",
                                   exit_code_only(), timeout=45)))

        drain_router()
        # Lease is inside the dnsmasq range 192.168.99.50-200.
        results.append(("client: leased address in DHCP range",
                        *run_check(client, "client addr",
                                   "ip -4 -o addr show dev eth0 | grep -oE '192\\.168\\.99\\.[0-9]+'",
                                   regex_matches(r"192\.168\.99\.(5[0-9]|[6-9][0-9]|1[0-9][0-9]|200)"),
                                   timeout=15)))
        # DNS through the box: resolve the router's own registered name against
        # the box's dnsmasq. The GNU booted rootfs has no standalone `nslookup`
        # (bind-tools isn't installed); we call busybox's nslookup applet
        # (CONFIG_NSLOOKUP=y) explicitly — `busybox nslookup HOST SERVER` queries
        # SERVER directly, proving the .home.arpa zone resolves through the box.
        results.append(("client: resolves monolith.home.arpa via the box",
                        *run_check(client, "nslookup",
                                   "busybox nslookup monolith.home.arpa 192.168.99.1",
                                   contains("192.168.99.1"), timeout=20)))

        drain_router()
        # DHCP-hostname → DNS zone registration: the client sent its hostname
        # (DHCP option 12) in the fresh lease, so dnsmasq (expand-hosts +
        # domain=home.arpa) registered natclient.home.arpa → the leased address.
        # This is the actual "DHCP client names auto-populate the zone" proof. The
        # lease-range regex CANNOT be satisfied by nslookup's own "Server: 192.168.99.1"
        # line (.1 is outside .50-.200), so only a genuine leased answer passes.
        results.append(("client: natclient.home.arpa resolves to the leased address",
                        *run_check(client, "nslookup natclient",
                                   "busybox nslookup natclient.home.arpa 192.168.99.1",
                                   regex_matches(r"192\.168\.99\.(5[0-9]|[6-9][0-9]|1[0-9][0-9]|200)"),
                                   timeout=20)))

        _diag(child, "router-pre",
              ["ip -o addr show dev eth1", "ip -o link show dev eth1", "cat /proc/net/dev"])
        _diag(client, "client",
              ["ip -o addr show dev eth0", "ping -c2 -W2 192.168.99.1", "ip neigh show"])
        _diag(child, "router-post", ["ip neigh show", "cat /proc/net/dev"])
        # Positive: reach the host http.server THROUGH the router's masquerade.
        # Poll rather than fire a single shot — the client's first-packet ARP to
        # the gateway plus conntrack setup can take a moment, and a lone curl the
        # instant after `ip route add` can race that and return EHOSTUNREACH.
        # Retry a bounded number of times, breaking on the first success; a
        # genuine NAT break still fails — the loop exhausts without the marker.
        drain_router()
        results.append(("client: curl host service through NAT",
                        *run_check(client, "curl via NAT",
                                   "for i in $(seq 1 20); do "
                                   "curl -s -m 4 http://10.0.2.2:8000/probe.txt && break; "
                                   "sleep 1; done",
                                   contains("NAT_OK_marker"), timeout=120)))
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


MODE_BUILDERS = {
    "bios": build_bios_cmd,
    "uefi": build_uefi_cmd,
    "toram": build_bios_cmd,
    "ahci": build_ahci_cmd,
    "nvme": build_nvme_cmd,
    "usb": build_usb_cmd,
    "virtio": build_virtio_cmd,
    "nicless": build_nicless_cmd,
    "nic": build_nic_cmd,
    "nat": build_nat_router_cmd,
    "gui": build_gui_cmd,
}

MODE_RUNNERS = {
    "bios": run_bios,
    "uefi": run_uefi,
    "toram": run_toram,
    "ahci": run_ahci,
    "nvme": run_nvme,
    "usb": run_usb,
    "virtio": run_virtio,
    "nicless": run_nicless,
    "nic": run_nic,
    "nat": run_nat,
    "gui": run_gui,
}

MODE_DEFAULT_RAM = {
    "bios": 64,
    "uefi": 512,
    "toram": 512,  # copies the full squashfs into RAM + a 50% tmpfs overlay; 128M OOMs
    "ahci": 512,
    "nvme": 512,
    "usb": 512,
    "virtio": 512,
    "nicless": 64,  # mirrors bios: same machine type, no extra RAM pressure
    "nic": 256,
    "nat": 256,
    "gui": 128,
}


def parse_args():
    p = argparse.ArgumentParser(
        description="Boot The Monolith ISO in QEMU and verify it reaches a working shell.",
    )
    p.add_argument("--iso", required=True, help="Path to the themonolith-*.iso file to test")
    p.add_argument("--mode", required=True, choices=sorted(MODE_RUNNERS), help="Which boot path to exercise")
    p.add_argument(
        "--kernel-version", required=True,
        help=(
            "Expected `uname -r` string, e.g. 6.12.80-i486-monolith. "
            "Compute this from configs/portage/versions.lock "
            "(sys-kernel/monolith-kernel) + CONFIG_LOCALVERSION in "
            "configs/kernel.config — never hardcode it here or in CI."
        ),
    )
    p.add_argument("--ram-mb", type=int, default=None, help="Guest RAM in MB (default depends on --mode)")
    p.add_argument("--qemu-i386", default="qemu-system-i386")
    p.add_argument("--qemu-x86_64", default="qemu-system-x86_64")
    p.add_argument("--ovmf-code", default=None, help="Path to OVMF_CODE.fd (uefi mode only; auto-detected if omitted)")
    p.add_argument(
        "--boot-timeout", type=int, default=DEFAULT_BOOT_TIMEOUT,
        help=f"Max seconds to wait for each boot milestone (default: {DEFAULT_BOOT_TIMEOUT})",
    )
    p.add_argument(
        "--cdrom-monitor-id", default="ide1-cd0",
        help="QEMU block device id for `eject` in the monitor (toram mode only). "
             "'ide1-cd0' is QEMU's default id for a plain -cdrom on the pc/i440fx machine type.",
    )
    p.add_argument("--log-file", default=None, help="Write the full serial session transcript here")
    p.add_argument("--nic-model", default=None,
                   choices=["pcnet", "rtl8139", "tulip", "ne2k_pci", "ne2k_isa"],
                   help="QEMU NIC model for --mode nic (pcnet|rtl8139|tulip|ne2k_pci|ne2k_isa)")
    p.add_argument(
        "--gui-screendump", default="output/gui-screendump.ppm",
        help="Host-side path QEMU's HMP 'screendump' writes the framebuffer PPM to (gui mode only)",
    )
    return p.parse_args()


def main():
    args = parse_args()
    if args.ram_mb is None:
        args.ram_mb = MODE_DEFAULT_RAM[args.mode]

    log(f"mode={args.mode} iso={args.iso} ram={args.ram_mb}M kernel={args.kernel_version}")

    import os
    if not os.path.isfile(args.iso):
        log(f"FATAL: ISO not found: {args.iso}")
        sys.exit(2)

    child = None
    ok = False
    try:
        cmd = MODE_BUILDERS[args.mode](args)
        log(f"Launching: {' '.join(cmd)}")

        child = pexpect.spawn(
            cmd[0], cmd[1:], timeout=args.boot_timeout, encoding="utf-8", codec_errors="replace"
        )
        if args.log_file:
            child.logfile = open(args.log_file, "w", encoding="utf-8", errors="replace")
            log(f"Logging full session to {args.log_file}")

        ok = MODE_RUNNERS[args.mode](child, args)
    except BootTestError as exc:
        log(f"FATAL: {exc}")
        ok = False
    except pexpect.ExceptionPexpect as exc:
        log(f"FATAL: pexpect error: {exc}")
        ok = False
    finally:
        if child is not None:
            if child.isalive():
                log("Guest still alive at end of test — force-killing QEMU")
                try:
                    child.close(force=True)
                except Exception:
                    pass
            if args.log_file and child.logfile:
                child.logfile.close()

    if ok:
        log(f"RESULT: PASS ({args.mode})")
        sys.exit(0)
    else:
        log(f"RESULT: FAIL ({args.mode})")
        sys.exit(1)


if __name__ == "__main__":
    main()
