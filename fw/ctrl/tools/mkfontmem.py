#!/usr/bin/env python3
"""The OSD text layer's 8x16 font: one source, two outputs.

    mkfontmem.py [--bdf B] [--symbols S] [--icons I] [--font F] [--out M]
        fw/ctrl/font8x16.h (the firmware's copy, the ROM font the About and
        Supporters pages restore from) and rtl/openaars/adv7511/osd_font.mem
        (the RTL font RAM's $readmemh image: 4096 lines of two hex digits,
        glyph n row r at line n*16 + r) from the same glyphs.
    mkfontmem.py --check
        both made in memory and compared with the files (exit 1 on a
        difference; fw/ctrl make check (l)).
    mkfontmem.py --png F
        only a preview: the 256 glyphs in a 16 x 16 grid at scale 2 (PIL).

The glyphs (256 x 16 bytes, byte r = pixel row r, 0 = top, bit 7 = the left
pixel) come from three sources:
  0x20-0x7E  Spleen 8x16 (fw/ctrl/font/spleen-8x16.bdf, as released, BSD-2-
             Clause: fw/ctrl/font/LICENSE.spleen, repeated in font8x16.h)
  osd_icons.h  the glyphs the menu (ui.c ui_glyphs) uploads when it opens:
             osd_glyphs[] (lines, corners, the change and submenu arrows), the
             value bar OSD_G_BAR0.. (computed here as ui_glyphs computes it)
             and the category icons osd_icons[] at OSD_ICON_MAIN.. (each a
             left and a right glyph), so the ROM font is the font RAM of an
             open menu
  fw/ctrl/font/symbols.txt  the rest that is not blank (stripes, up/down
             arrows, padlocks, the note, the block); drawn for this project
A code given twice is an error.  Every other code is blank: 0x80-0xBF and
0xCA-0xFF are the About and Supporters pages' slots (ui.h), so Latin-1 is
left out.

Paths default to the repository layout relative to this script.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
CTRL = os.path.join(REPO, "fw", "ctrl")
DEF_BDF = os.path.join(CTRL, "font", "spleen-8x16.bdf")
DEF_LICENSE = os.path.join(CTRL, "font", "LICENSE.spleen")
DEF_SYMBOLS = os.path.join(CTRL, "font", "symbols.txt")
DEF_ICONS = os.path.join(CTRL, "osd_icons.h")
DEF_FONT = os.path.join(CTRL, "font8x16.h")
DEF_MEM = os.path.join(REPO, "rtl", "openaars", "adv7511", "osd_font.mem")

ASCII = range(0x20, 0x7F)


def die(msg):
    sys.exit("mkfontmem.py: " + msg)


def read_bdf(path):
    """{code: (16 rows, name)} of the BDF's glyphs with an 8 x 16 box"""
    out = {}
    fbb = None
    code = name = bbx = rows = None
    with open(path, encoding="ascii") as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "FONTBOUNDINGBOX":
                fbb = [int(v) for v in t[1:5]]
            elif t[0] == "STARTCHAR":
                name = " ".join(t[1:])
            elif t[0] == "ENCODING":
                code = int(t[1])
            elif t[0] == "BBX":
                bbx = [int(v) for v in t[1:5]]
            elif t[0] == "BITMAP":
                rows = []
            elif t[0] == "ENDCHAR":
                if fbb != [8, 16, 0, -4] or bbx is None:
                    die(f"{path}: {name}: not an 8 x 16 cell font")
                # every glyph fills the cell: 16 rows of one byte, the top first
                if bbx != fbb or len(rows) != 16 or any(len(r) != 2 for r in rows):
                    die(f"{path}: {name}: not a full 8 x 16 cell")
                out[code] = ([int(r, 16) for r in rows], name)
                code = name = bbx = rows = None
            elif rows is not None:
                rows.append(t[0])
    return out


def read_symbols(path):
    """{code: (16 rows, name)} of symbols.txt"""
    out = {}
    with open(path, encoding="ascii") as f:
        lines = [l.rstrip("\n") for l in f]
    i = 0
    while i < len(lines):
        l = lines[i].strip()
        i += 1
        if not l or l.startswith("# ") or l == "#":
            continue
        m = re.match(r"glyph\s+0x([0-9A-Fa-f]{2})\s+(.*)$", l)
        if not m:
            die(f"{path}:{i}: expected 'glyph 0xNN name': {l}")
        code, name = int(m.group(1), 16), m.group(2).strip()
        rows = []
        for k in range(16):
            r = lines[i + k].strip() if i + k < len(lines) else ""
            if not re.fullmatch(r"[#.]{8}", r):
                die(f"{path}:{i + k + 1}: glyph 0x{code:02X}: row {k} is not 8 of '#' '.': {r!r}")
            rows.append(int(r.replace("#", "1").replace(".", "0"), 2))
        i += 16
        if code in out:
            die(f"{path}: glyph 0x{code:02X} twice")
        out[code] = (rows, name)
    return out


