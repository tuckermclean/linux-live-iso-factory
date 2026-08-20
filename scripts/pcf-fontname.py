#!/usr/bin/env python3
"""Print a PCF bitmap font's FONT property — its XLFD — read straight from the file.

The target sysroot has no mkfontscale/mkfontdir, and the builder image can't
currently be rebuilt to add them host-side (its TOOLCHAIN_EPOCH portage snapshot
was pruned upstream; see the Dockerfile). So build-rootfs.sh indexes the bitmap
font dirs with this instead, using the builder's stock python3. The XLFD is read
from the PCF's own PCF_PROPERTIES table -> AUTHORITATIVE, not guessed from
memory (the "verify the XLFD against the actual font" landmine): whatever this
prints is exactly what an X client must ask for, and what our fonts.alias must
point at.

PCF format reference: the file starts with the magic b"\\x01fcp"; a
little-endian table-of-contents lists (type, format, size, offset) entries; the
PCF_PROPERTIES table (type 1) holds an array of {name_offset, isString, value}
props followed by a string blob. The table's own multi-byte fields use the byte
order encoded in its `format` word (PCF_BYTE_MASK). We locate the prop named
"FONT" and return its string value.
"""
import sys
import gzip
import struct

PCF_PROPERTIES = 1
PCF_BYTE_MASK = 1 << 2  # table data is MSByte-first when this bit is set


def _read(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as fh:
        return fh.read()


def font_xlfd(data):
    if data[:4] != b"\x01fcp":
        raise ValueError("not a PCF file (bad magic)")
    # The table-of-contents is always little-endian.
    (count,) = struct.unpack_from("<i", data, 4)
    toc = {}
    pos = 8
    for _ in range(count):
        typ, fmt, size, offset = struct.unpack_from("<iiii", data, pos)
        toc[typ] = offset
        pos += 16
    if PCF_PROPERTIES not in toc:
        raise ValueError("no PCF_PROPERTIES table")
    base = toc[PCF_PROPERTIES]
    # The table opens with its `format` word; its byte order governs the rest.
    (tfmt,) = struct.unpack_from("<i", data, base)
    en = ">" if (tfmt & PCF_BYTE_MASK) else "<"
    pos = base + 4
    (nprops,) = struct.unpack_from(en + "i", data, pos)
    pos += 4
    props = []
    for _ in range(nprops):
        # Packed, unaligned: int32 name_offset, uint8 isString, int32 value = 9 bytes.
        name_off, is_str, value = struct.unpack_from(en + "iBi", data, pos)
        pos += 9
        props.append((name_off, is_str, value))
    if nprops & 3:  # pad the prop array to a 4-byte boundary
        pos += 4 - (nprops & 3)
    (str_size,) = struct.unpack_from(en + "i", data, pos)
    pos += 4
    strings = data[pos:pos + str_size]

    def cstr(off):
        end = strings.index(b"\x00", off)
        return strings[off:end].decode("latin-1")

    for name_off, is_str, value in props:
        if is_str and cstr(name_off) == "FONT":
            return cstr(value)
    raise ValueError("PCF has no FONT property")


def main(argv):
    if len(argv) != 2:
        print("usage: pcf-fontname.py <font.pcf[.gz]>", file=sys.stderr)
        return 2
    try:
        print(font_xlfd(_read(argv[1])))
        return 0
    except Exception as exc:  # noqa: BLE001 — build script wants a clean nonzero + message
        print(f"pcf-fontname: {argv[1]}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
