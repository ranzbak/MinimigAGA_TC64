#!/usr/bin/env python3
"""Reference model of rtl/openaars/adv7511/osd_text.v (sim/osd_text).

    model.py gen <leg> <dir>    the leg's data files for osd_text_tb.v
    model.py check <dir>        render frames 1 and 2 from in_<f>.hex and the
                                leg's cells / font / palette / window, write
                                exp_<f>.ppm, out_<f>.ppm (from the bench's
                                out_<f>.hex) and in_<f>.ppm, and compare
                                exp and out byte for byte (exit 1 if not)

The model is the specification of the layer (osd_text.v header,
findings/osd-redesign/plan.md 3.2-3.5): a window of cols x rows cells of
8x16 pixels (16x32 at scale 2) at (x0*8, y0*8), clipped to 1280x720; cell
(c, r) = cell word r*64 + c {attr, char}; glyph bit 7 = left pixel; palette
entry {mode, r, g, b}: 0 colour, 1 video >> 1, 2 video, 3 (colour + video) >> 1.
"""
import os
import random
import sys

W, H = 1280, 720
HERE = os.path.dirname(os.path.abspath(__file__))
FONT_MEM = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "openaars", "adv7511", "osd_font.mem"))

# legs: (cfg A, cfg B), each (ctrl, x0, y0, cols, rows); ctrl bit 0 enable, bit 1 scale 2
LEGS = {
    # A: scale 1, x0 = 0, y0 = 0, 64 x 32 (all 32 rows); B: scale 2, the
    # proposed 64 x 20 menu centred (1024 x 640 at 128, 40)
    "s1full": ((1, 0, 0, 64, 32), (3, 16, 5, 64, 20)),
    # A: scale 2, cut by the right and bottom edges (1120..1600, 400..784);
    # B: scale 1, ends exactly at the right and bottom edges (960..1280, 560..720)
    "edges": ((3, 140, 50, 30, 12), (1, 120, 70, 40, 10)),
    # A: scale 2, cols 200 / rows 100 clamp to 64 x 32 (bottom cut);
    # B: scale 2, 3 x 3 cells at the bottom right corner, 8 x 8 pixels visible
    "clamp": ((3, 0, 0, 200, 100), (3, 159, 89, 3, 3)),
    # odd sizes: A: scale 1, one cell at (8, 8); B: scale 2, 13 x 7 at (8, 16)
    "small": ((1, 1, 1, 1, 1), (3, 1, 2, 13, 7)),
    # 720p60 (bench +hz60: the shorter line): A as s1full's B, B scale 2 cut
    # by the right edge (768..1408)
    "hz60": ((3, 16, 5, 64, 20), (3, 96, 3, 40, 5)),
    # layer off: A disabled with a window set, B enabled with cols 0
    "off": ((2, 0, 0, 64, 32), (3, 0, 0, 0, 20)),
    # bench +vtop=15: the DE starts 15 lines after the frame pulse (the
    # generator's PAL_VT_TOP); the window follows the DE.  A: s1full's B;
    # B: scale 1 at the top edge (y0 = 0) and the bottom rows
    "vtop": ((3, 16, 5, 64, 20), (1, 2, 0, 40, 32)),
}


def rd_hex(path):
    with open(path) as f:
        return [int(l, 16) for l in f.read().split()]


def wr_hex(path, vals, digits):
    with open(path, "w") as f:
        for v in vals:
            f.write(f"{v:0{digits}x}\n")


def gen(leg, d):
    if leg not in LEGS:
        sys.exit(f"unknown leg {leg}: {' '.join(LEGS)}")
    rnd = random.Random("osd_text/" + leg)
    os.makedirs(d, exist_ok=True)
    chars = [rnd.randrange(256) for _ in range(2048)]
    attrs = [rnd.randrange(256) for _ in range(2048)]
    wr_hex(os.path.join(d, "cells_g.hex"), [rnd.randrange(65536) for _ in range(2048)], 4)
    wr_hex(os.path.join(d, "cells_c.hex"), [(rnd.randrange(256) << 8) | c for c in chars], 4)
    wr_hex(os.path.join(d, "cells_a.hex"), [(a << 8) | rnd.randrange(256) for a in attrs], 4)
    wr_hex(os.path.join(d, "cells.hex"), [(a << 8) | c for a, c in zip(attrs, chars)], 4)
    # glyphs 0x80..0xff rewritten through the font port, in a shuffled order
    adrs = list(range(0x800, 0x1000))
    rnd.shuffle(adrs)
    wr_hex(os.path.join(d, "font_w.hex"), [(a << 8) | rnd.randrange(256) for a in adrs], 5)
    for name in ("pal_a.hex", "pal_b.hex"):
        modes = [i % 4 for i in range(16)]
        rnd.shuffle(modes)
        b = []
        for m in modes:
            b += [(m << 6) | rnd.randrange(64), rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)]
        wr_hex(os.path.join(d, name), b, 2)
    cfgs = []
    for ctrl, x0, y0, cols, rows in LEGS[leg]:
        cfgs.append(ctrl | (x0 << 8) | (y0 << 16) | (cols << 24) | (rows << 32))
    wr_hex(os.path.join(d, "cfg.hex"), cfgs, 10)
    with open(FONT_MEM) as f, open(os.path.join(d, "osd_font.mem"), "w") as g:
        g.write(f.read())