def read_icons(path):
    """{code: (16 rows, name)}: osd_icons.h's glyphs, the bar, the icons"""
    with open(path, encoding="ascii") as f:
        text = f.read()

    def define(n):
        m = re.search(r"#define\s+" + n + r"\s+(0x[0-9A-Fa-f]+|\d+)", text)
        if not m:
            die(f"{path}: no #define {n}")
        return int(m.group(1), 0)

    def block(start):
        a = text.find(start)
        if a < 0:
            die(f"{path}: no '{start}'")
        return text[a:text.index("\n};", a)]

    def no_comments(s):
        return re.sub(r"/\*.*?\*/", "", s, flags=re.S)

    out = {}

    def put(code, rows, name):
        if code in out:
            die(f"{path}: glyph 0x{code:02X} twice")
        out[code] = (rows, name)

    # osd_glyphs[]: { code, { 16 rows } }, a comment before each names it
    body = block("static const struct osd_glyph osd_glyphs[]")
    for m in re.finditer(r"/\*\s*(0x[0-9A-Fa-f]{2})\s+([^*]*?)\s*\*/\s*\{\s*(0x[0-9A-Fa-f]{2})\s*,\s*\{(.*?)\}\s*\}",
                         body, re.S):
        rows = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{2})", no_comments(m.group(4)))]
        if len(rows) != 16 or int(m.group(1), 16) != int(m.group(3), 16):
            die(f"{path}: osd_glyphs {m.group(3)}: {len(rows)} rows, comment {m.group(1)}")
        put(int(m.group(3), 16), rows, m.group(2))
    if len(out) != len(re.findall(r"\{\s*0x[0-9A-Fa-f]{2}\s*,\s*\{", body)):
        die(f"{path}: an osd_glyphs entry without its '/* 0xNN NAME' comment")

    # the value bar: ui.c ui_glyphs, k/8 of the cell from the left, rows 3-12
    bar0, bars = define("OSD_G_BAR0"), define("OSD_G_BARS")
    for k in range(bars):
        put(bar0 + k, [((0xff00 >> k) & 0xff) if 3 <= r <= 12 else 0 for r in range(16)],
            f"OSD_G_BAR0 + {k}: the value bar, {k}/8")

    # osd_icons[n][16]: 16 x 16, the high byte the left glyph
    icon0 = define("OSD_ICON_MAIN")
    body = no_comments(block("static const unsigned short osd_icons["))
    icons = re.findall(r"\{([^{}]*)\}", body[body.index("=") + 1:])
    names = ("Main", "Storage", "System", "Video", "Acceleration")
    for n, ic in enumerate(icons):
        rows = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{4})", ic)]
        if len(rows) != 16:
            die(f"{path}: osd_icons[{n}]: {len(rows)} rows")
        nm = names[n] if n < len(names) else str(n)
        put(icon0 + 2 * n, [r >> 8 for r in rows], f"OSD_ICON_MAIN + {2 * n}: {nm} icon, left")
        put(icon0 + 2 * n + 1, [r & 0xff for r in rows], f"OSD_ICON_MAIN + {2 * n + 1}: {nm} icon, right")
    return out


def build(a):
    bdf = read_bdf(a.bdf)
    glyphs = [([0] * 16, "") for _ in range(256)]
    owner = {}

    def take(src, what):
        for code, (rows, name) in sorted(src.items()):
            if code in owner:
                die(f"glyph 0x{code:02X} from {what} and from {owner[code]}")
            owner[code] = what
            glyphs[code] = (rows, name)

    missing = [c for c in ASCII if c not in bdf]
    if missing:
        die(f"{a.bdf}: no glyph for {', '.join('0x%02X' % c for c in missing)}")
    take({c: (bdf[c][0], "'" + chr(c) + "'" if c != 0x20 else "space") for c in ASCII}, "Spleen")
    take(read_icons(a.icons), "osd_icons.h")
    take(read_symbols(a.symbols), "symbols.txt")
    return glyphs


