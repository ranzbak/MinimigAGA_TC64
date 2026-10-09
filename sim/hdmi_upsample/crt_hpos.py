#!/usr/bin/env python3
"""HDMI Video Pos gates (sim/hdmi_upsample/crt_run.sh, legs hpos*).

  crt_hpos.py shift A.hex B.hex N   B is A moved N HD pixels (N < 0: left):
                                    B[y][x] == A[y][x - N] wherever both
                                    columns lie inside the picture window
  crt_hpos.py rows  A.hex B.hex     B has no horizontal move against A:
                                    every non-black row of B is a row of A
                                    (a vertical move is allowed)
"""
import sys
import numpy as np

W, H = 1280, 720


def load(fn):
    with open(fn) as f:
        v = np.array([int(l, 16) for l in f if l.strip()], dtype=np.uint32)
    return v.reshape(H, W)


def window(a):
    """columns that are ever non-black: the active window of the picture"""
    cols = np.nonzero((a != 0).any(axis=0))[0]
    return cols[0], cols[-1]


def shift(a, b, n):
    lo, hi = window(a)
    # both columns x (in B) and x - n (in A) inside A's window, with a
    # margin of 4 px for the window edges themselves
    xs = [x for x in range(W) if lo + 4 <= x - n <= hi - 4 and lo + 4 <= x <= hi - 4]
    if len(xs) < 600:
        return False, "overlap only %d columns" % len(xs)
    xs = np.array(xs)
    d = int((b[:, xs] != a[:, xs - n]).sum())
    nb = int((b[:, xs] != 0).sum())
    ok = d == 0 and nb > 100000
    # where B's picture really is: the best whole-pixel move, for the log
    best = min(range(-300, 301, 1),
               key=lambda m: (b[:, max(0, m):W + min(0, m)] != a[:, max(0, -m):W - max(0, m)]).sum())
    return ok, "%d of %d pixels differ from A moved %+d (best fit %+d)" % (d, b[:, xs].size, n, best)


def rows(a, b):
    ra = {a[y].tobytes() for y in range(H)}
    nz = [y for y in range(H) if b[y].any()]
    miss = [y for y in nz if b[y].tobytes() not in ra]
    ok = len(nz) > 200 and not miss
    return ok, "%d of %d non-black rows are not rows of A" % (len(miss), len(nz))


if __name__ == "__main__":
    if sys.argv[1] == "shift":
        ok, msg = shift(load(sys.argv[2]), load(sys.argv[3]), int(sys.argv[4]))
    else:
        ok, msg = rows(load(sys.argv[2]), load(sys.argv[3]))
    print(msg)
    sys.exit(0 if ok else 1)
