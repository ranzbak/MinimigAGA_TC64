#!/usr/bin/env python3
"""The OSD text layer in the HDMI chain (crt_run.sh legs osd2off, osd2win,
osd2win60; findings/osd-redesign Phase 2).

    osd2_check.py gen <dir> win|off     the layer's data for tb_crt_frame
                                        +osd2=<dir>: cells.hex, font_w.hex,
                                        pal.hex, cfg.hex
    osd2_check.py pins <dir> GEN GEN2 PINS
                                        PINS (the pins, +pins: both bus words
                                        of every pixel) = the model of the
                                        layer over GEN (first words) and GEN2
                                        (second words), pixel for pixel
    osd2_check.py check <dir> GEN OUT   OUT (adv_ddr's input picture, +out)
                                        = the Phase 1 model
                                        (sim/osd_text/model.py render) of
                                        the layer over GEN (the generator's
                                        picture, +osd2gen), pixel for pixel

tb_crt_frame takes a pixel on the clk_148 of adv_ddr's first bus word
under the generator's DE (+out, +osd2gen; +osd2gen's ...b.hex: the next
clock, the second word's): dump column x = pin pixel x = the layer's and
the model's x (osd_text PE_PHASE 1, since 2026-10-28; before, the layer ran
one clock late and the check read column c as x = c - 1).

No stored golden: the expected picture is computed from the frame without
the layer, so the check holds wherever the chain puts the picture.
Window (win): scale 2, 64 x 20 cells at x0 = 16, y0 = 5 (8-pixel units),
i.e. 1024 x 640 at (128, 40) on the generator's raster -- the firmware's
default; off: the same with enable 0.  Random chars and attributes, glyphs
0x80..0xff rewritten, a palette with all four modes.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "osd_text"))
import model  # noqa: E402  (sim/osd_text/model.py: render, rd_hex, wr_hex, FONT_MEM)

WIN = (3, 16, 5, 64, 20)   # ctrl (enable, scale 2), x0, y0, cols, rows


def gen(d, which):
    rnd = random.Random("osd2win")
    os.makedirs(d, exist_ok=True)
    model.wr_hex(os.path.join(d, "cells.hex"), [rnd.randrange(65536) for _ in range(2048)], 4)
    model.wr_hex(os.path.join(d, "font_w.hex"),
                 [(a << 8) | rnd.randrange(256) for a in range(0x800, 0x1000)], 5)
    modes = [i % 4 for i in range(16)]
    rnd.shuffle(modes)
    pal = []
    for m in modes:
        pal += [(m << 6) | rnd.randrange(64), rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)]
    model.wr_hex(os.path.join(d, "pal.hex"), pal, 2)
    ctrl, x0, y0, cols, rows = WIN
    if which == "off":
        ctrl &= ~1
    model.wr_hex(os.path.join(d, "cfg.hex"), [ctrl | (x0 << 8) | (y0 << 16) | (cols << 24) | (rows << 32)], 10)


def check(d, gfile, ofile):
    cells = model.rd_hex(os.path.join(d, "cells.hex"))
    font = model.rd_hex(model.FONT_MEM)
    for w in model.rd_hex(os.path.join(d, "font_w.hex")):
        font[w >> 8] = w & 0xff
    pal = model.rd_hex(os.path.join(d, "pal.hex"))
    cfg = model.rd_hex(os.path.join(d, "cfg.hex"))[0]
    dg, do = model.rd_hex(gfile), model.rd_hex(ofile)
    W, n = model.W, model.W * model.H
    if len(dg) != n or len(do) != n:
        print(f"{len(dg)} generator / {len(do)} output pixels, expected {n}")
        return False
    # dump column x = the model's x
    vin, vout = dg, do
    exp = model.render(vin, cells, font, pal, cfg)
    nwin = sum(1 for a, b in zip(exp, vin) if a != b)
    bad = [i for i in range(n) if exp[i] != vout[i]]
    if bad:
        i = bad[0]
        print(f"{len(bad)} pixels differ from the model, first at x {i % model.W} y {i // model.W}: "
              f"{vout[i]:06x}, expected {exp[i]:06x}")
        return False
    print(f"= model ({nwin} pixels changed by the layer)")
    return nwin > 0 or not (cfg & 1)


def pin_words(fn):
    """The two bus words of every pixel under the pin DE of a tb_crt_frame
    +pins dump (frame_shift.py load_pins: a DE rise shows in sample R, the
    words in R+1, R+3, ...; {r, g[7:4]} with o_clk_pixel low, then
    {g[3:0], b}): two lists of 1280 x 720 words, or a message."""
    with open(fn) as f:
        rows = f.read().split("\n")
    de = [len(r) == 11 and r[2] == "1" for r in rows]
    word = [int(r[8:11], 16) if len(r) == 11 else 0 for r in rows]
    rises = [i for i in range(1, len(de)) if de[i] and not de[i - 1]]
    if de and de[0]:
        rises.insert(0, 0)
    W, H = model.W, model.H
    if len(rises) < H:
        return None, None, f"{len(rises)} DE pulses, expected {H}"
    hi, lo = [0] * (W * H), [0] * (W * H)
    for y, r in enumerate(rises[:H]):
        n = 0
        while r + n < len(de) and de[r + n]:
            n += 1
        if n != 4 * W:
            return None, None, f"DE pulse {y}: {n} samples, expected {4 * W}"
        for x in range(W):
            hi[y * W + x] = word[r + 1 + 4 * x]
            lo[y * W + x] = word[r + 3 + 4 * x]
    return hi, lo, None


def check_pins(d, gfile, gfile2, pfile):
    """BOTH bus words of every pixel at the pins (+pins: what the ADV7511
    gets) = the model of the layer over the generator's picture, pin pixel
    x = GEN column x = model x: the first word {r, g[7:4]} of the model over
    GEN (+osd2gen, the first word's clock), the second {g[3:0], b} of the
    model over GEN2 (+osd2gen's ...b.hex, the next clock; the two differ in
    pin pixel 0, whose first clock signal_generator still blanks).  A layer whose pixels change on the other clk_148 of
    adv_ddr's word pair shows here: one word of the pixel, the other of its
    neighbour (the one-clock-per-pixel +out dump cannot see that)."""
    cells = model.rd_hex(os.path.join(d, "cells.hex"))
    font = model.rd_hex(model.FONT_MEM)
    for w in model.rd_hex(os.path.join(d, "font_w.hex")):
        font[w >> 8] = w & 0xff
    pal = model.rd_hex(os.path.join(d, "pal.hex"))
    cfg = model.rd_hex(os.path.join(d, "cfg.hex"))[0]
    dg, dg2 = model.rd_hex(gfile), model.rd_hex(gfile2)
    W, n = model.W, model.W * model.H
    if len(dg) != n or len(dg2) != n:
        print(f"{len(dg)} / {len(dg2)} generator pixels, expected {n}")
        return False
    hi, lo, err = pin_words(pfile)
    if err:
        print(f"pins: {err}")
        return False
    exp = model.render(dg, cells, font, pal, cfg)
    exp2 = model.render(dg2, cells, font, pal, cfg)
    nwin = sum(1 for a, b in zip(exp, dg) if a != b)
    bh = [i for i in range(n) if hi[i] != exp[i] >> 12]
    bl = [i for i in range(n) if lo[i] != exp2[i] & 0xfff]
    if bh or bl:
        i = min((bh or [n]) + (bl or [n]))
        print(f"pins: {len(bh)} first words ({{r, g[7:4]}}) and {len(bl)} second words ({{g[3:0], b}}) "
              f"differ from the model, first at x {i % W} y {i // W}: words {hi[i]:03x} {lo[i]:03x}, "
              f"expected {exp[i] >> 12:03x} {exp2[i] & 0xfff:03x}")
        return False
    ch = [i for i in range(n) if exp[i] != dg[i]]
    where = (f", at pin x {min(i % W for i in ch)}..{max(i % W for i in ch)}, "
             f"y {ch[0] // W}..{ch[-1] // W}") if ch else ""
    print(f"pins = model, both words of all {n} pixels ({nwin} pixels changed by the layer{where})")
    return nwin > 0 or not (cfg & 1)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3], sys.argv[4]) else 1)
    elif len(sys.argv) == 6 and sys.argv[1] == "pins":
        sys.exit(0 if check_pins(*sys.argv[2:6]) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