def font_h(glyphs, license_text):
    lic = "".join(" *   " + l if l.strip() else " *\n" for l in license_text.splitlines(True))
    s = ["#ifndef FONT8X16_H\n#define FONT8X16_H\n\n",
         "/*\n"
         " * 8x16 font of the OSD text layer (rtl/openaars/adv7511/osd_text.v): the\n"
         " * ROM font.  256 glyphs x 16 bytes: byte r = pixel row r (0 = top), bit 7 =\n"
         " * the left pixel; glyph n row r is font RAM byte n*16 + r.\n"
         " *\n"
         " * GENERATED, do not edit: python3 fw/ctrl/tools/mkfontmem.py writes this\n"
         " * file and rtl/openaars/adv7511/osd_font.mem (the RTL font RAM's initial\n"
         " * content) from the same glyphs; make -C fw/ctrl check (l) verifies both.\n"
         " * Sources: 0x20-0x7E Spleen 8x16 (fw/ctrl/font/spleen-8x16.bdf); the\n"
         " * menu's glyphs from osd_icons.h (lines, corners, arrows, the value bar,\n"
         " * the category icons, at the codes ui.c uploads them to); the other\n"
         " * symbols from fw/ctrl/font/symbols.txt.  0x80-0xBF, 0xCA-0xFF blank:\n"
         " * the About and Supporters pages' glyph slots.\n"
         " *\n"
         " * The Spleen glyphs (0x20-0x7E) are under the BSD 2-Clause license\n"
         " * (fw/ctrl/font/LICENSE.spleen):\n"
         " *\n" + lic +
         " */\n\n",
         "static const unsigned char font8x16[256][16] =\n{\n"]
    for n, (rows, label) in enumerate(glyphs):
        body = ",".join(f"0x{b:02X}" for b in rows)
        sep = "," if n < 255 else " "
        s.append(f"        {{{body}}}{sep}  // 0x{n:02x}" + (" " + label if label else "") + "\n")
    s.append("};\n\n#endif\n")
    return "".join(s)


def font_mem(glyphs):
    return "".join(f"{b:02x}\n" for rows, _ in glyphs for b in rows)


def font_png(glyphs, path, scale=2):
    """a preview: the 256 glyphs in a 16 x 16 grid at scale 2, white on black,
    one grey pixel line between the cells (needs PIL)"""
    from PIL import Image
    cw, ch = 8 * scale + 1, 16 * scale + 1
    im = Image.new("RGB", (16 * cw + 1, 16 * ch + 1), (90, 90, 90))
    px = im.load()
    for n, (rows, _) in enumerate(glyphs):
        x0, y0 = (n % 16) * cw + 1, (n // 16) * ch + 1
        for y in range(16 * scale):
            for x in range(8 * scale):
                on = rows[y // scale] & (0x80 >> (x // scale))
                px[x0 + x, y0 + y] = (240, 240, 240) if on else (0, 0, 0)
    im.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bdf", default=DEF_BDF)
    ap.add_argument("--license", default=DEF_LICENSE)
    ap.add_argument("--symbols", default=DEF_SYMBOLS)
    ap.add_argument("--icons", default=DEF_ICONS)
    ap.add_argument("--font", default=DEF_FONT)
    ap.add_argument("--out", default=DEF_MEM)
    ap.add_argument("--check", action="store_true", help="compare with --font and --out, do not write")
    ap.add_argument("--png", help="write only a preview of the font to this PNG file (PIL)")
    a = ap.parse_args()

    glyphs = build(a)
    if a.png:
        font_png(glyphs, a.png)
        print(f"wrote {a.png}")
        return
    with open(a.license, encoding="ascii") as f:
        outs = [(a.font, font_h(glyphs, f.read())), (a.out, font_mem(glyphs))]
    if a.check:
        bad = 0
        for path, want in outs:
            try:
                with open(path, encoding="ascii") as f:
                    have = f.read()
            except OSError as e:
                have = None
                print(f"{path}: {e.strerror}")
            if have != want:
                print(f"{os.path.relpath(path, REPO)} is not mkfontmem.py's output: run python3 fw/ctrl/tools/mkfontmem.py")
                bad = 1
        if bad:
            sys.exit(1)
        print(f"{os.path.relpath(a.font, REPO)} and {os.path.relpath(a.out, REPO)} are mkfontmem.py's output")
        return
    for path, text in outs:
        with open(path, "w", encoding="ascii") as f:
            f.write(text)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
