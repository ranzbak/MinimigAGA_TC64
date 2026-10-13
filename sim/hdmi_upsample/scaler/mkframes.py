#!/usr/bin/env python3
"""Amiga source frames for the scaler legs (tb_crt_frame +frame=): the
scaler study's native test frame (frames.native_frame: lowres WB1.3 GUI |
hires WB3 GUI, pixel art | real 16-colour picture, 1-px line test | colour
test with red/green lines), on the bench's superhires grid.

  mkframes.py OUTDIR    OUTDIR/scaler_pal.hex   native_frame(288) at input
                                                lines 24..311 (PAL window)
                        OUTDIR/scaler_ntsc.hex  native_frame(240) at input
                                                lines 22..261 (NTSC window)
                        OUTDIR/scaler_{pal,ntsc}_src.png  the 720-wide frames

Each 720-px row is hires: one pixel = 2 superhires samples, from lowres
hpos 92 (sample 368) to sample 1808 (hblank is lowres 13..88).  Lines and
columns outside are black (border 0), and so is the vertical blank (PAL
lines 0..25, NTSC 0..20: Agnus blanks them), which takes the PAL frame's
first two rows.  312 lines x 1816 samples, RRGGBB.
"""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import frames

W, H = 1816, 312
X0 = 92 * 4
WIN = {'pal': (288, 24), 'ntsc': (240, 22)}
VBLANK = {'pal': 26, 'ntsc': 21}

def amiga(img, y0):
    a = np.zeros((H, W, 3), np.uint8)
    n = img.shape[0]
    a[y0:y0 + n, X0:X0 + 2 * img.shape[1]] = np.repeat(img, 2, axis=1)
    return a

def write_hex(a, fn):
    v = (a[..., 0].astype(np.uint32) << 16) | (a[..., 1].astype(np.uint32) << 8) | a[..., 2]
    with open(fn, 'w') as f:
        f.write('\n'.join('%06x' % x for x in v.ravel()))
        f.write('\n')

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    for k, (n, y0) in WIN.items():
        img, _ = frames.native_frame(n)
        Image.fromarray(img).save(os.path.join(out, 'scaler_%s_src.png' % k))
        a = amiga(img, y0)
        a[:VBLANK[k]] = 0
        write_hex(a, os.path.join(out, 'scaler_%s.hex' % k))
        print('scaler_%s.hex: %d lines at input line %d' % (k, n, y0))
