#!/usr/bin/env python3
"""mkcfgbe.py <dir>: big-endian ("BE") config files for config_test (Task 11).

The previous (big-endian) firmware wrote its config file (MINMGAA.CFG,
MINMGAA<n>.CFG) as configTYPE was in its memory: big-endian, unsigned long =
4 bytes; the RISC-V firmware converts such files (config.c, cfgswap.c,
tools/cfgconv).  This
script writes such files from a field table that follows fw/ctrl/config.h
(struct.pack, independent of the C code: no offset, size or swap of
cfgswap.c is used here).  python3 -I, standard library only.

Written into <dir>:
  <case>.cfg     the big-endian file of each case below
  <case>.check   what `cfgconv --check <case>.cfg` must print (valid cases)
  cfgcases.h     for config_test.c:
                   CFG_CASE(name, order, length)            every case
                   CFG_FIELD_U(name, member, value)         number fields
                   CFG_FIELD_S(name, member, "bytes")       char arrays
                 (the fields of the valid cases that lie inside the file)

Cases:
  defaults         the firmware's default config (config.c, "set default
                   configuration")
  distinct         every field non-zero and distinct (floppy.drives 3: the
                   sanity check wants <= 4; version 4), the 32-bit fields
                   with four different bytes each
  v2, v3           distinct with version 2 / 3 (the old-format paths of
                   LoadConfiguration: extrom, kickdir, hdfdir, drivesounds)
  v3_208           v3 cut to 208 bytes, the file of the firmware before
                   audio/videopos (the previous firmware's db2dda6..a6cf54d)
  l2               defaults with a few harmless changes, kickdir 0: the
                   fwboot_cfg card (sim/host_bridge/fwboot/Makefile)
  corrupt_id       distinct with id MNMGCFGB
  corrupt_version  distinct with version 5 (in neither order 1..4)
  corrupt_version0 distinct with version 0
  corrupt_short    distinct cut to 155 bytes (hdfdir[3] incomplete)
  corrupt_long     distinct plus one byte (213)
"""
import os
import struct
import sys

# configTYPE (fw/ctrl/config.h) in struct order: (name, struct code).
# 'L' = unsigned long (32 bits on both firmwares' CPUs), big-endian here.
FIELDS = [("id", "8s"), ("version", "L"),
          ("kickstart.name", "8s"), ("kickstart.long_name", "16s"),
          ("filter.lores", "B"), ("filter.hires", "B"),
          ("memory", "B"), ("chipset", "B"),
          ("floppy.speed", "B"), ("floppy.drives", "B"),
          ("disable_ar3", "B"), ("enable_ide", "B"), ("scanlines", "B"), ("misc", "B")]
for i in range(2):
    FIELDS += [(f"hardfile[{i}].enabled", "B"), (f"hardfile[{i}].present", "B"),
               (f"hardfile[{i}].name", "8s"), (f"hardfile[{i}].long_name", "16s")]
FIELDS += [("cpu", "B"), ("fastram", "B"), ("kick13patch", "B"), ("autofire", "B"),
           ("extrom.name", "8s"), ("extrom.long_name", "16s"),
           ("drivesounds", "B"), ("crt_beam", "B"), ("crt_mask", "B"), ("crt_bloom", "B"),
           # the RTG screen's Video Pos: the two alignment bytes before kickdir
           # (0 in a file of older firmware: centred)
           ("videopos_rtg.hpos", "B"), ("videopos_rtg.vpos", "B"),
           ("kickdir", "L"), ("extromdir", "L")]
FIELDS += [(f"hdfdir[{i}]", "L") for i in range(4)]
for i in range(2):
    FIELDS += [(f"secondaryhardfile[{i}].enabled", "B"), (f"secondaryhardfile[{i}].present", "B"),
               (f"secondaryhardfile[{i}].name", "8s"), (f"secondaryhardfile[{i}].long_name", "16s")]
FIELDS += [("audio.volume", "B"), ("videopos.hpos", "B"), ("videopos.vpos", "B"),
           ("hdmi_clkdelay", "B")]

FMT = ">" + "".join(code for _, code in FIELDS)
assert struct.calcsize(FMT) == 212, struct.calcsize(FMT)
PAD = "(pad)"


def offsets():
    """name -> (offset, size) from the struct codes"""
    out, off = {}, 0
    for name, code in FIELDS:
        n = struct.calcsize(">" + code)
        out[name or PAD] = (off, n)
        off += n
    return out


OFFS = offsets()


