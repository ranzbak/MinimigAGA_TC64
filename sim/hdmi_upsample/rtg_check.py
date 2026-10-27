#!/usr/bin/env python3
"""RTG 1:1 gate for scaler_run.sh (the rtg* legs; tb_crt_frame +rtg720*).

  rtg_check.py W DX ONCE PREFIX FRAME [FRAME ...]

PREFIX_<FRAME>.hex are tb_crt_frame +out= dumps (1280x720, RRGGBB per
line) of an RTG source whose pixel (x, y) is 800000 | y << 11 | x and
whose lines are W pixels wide.  Every HD pixel (x, r) must be the source
pixel (x - x0 - DX, r - y0), x0 = (1280 - W) // 2 (W > 1280: a centred
crop), and black where that pixel lies outside the source (the columns
outside W, and the rows outside 0..719).  DX is the horizontal offset the
leg expects (0; 1 where the source's pixel latency is one more than the
write side's tap: the first column black, the last pixel lost).  y0 is
taken from the first frame and must be the same in every frame.  ONCE 1:
every source line 0..719 appears in exactly one HD row of every frame (no
line dropped or repeated: y0 = 0).  Prints x0, y0, the frames; exit 1 on
any mismatch, with the first few.
HD column 0 is black in every mode, RTG or not: signal_generator.sv gates
its data with hz_region_act, the register DE comes from, one clk_148 after
DE rises -- the window's first pixel is sampled before the gate opens
(outside this gate's reach; the column is expected black here).
"""
import sys
import numpy as np


def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32)
    if a.size != 1280 * 720:
        raise ValueError('%s: %d pixels, not 1280x720' % (fn, a.size))
    return a.reshape(720, 1280)


def describe(a):
    """what a row in the middle shows: lit columns and the source x there"""
    r = 360
    lit = np.nonzero(a[r] & 0x800000)[0]
    if lit.size == 0:
        return 'row %d black' % r
    sx = a[r, lit] & 0x7FF
    return 'row %d: lit HD x %d..%d (%d), source x %d..%d (%d distinct), source y %d' % (
        r, lit[0], lit[-1], lit.size, sx.min(), sx.max(), np.unique(sx).size,
        (a[r, lit[0]] >> 11) & 0x3FF)


def main():
    w, dx, once, prefix = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    frames = [int(f) for f in sys.argv[5:]]
    x0 = (1280 - w) // 2
    hx = np.arange(1280)
    sx = hx - x0 - dx                         # the source column each HD column shows
    colok = (sx >= 0) & (sx < w - dx)         # ... written (DX > 0: the last DX lost)
    colok[0] = False                          # the generator's first pixel (above)
    y0 = None
    bad = []
    for f in frames:
        a = load('%s_%d.hex' % (prefix, f))
        lit = np.argwhere(a & 0x800000)
        if lit.size == 0:
            bad.append('frame %d: black' % f)
            continue
        r, c = lit[0]
        fy0 = int(r) - int((a[r, c] >> 11) & 0x3FF)
        if y0 is None:
            y0 = fy0
        sy = np.arange(720) - y0
        rowok = (sy >= 0) & (sy < 720)
        exp = np.where(rowok[:, None] & colok[None, :],
                       0x800000 | (np.clip(sy, 0, 1023)[:, None] << 11) | np.clip(sx, 0, 2047)[None, :],
                       0).astype(np.uint32)
        d = np.argwhere(a != exp)
        if d.size:
            first = ', '.join('(%d,%d) %06x want %06x' % (x, y, a[y, x], exp[y, x]) for y, x in d[:4])
            bad.append('frame %d: %d pixels differ (y0 here %d), first %s; %s' % (f, len(d), fy0, first, describe(a)))
        if once:
            ys = [int((a[rr, np.nonzero(a[rr] & 0x800000)[0][0]] >> 11) & 0x3FF)
                  for rr in range(720) if (a[rr] & 0x800000).any()]
            cnt = np.bincount(np.array(ys, dtype=np.int64), minlength=1024)[:720]
            if len(ys) != 720 or not (cnt == 1).all():
                miss = np.nonzero(cnt == 0)[0]
                rep = np.nonzero(cnt > 1)[0]
                bad.append('frame %d: %d lit rows, source lines missing %s, repeated %s' % (
                    f, len(ys), list(miss[:6]), list(rep[:6])))
    head = 'W %d x0 %d dx %d y0 %s frames %s' % (w, x0, dx, y0, ','.join(map(str, frames)))
    if bad:
        print(head + ': ' + '; '.join(bad[:3]))
        sys.exit(1)
    print(head + ': every pixel 1:1' + (', every source line once' if once else ''))


if __name__ == '__main__':
    main()
