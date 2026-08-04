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

Ground truth this script is built against (re-check these if the boot
sequence ever changes — this script has no other source of truth):
  rootfs/init                 — initramfs init: mount sequence, log lines
  scripts/build-rootfs.sh     — /etc/inittab, /etc/init.d/rcS, /etc/passwd etc.
  scripts/build-iso.sh        — ISOLINUX + GRUB menu definitions

Two important, non-obvious facts about this ISO that shape this script:

1. There is no login prompt. /etc/inittab runs
     agetty -n -l /bin/bash ...
   on every console (tty1, tty2, ttyS0) — `-n` skips the username/password
   prompt entirely and execs bash directly as root. "Passwordless root" here
   means "no authentication step happens at all", not "empty password is
   accepted at a login: prompt". This script never sends a username.

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
  - grub.cfg: `set default=1` (the framebuffer entry, gfxterm-only, also
    invisible over -nographic/serial). We send a Down-arrow + Enter to select
    the "(serial)" entry (index 2) instead. GRUB has no `toram`-over-serial
    entry at all (its `(toram)` menuentry doesn't set console=ttyS0), so
    `toram` is only exercised via the BIOS/ISOLINUX path in this script,
    where the boot prompt lets us combine `serial toram` in one line.

This script cannot be exercised on the authoring machine (no qemu-system-*
here). It is written to be correct against the code above and is meant to be
proven out by CI logs, not by a local run.
"""

import argparse
import os
import re
import shutil
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
#   0 plain  1 framebuffer(default)  2 serial  3 debug  4 rescue  5 toram
# We only ever need entry 2 ("(serial)"); toram is tested via ISOLINUX instead
# (see module docstring) because the GRUB toram entry has no console=ttyS0.
GRUB_SERIAL_ENTRY_DOWN_PRESSES = 1

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

    Menu order (grub.cfg, 0-indexed): 0 plain, 1 framebuffer (default,
    `set default=1`), 2 serial, 3 debug, 4 rescue, 5 toram, 6 persistent.
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
    """
    marker = f"MONOLITH_SHELL_READY_{uuid.uuid4().hex[:8]}"
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


def run_full_smoke_suite(child, expected_kernel):
    results = []
    results.append(("uname -r matches expected kernel", *smoke_kernel_version(child, expected_kernel)))
    results.append(("e1000 NIC driver loaded as a module (coldplug)", *smoke_nic_is_module(child)))
    results.append(("eth0 link is up", *smoke_eth0_link(child)))
    smoke_dhcp_lease(child, results)
    results.append(("curl --version executes", *smoke_curl(child)))
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


MODE_BUILDERS = {
    "bios": build_bios_cmd,
    "uefi": build_uefi_cmd,
    "toram": build_bios_cmd,
}

MODE_RUNNERS = {
    "bios": run_bios,
    "uefi": run_uefi,
    "toram": run_toram,
}

MODE_DEFAULT_RAM = {
    "bios": 64,
    "uefi": 512,
    "toram": 512,  # copies the full squashfs into RAM + a 50% tmpfs overlay; 128M OOMs
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
