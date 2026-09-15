#!/usr/bin/env python3
"""Decode an ila_rtg_capture.tcl CSV into Akiko RTG register accesses.

    tools/vivado/rtg_decode.py <csv> [<csv> ...]

Probe layout (rtl/soc/TG68K.vhd dbg_rtg, minimig_virtual_top.v probe10):
    dbg_rtg  [31] akiko_req [30] akiko_wr [29:28] bstate [27:16] cpuaddr[11:0] [15:0] data
    probe10  [28] rtg_ena [27] rtg_16bit [26] rtg_clut [25:22] pixelwidth [21:0] rtg_addr[25:4]
Register map (rtl/akiko/akiko.vhd): $B80100 framebuffer address high word,
$B80102 low word, $B80104 control, $B80106 pixel format, $B8010E id,
$B80400-$B807FF CLUT (4 bytes per entry).
Stage E0, findings/ap68040/stage-e/2026-09-15-e0-e1-plan.md Task 7.
"""
import csv
import sys

NAMES = {0x100: "fb_addr_hi", 0x102: "fb_addr_lo", 0x104: "control",
         0x106: "pixel_format", 0x10E: "id"}


def _hex(v):
    v = v.strip().lower()
    return int(v[2:] if v.startswith("0x") else v, 16)


def _name(reg):
    if 0x400 <= reg <= 0x7FF:
        return f"clut[{(reg - 0x400) // 4}]"
    return NAMES.get(reg, f"reg_{reg:03x}")


def decode_rows(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    head = rows[0]
    c_rtg = next(i for i, h in enumerate(head) if "dbg_rtg" in h)
    c_st = c_rtg + 1
    out = []
    for row in rows[2:]:
        if len(row) <= c_st or not row[c_rtg].strip():
            continue
        w, s = _hex(row[c_rtg]), _hex(row[c_st])
        if not (w >> 31) & 1:
            continue
        reg = (w >> 16) & 0xFFF
        out.append({
            "kind": "W" if (w >> 30) & 1 else "R",
            "reg": reg,
            "name": _name(reg),
            "data": w & 0xFFFF,
            "rtg_ena": (s >> 28) & 1,
            "rtg_addr": (s & 0x3FFFFF) << 4,
        })
    return out


def framebuffer(rows):
    """Amiga address written by the last fb_addr_hi/fb_addr_lo pair, or None."""
    hi = lo = None
    for r in rows:
        if r["kind"] == "W" and r["name"] == "fb_addr_hi":
            hi = r["data"]
        elif r["kind"] == "W" and r["name"] == "fb_addr_lo":
            lo = r["data"]
    if hi is None or lo is None:
        return None
    return (hi << 16) | lo


def main(paths):
    for p in paths:
        rows = decode_rows(p)
        print(f"--- {p}: {len(rows)} Akiko accesses")
        for r in rows:
            print(f"  {r['kind']} {r['name']:<13} ${0xB80000 + r['reg']:06X} = ${r['data']:04X}"
                  f"   rtg_ena={r['rtg_ena']} rtg_addr=${r['rtg_addr']:07X}")
        fb = framebuffer(rows)
        if fb is None:
            print("  framebuffer address: not written in this capture")
        else:
            where = ("Zorro II (scan-out reachable)" if fb < 0x1000000
                     else "32-bit: driver keeps low 24 bits + bit 24")
            print(f"  framebuffer address written: ${fb:08X}  -> {where}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
