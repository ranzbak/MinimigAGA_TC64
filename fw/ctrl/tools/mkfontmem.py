#!/usr/bin/env python3
"""The OSD text layer's 8x16 font: one source, two outputs.

    mkfontmem.py [--font fw/ctrl/font8x16.h] [--out rtl/openaars/adv7511/osd_font.mem]
        osd_font.mem from font8x16.h: 4096 lines of two hex digits, glyph n
        row r at line n*16 + r (the font RAM of rtl/openaars/adv7511/osd_text.v,
        $readmemh).  --check: compare with the existing file instead of
        writing it (exit 1 on a difference).

    mkfontmem.py --from-charrom [--charrom fw/ctrl/charrom.h] [--font fw/ctrl/font8x16.h]
        font8x16.h from the legacy OSD font charrom.h, doubled vertically
        (the first version of the 8x16 font, findings/osd-redesign/plan.md
        3.3).  charrom.h is 256 glyphs x 8 bytes, each byte one pixel
        COLUMN (byte 0 = left), bit 0 = top row.  font8x16.h is 256 glyphs
        x 16 bytes, each byte one pixel ROW (byte 0 = top), bit 7 = left
        pixel; row r of the 8x16 glyph is row r / 2 of the 8x8 one.

Paths default to the repository layout relative to this script.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
DEF_CHARROM = os.path.join(REPO, "fw", "ctrl", "charrom.h")
DEF_FONT = os.path.join(REPO, "fw", "ctrl", "font8x16.h")
DEF_MEM = os.path.join(REPO, "rtl", "openaars", "adv7511", "osd_font.mem")

ROW_RE = re.compile(r"^\s*\{([^}]*)\}\s*,?\s*(?://(.*))?$")


def parse_rows(path, width):
    """Every '{0x.., ...}' initialiser line of a C table: list of (bytes, comment)."""
    out = []
    with open(path) as f:
        for line in f:
            m = ROW_RE.match(line)
            if not m:
                continue
            vals = [int(v, 0) for v in m.group(1).split(",") if v.strip()]
            if len(vals) != width:
                sys.exit(f"{path}: expected {width} bytes per glyph: {line.strip()}")
            out.append((vals, (m.group(2) or "").strip()))
    if len(out) != 256:
        sys.exit(f"{path}: {len(out)} glyphs, expected 256")
    return out


def charrom_to_8x16(cols):
    """8 column bytes (LSB top) -> 16 row bytes (bit 7 left), rows doubled."""
    rows8 = []
    for r in range(8):
        b = 0
        for c in range(8):
            if (cols[c] >> r) & 1:
                b |= 0x80 >> c
        rows8.append(b)
    return [rows8[r // 2] for r in range(16)]


def glyph_label(n, old_comment):
    # keep charrom.h's description (after "[0x..]"), else the printable char
    m = re.search(r"\[0x[0-9a-fA-F]+\]\s*(.*)$", old_comment)
    desc = m.group(1).strip() if m else ""
    if not desc and 0x21 <= n <= 0x7e:
        desc = "'" + chr(n) + "'"
    return f"0x{n:02x}" + (" " + desc if desc else "")


def write_font_h(path, glyphs):
    with open(path, "w") as f:
        f.write("#ifndef FONT8X16_H\n#define FONT8X16_H\n\n")
        f.write("/*\n"
                " * 8x16 font of the OSD text layer (rtl/openaars/adv7511/osd_text.v).\n"
                " * 256 glyphs x 16 bytes: byte r = pixel row r (0 = top), bit 7 = left\n"
                " * pixel; glyph n row r is font RAM byte n*16 + r.\n"
                " * rtl/openaars/adv7511/osd_font.mem is generated from this file:\n"
                " *   python3 fw/ctrl/tools/mkfontmem.py\n"
                " * First version: charrom.h doubled vertically\n"
                " *   (python3 fw/ctrl/tools/mkfontmem.py --from-charrom).\n"
                " */\n\n")
        f.write("static const unsigned char font8x16[256][16] =\n{\n")
        for n, (rows, label) in enumerate(glyphs):
            body = ",".join(f"0x{b:02X}" for b in rows)
            sep = "," if n < 255 else " "
            f.write(f"        {{{body}}}{sep}  // {label}\n")
        f.write("};\n\n#endif\n")


def write_mem(path, glyphs):
    with open(path, "w") as f:
        for rows, _ in glyphs:
            for b in rows:
                f.write(f"{b:02x}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-charrom", action="store_true", help="write font8x16.h from charrom.h")
    ap.add_argument("--charrom", default=DEF_CHARROM)
    ap.add_argument("--font", default=DEF_FONT)
    ap.add_argument("--out", default=DEF_MEM)
    ap.add_argument("--check", action="store_true", help="compare with --out, do not write")
    a = ap.parse_args()

    if a.from_charrom:
        old = parse_rows(a.charrom, 8)
        glyphs = [(charrom_to_8x16(cols), glyph_label(n, c)) for n, (cols, c) in enumerate(old)]
        write_font_h(a.font, glyphs)
        print(f"wrote {a.font}")
        return

    glyphs = parse_rows(a.font, 16)
    if a.check:
        tmp = []
        for rows, _ in glyphs:
            tmp += [f"{b:02x}\n" for b in rows]
        with open(a.out) as f:
            cur = f.readlines()
        if cur != tmp:
            sys.exit(f"{a.out} differs from {a.font}: run fw/ctrl/tools/mkfontmem.py")
        print(f"{a.out} matches {a.font}")
        return
    write_mem(a.out, glyphs)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
