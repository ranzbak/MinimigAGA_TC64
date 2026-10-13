#!/usr/bin/env python3
"""Checks for scaler_run.sh (findings/scaler/plan.md steps 3-5).

  scl_check.py ring LOG FROM [LAGMIN LAGMAX]
      tb_crt_frame's "ring N:" lines from HD frame FROM on: no read of a
      slot being written, none overwritten during an HD line, no wrong
      line; the lag (the line being written minus the cur line) within
      LAGMIN..LAGMAX (default 2..15: next line complete, cur not yet
      overwritten in a 16-line ring).  Prints the frames' extremes.
"""
import re, sys

def ring(log, frm, lo=2, hi=15):
    rows = []
    for l in open(log):
        m = re.match(r'ring (\d+): (\d+) lines, lag (-?\d+)\.\.(-?\d+), rd-wr (\d+), overwritten (\d+), wrongline (\d+), ratio (\d+) \(top (\d+)\)', l)
        if m and int(m[1]) >= frm:
            rows.append(tuple(int(x) for x in m.groups()))
    if not rows:
        print('no ring lines from frame %d' % frm); return False
    lmin = min(r[2] for r in rows); lmax = max(r[3] for r in rows)
    rw = sum(r[4] for r in rows); ow = sum(r[5] for r in rows); wl = sum(r[6] for r in rows)
    lines = sum(r[1] for r in rows); top = sum(r[8] for r in rows)
    ratio = sorted(set(r[7] for r in rows))
    ok = rw == 0 and ow == 0 and wl == 0 and lmin >= lo and lmax <= hi and min(r[1] for r in rows) >= 600
    print('frames %d..%d, %d HD lines: lag %d..%d (allowed %d..%d), rd-wr %d, overwritten %d, wrongline %d, ratio %s, stale top-line reads %d'
          % (rows[0][0], rows[-1][0], lines, lmin, lmax, lo, hi, rw, ow, wl, ratio, top))
    return ok

if __name__ == '__main__':
    if sys.argv[1] == 'ring':
        a = sys.argv[2:]
        ok = ring(a[0], int(a[1]), *(int(x) for x in a[2:4]))
        sys.exit(0 if ok else 1)
