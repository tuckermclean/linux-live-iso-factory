#!/bin/sh
# Unit test for scripts/pcf-fontname.py — the PCF FONT-property reader
# build-rootfs.sh uses to index the bitmap fonts (mkfontscale isn't available:
# the target has none and the builder image can't currently be rebuilt to add
# it). If this reader returns the wrong XLFD, the whole Terminus-as-default X
# font pass silently points `fixed` at a font that doesn't exist. So we
# construct minimal synthetic PCFs (both byte orders) and assert the exact FONT
# XLFD comes back — no real font file needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
READER="$HERE/../pcf-fontname.py"

python3 - "$READER" <<'PY'
import struct, importlib.util, sys
spec = importlib.util.spec_from_file_location("pcf", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fails = 0

def build_pcf(xlfd, big_endian=False):
    # A minimal PCF: magic + LSB table-of-contents with one PCF_PROPERTIES table
    # (type 1) holding a FOUNDRY and a FONT prop. Per libXfont the table's
    # `format` word is ALWAYS read LSB; only its byte-mask bit governs the rest.
    en = ">" if big_endian else "<"
    fmt = 4 if big_endian else 0
    strings = b"FOUNDRY\x00xos4\x00FONT\x00" + xlfd.encode() + b"\x00"
    props  = struct.pack(en + "iBi", 0, 1, strings.index(b"xos4\x00"))
    props += struct.pack(en + "iBi", strings.index(b"FONT\x00"), 1, strings.index(xlfd.encode()))
    nprops = 2
    pad = b"\x00" * ((4 - (nprops & 3)) if (nprops & 3) else 0)
    table = struct.pack("<i", fmt) + struct.pack(en + "i", nprops) + props + pad \
        + struct.pack(en + "i", len(strings)) + strings
    header = b"\x01fcp" + struct.pack("<i", 1)
    offset = len(header) + 16
    toc = struct.pack("<iiii", 1, fmt, len(table), offset)
    return header + toc + table

def check(label, cond):
    global fails
    if cond:
        print(f"  ok: {label}")
    else:
        print(f"  FAIL: {label}")
        fails += 1

XLFD = "-xos4-terminus-medium-r-normal--16-160-72-72-c-80-iso10646-1"
check("little-endian PCF -> exact FONT XLFD", m.font_xlfd(build_pcf(XLFD, False)) == XLFD)
check("big-endian PCF -> exact FONT XLFD",    m.font_xlfd(build_pcf(XLFD, True))  == XLFD)

# A misc-fixed style XLFD (different foundry/registry) round-trips too.
MISC = "-misc-fixed-medium-r-normal--13-120-75-75-c-70-iso10646-1"
check("a -misc- XLFD round-trips",            m.font_xlfd(build_pcf(MISC, False)) == MISC)

# Non-PCF / no-properties inputs raise cleanly rather than returning junk.
try:
    m.font_xlfd(b"not a pcf at all")
    check("non-PCF raises", False)
except ValueError:
    check("non-PCF raises cleanly", True)

print()
if fails:
    print(f"{fails} FAILED"); sys.exit(1)
print("ALL PASS")
PY
