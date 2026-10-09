#!/usr/bin/env python3
"""HDMI Video Pos VPOS gates (sim/hdmi_upsample/crt_run.sh, legs vpos*).

VPOS moves the picture by whole 64 us steps (one 15 kHz input line) of the
HD raster's restart against the input: positive down, negative up.  One step
is RPL HD lines: the input line over the HD line, 7264 clk_114 at
113.4375 MHz over (H_TOTAL + 1) HD pixels at 74.25 MHz (signal_generator.sv
counts 0 .. H_TOTAL) -- 2.40011 at 50 Hz (1980 + 1), 2.87985 on the 60 Hz
path (1650 + 1) with the bench's PAL source.

  crt_vpos.py shift A.hex B.hex S HZ   B is A (VPOS 0) moved S steps: every
                                       non-black row y of B equals row
                                       floor(y - e) or ceil(y - e + 0.01)
                                       of A,
                                       e = S * RPL, where that row is one of
                                       A's live rows; the best whole-row fit
                                       lies within 1 of e

Live rows: from 4 input lines (+1 HD line) below the top -- the read side
starts four buffers behind the write side, so each frame's top four input
lines show buffers written before the restart, which hold other lines in B
than in A (and, after a frame of another length, other ones than in the
frame before) -- to the bottom.  Only rows live in both A and B are checked
(at least 500); rows of B that land outside A show lines A never shows.
  crt_vpos.py where A.hex B.hex HZ LO HI   which step k in LO..HI B is A
                                       moved by (the clean fit as above,
                                       exactly one k); prints "at k" or
                                       "unclean"
  crt_vpos.py same A.hex B.hex T       A and B identical below the top T rows
"""
import math
import sys
import numpy as np

W, H = 1280, 720
T_IN = 7264 / 113.4375e6
RPL = {50: T_IN / (1981 / 74.25e6), 60: T_IN / (1651 / 74.25e6)}


def load(fn):
    with open(fn) as f:
        v = np.array([int(l, 16) for l in f if l.strip()], dtype=np.uint32)
    return v.reshape(H, W)


def check(a, b, e, rpl):
    """rows of B that are not A moved e rows; (bad rows, non-black rows checked)"""
    rows_a = [a[y].tobytes() for y in range(H)]
    top = math.ceil(4 * rpl) + 1
    bad = []
    nz = 0
    for y in range(H):
        # a virtual restart reaches clk_148 a few clocks after the real one
        # would (toggle synchroniser): B's raster may run up to 0.01 HD line
        # late, so an exact move (integer e) may show the next row once
        lo, hi = math.floor(y - e), math.ceil(y - e + 0.01)
        if not b[y].any() or y < top or lo < top or hi >= H:
            continue
        nz += 1
        k = b[y].tobytes()
        if k != rows_a[lo] and k != rows_a[hi]:
            bad.append(y)
    return bad, nz


def best(a, b):
    """the whole-row move of A that matches the most non-black rows of B"""
    def score(d):
        return sum(1 for y in range(max(0, d), min(H, H + d))
                   if b[y].any() and (b[y] == a[y - d]).all())
    return max(range(-80, 81), key=score)


def shift(a, b, s, hz):
    e = s * RPL[hz]
    bad, nz = check(a, b, e, RPL[hz])
    d = best(a, b)
    ok = not bad and nz >= 500 and math.floor(e) - 1 <= d <= math.ceil(e) + 1
    msg = "VPOS %+d at %d Hz: expected move %+.2f HD lines, best fit %+d, %d of %d non-black rows off%s" % (
        s, hz, e, d, len(bad), nz, (" (first %s)" % bad[:5]) if bad else "")
    return ok, msg


def where(a, b, hz, lo, hi):
    hits = [k for k in range(lo, hi + 1) if not check(a, b, k * RPL[hz], RPL[hz])[0]]
    if len(hits) == 1:
        return True, "at %d" % hits[0]
    return False, "unclean %s (best fit %+d rows)" % (hits, best(a, b))


if __name__ == "__main__":
    a, b = load(sys.argv[2]), load(sys.argv[3])
    if sys.argv[1] == "same":
        t = int(sys.argv[4])
        n = int((a[t:] != b[t:]).any(axis=1).sum())
        ok, msg = n == 0, "%d rows below row %d differ" % (n, t)
    elif sys.argv[1] == "shift":
        ok, msg = shift(a, b, int(sys.argv[4]), int(sys.argv[5]))
    else:
        ok, msg = where(a, b, int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))
    print(msg)
    sys.exit(0 if ok else 1)