def defaults():
    """config.c's defaults (memset 0, then the assignments)"""
    v = {name or PAD: (b"" if code.endswith("s") else 0) for name, code in FIELDS}
    v.update({"id": b"MNMGCFGA", "version": 4, "kickstart.name": b"KICK    ",
              "misc": 1 << 0,                  # 1 << PLATFORM_SCANDOUBLER
              "memory": 0x15, "floppy.speed": 1, "floppy.drives": 1,   # CONFIG_FLOPPY2X
              "hardfile[0].enabled": 1, "hardfile[0].name": b"HARDFILE",
              "hardfile[1].name": b"HARDFILE", "hardfile[1].enabled": 2,
              "secondaryhardfile[0].enabled": 7,   # HDF_CDROM
              "audio.volume": 15, "extrom.name": b"EXTENDED"})
    return v


def distinct():
    v, nb, nl, ns = {}, 0x21, 0, 0
    for name, code in FIELDS:
        if name is None:
            v[PAD] = b"\xa5\x5a"
        elif code == "B":
            v[name] = nb
            nb += 1
        elif code == "L":
            nl += 1        # four different bytes, none a mirror of another field's
            v[name] = (0xA0 + nl) << 24 | (0xB0 + nl) << 16 | (0xC0 + nl) << 8 | (0xD0 + nl)
        else:
            ns += 1
            size = struct.calcsize(code)
            v[name] = (f"N{ns:02d}NAME_" if size == 8 else f"Long name #{ns:02d} xy").encode()
            assert len(v[name]) == size
    v["id"] = b"MNMGCFGA"
    v["version"] = 4
    v["floppy.drives"] = 3
    bytes_ = [x for k, x in v.items() if isinstance(x, int) and OFFS[k][1] == 1]
    assert len(set(bytes_)) == len(bytes_) and 0 not in bytes_
    return v


def pack(v):
    vals = []
    for name, code in FIELDS:
        x = v[name or PAD]
        vals.append(x.ljust(struct.calcsize(code), b"\0") if isinstance(x, bytes) else x)
    return struct.pack(FMT, *vals)


def l2():
    v = defaults()
    v.update({"audio.volume": 9, "floppy.speed": 0, "kickstart.long_name": b"L2 kick",
              "extrom.long_name": b"L2 extrom", "extromdir": 0x0A0B0C0D,
              "hdfdir[3]": 0x01020304})
    return v


def cases():
    """(name, order, bytes, field values or None)"""
    d = distinct()
    out = [("defaults", "CFG_BE", defaults()), ("distinct", "CFG_BE", d)]
    for ver in (2, 3):
        x = dict(d)
        x["version"] = ver
        out.append((f"v{ver}", "CFG_BE", x))
    out.append(("l2", "CFG_BE", l2()))
    res = [(n, o, pack(v), v) for n, o, v in out]
    v3 = dict(d)
    v3["version"] = 3
    res.append(("v3_208", "CFG_BE", pack(v3)[:208], v3))
    bad = dict(d)
    bad["id"] = b"MNMGCFGB"
    res.append(("corrupt_id", "CFG_BAD", pack(bad), None))
    for ver, n in ((5, "corrupt_version"), (0, "corrupt_version0")):
        bad = dict(d)
        bad["version"] = ver
        res.append((n, "CFG_BAD", pack(bad), None))
    res.append(("corrupt_short", "CFG_BAD", pack(d)[:155], None))
    res.append(("corrupt_long", "CFG_BAD", pack(d) + b"\x01", None))
    return res


def c_bytes(b):
    """a C string literal of exactly these bytes (octal escapes: no hex run-on)"""
    return '"' + "".join(f"\\{c:03o}" for c in b) + '"'


def show(b):
    """cfgconv --check's text of a char array: up to the first NUL, bytes
    outside 0x20..0x7e and the quote and backslash as \\xHH"""
    b = b.split(b"\0", 1)[0]
    return '"' + "".join(chr(c) if 0x20 <= c <= 0x7E and c not in (0x22, 0x5C) else f"\\x{c:02x}"
                         for c in b) + '"'


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkcfgbe.py <dir>")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    h = ["/* generated by fw/ctrl/test/gold/mkcfgbe.py: do not edit */"]
    for name, order, data, v in cases():
        with open(os.path.join(out, name + ".cfg"), "wb") as f:
            f.write(data)
        h.append(f"CFG_CASE({name}, {order}, {len(data)})")
        if v is None:
            continue
        check = ["order = BE"]
        for field, code in FIELDS:
            if field is None:
                continue
            off, size = OFFS[field]
            if off + size > len(data):
                continue
            x = v[field]
            if isinstance(x, bytes):
                full = x.ljust(size, b"\0")
                h.append(f"CFG_FIELD_S({name}, {field}, {c_bytes(full)})")
                check.append(f"{field} = {show(x)}")
            else:
                h.append(f"CFG_FIELD_U({name}, {field}, {x}u)")
                check.append(f"{field} = {x}")
        with open(os.path.join(out, name + ".check"), "w") as f:
            f.write("\n".join(check) + "\n")
    with open(os.path.join(out, "cfgcases.h"), "w") as f:
        f.write("\n".join(h) + "\n")


if __name__ == "__main__":
    main()
