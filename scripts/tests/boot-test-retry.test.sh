#!/bin/sh
# Unit test for boot-test.py's launch-flake decision logic
# (should_retry_launch). This is the guard that separates a transient
# QEMU-startup flake (guest never reaches /init -> relaunch) from a real
# boot/assertion failure (guest reached /init, something after it failed ->
# report, never mask). It is pure logic, so we exercise the full decision
# matrix directly instead of booting a VM.
#
# boot-test.py imports pexpect at module scope, which isn't installed in the
# lint runner; we inject a tiny stub into sys.modules so the module imports
# for the pure-function test without pulling the real dependency. Importing is
# side-effect-free (the `if __name__ == "__main__"` guard keeps main() from
# running on import).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BOOT_TEST="$HERE/../boot-test.py"

python3 - "$BOOT_TEST" <<'PY'
import sys, types, importlib.util

# Stub pexpect only if the real one is absent, so this runs in a bare lint env.
if "pexpect" not in sys.modules:
    stub = types.ModuleType("pexpect")
    stub.TIMEOUT = type("TIMEOUT", (Exception,), {})
    stub.EOF = type("EOF", (Exception,), {})
    stub.ExceptionPexpect = type("ExceptionPexpect", (Exception,), {})
    stub.spawn = lambda *a, **k: None
    sys.modules["pexpect"] = stub

spec = importlib.util.spec_from_file_location("boot_test_mod", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

srl = m.should_retry_launch
MAX = 3
fails = 0

def check(label, got, want):
    global fails
    if got is want:
        print(f"  ok: {label}")
    else:
        print(f"  FAIL: {label} -> got {got!r}, want {want!r}")
        fails += 1

# A silent guest (never reached /init) with attempts left -> RETRY: this is the
# QEMU-startup flake pattern the whole mechanism exists for.
check("silent guest, attempts left -> retry",
      srl(ok=False, reached_init=False, attempt=1, max_attempts=MAX), True)
check("silent guest, one retry used, still room -> retry",
      srl(ok=False, reached_init=False, attempt=2, max_attempts=MAX), True)

# Exhausted attempts -> STOP: a guest silent across every launch is no longer a
# transient flake; report it as a real failure rather than loop forever.
check("silent guest on the final attempt -> stop (report real failure)",
      srl(ok=False, reached_init=False, attempt=MAX, max_attempts=MAX), False)

# Reached /init then failed -> NEVER retry: SeaBIOS+kernel+initramfs all ran, so
# the failure is real; retrying would mask a genuine regression.
check("failure AFTER /init -> never retry (real boot/assertion failure)",
      srl(ok=False, reached_init=True, attempt=1, max_attempts=MAX), False)

# Success -> never retry, regardless of how far it got.
check("success -> no retry",
      srl(ok=True, reached_init=True, attempt=1, max_attempts=MAX), False)
check("success even if reached_init unset -> no retry",
      srl(ok=True, reached_init=False, attempt=1, max_attempts=MAX), False)

print()
if fails:
    print(f"{fails} FAILED")
    sys.exit(1)
print("ALL PASS")
PY