def render(vin, cells, font, pal, cfg):
    ctrl, x0, y0, cols, rows = (cfg & 0xff, (cfg >> 8) & 0xff, (cfg >> 16) & 0xff,
                                (cfg >> 24) & 0xff, (cfg >> 32) & 0xff)
    en, s2 = ctrl & 1, (ctrl >> 1) & 1
    cw, chh = 8 << s2, 16 << s2
    X0, Y0 = x0 * 8, y0 * 8
    X1, Y1 = X0 + min(cols, 64) * cw, Y0 + min(rows, 32) * chh
    entries = []
    for i in range(16):
        m = pal[4 * i] >> 6
        entries.append((m, pal[4 * i + 1], pal[4 * i + 2], pal[4 * i + 3]))
    out = list(vin)
    if not en:
        return out
    for y in range(max(Y0, 0), min(Y1, H)):
        dy = y - Y0
        r, gl = dy // chh, (dy % chh) >> s2
        for x in range(max(X0, 0), min(X1, W)):
            dx = x - X0
            c, gc = dx // cw, (dx % cw) >> s2
            word = cells[r * 64 + c]
            bit = (font[(word & 0xff) * 16 + gl] >> (7 - gc)) & 1
            idx = (word >> 8) & 15 if bit else word >> 12
            m, pr, pg, pb = entries[idx]
            v = vin[y * W + x]
            vr, vg, vb = v >> 16, (v >> 8) & 0xff, v & 0xff
            if m == 0:
                o = (pr, pg, pb)
            elif m == 1:
                o = (vr >> 1, vg >> 1, vb >> 1)
            elif m == 2:
                o = (vr, vg, vb)
            else:
                o = ((pr + vr) >> 1, (pg + vg) >> 1, (pb + vb) >> 1)
            out[y * W + x] = (o[0] << 16) | (o[1] << 8) | o[2]
    return out


def ppm(path, pix):
    b = bytearray(b"P6\n%d %d\n255\n" % (W, H))
    for p in pix:
        b += bytes(((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff))
    with open(path, "wb") as f:
        f.write(b)
    return bytes(b)


def check(d):
    cells = rd_hex(os.path.join(d, "cells.hex"))
    font = rd_hex(os.path.join(d, "osd_font.mem"))
    for w in rd_hex(os.path.join(d, "font_w.hex")):
        font[w >> 8] = w & 0xff
    pals = [rd_hex(os.path.join(d, n)) for n in ("pal_a.hex", "pal_b.hex")]
    cfgs = rd_hex(os.path.join(d, "cfg.hex"))
    ok = True
    for f in (1, 2):
        vin = rd_hex(os.path.join(d, f"in_{f}.hex"))
        vout = rd_hex(os.path.join(d, f"out_{f}.hex"))
        if len(vin) != W * H or len(vout) != W * H:
            print(f"  frame {f}: {len(vin)} input / {len(vout)} output pixels, expected {W * H}")
            ok = False
            continue
        exp = render(vin, cells, font, pals[f - 1], cfgs[f - 1])
        ppm(os.path.join(d, f"in_{f}.ppm"), vin)
        be = ppm(os.path.join(d, f"exp_{f}.ppm"), exp)
        bo = ppm(os.path.join(d, f"out_{f}.ppm"), vout)
        if be == bo:
            nwin = sum(1 for a, b in zip(exp, vin) if a != b)
            print(f"  frame {f}: identical ({nwin} pixels differ from the input)")
        else:
            bad = [i for i in range(W * H) if exp[i] != vout[i]]
            i = bad[0]
            print(f"  frame {f}: {len(bad)} pixels differ, first at x {i % W} y {i // W}: "
                  f"{vout[i]:06x}, expected {exp[i]:06x}")
            ok = False
    return ok


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2]) else 1)
    elif len(sys.argv) == 2 and sys.argv[1] == "legs":
        print(" ".join(LEGS))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
