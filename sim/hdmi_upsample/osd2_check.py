#!/usr/bin/env python3
"""The OSD text layer in the HDMI chain (crt_run.sh legs osd2off, osd2win,
osd2win60; findings/osd-redesign Phase 2).

    osd2_check.py gen <dir> win|off     the layer's data for tb_crt_frame
                                        +osd2=<dir>: cells.hex, font_w.hex,
                                        pal.hex, cfg.hex
    osd2_check.py check <dir> GEN OUT   OUT (adv_ddr's input picture, +out)
                                        = the Phase 1 model
                                        (sim/osd_text/model.py render) of
                                        the layer over GEN (the generator's
                                        picture, +osd2gen), pixel for pixel

tb_crt_frame takes a pixel on the second clk_148 of its pixel clock with
the generator's DE, which rises one clock before the picture: dump column c
is generator pixel x = c - 1 (column 0 is the blank pixel before the line,
generator x 1279 is not dumped).  The check realigns both dumps to
generator coordinates (the model's) and compares x 0..1278.

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
    # dump column c = generator x c - 1: x = column + 1, x 1279 left 0 in both
    vin, vout = [0] * n, [0] * n
    for y in range(model.H):
        vin[y * W:y * W + W - 1] = dg[y * W + 1:y * W + W]
        vout[y * W:y * W + W - 1] = do[y * W + 1:y * W + W]
    exp = model.render(vin, cells, font, pal, cfg)
    for y in range(model.H):
        exp[y * W + W - 1] = vout[y * W + W - 1]
    nwin = sum(1 for a, b in zip(exp, vin) if a != b)
    bad = [i for i in range(n) if exp[i] != vout[i]]
    if bad:
        i = bad[0]
        print(f"{len(bad)} pixels differ from the model, first at x {i % model.W} y {i // model.W}: "
              f"{vout[i]:06x}, expected {exp[i]:06x}")
        return False
    print(f"= model ({nwin} pixels changed by the layer)")
    return nwin > 0 or not (cfg & 1)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3], sys.argv[4]) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
