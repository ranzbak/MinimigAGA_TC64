#!/usr/bin/env python3
"""Checks for scaler_run.sh (findings/scaler/plan.md steps 3-5).

  scl_check.py ring LOG FROM [LAGMIN LAGMAX [notime]]
      tb_crt_frame's "ring N:" lines from HD frame FROM on: no read of a
      slot being written, none overwritten during an HD line, no wrong
      line; the lag (the line being written minus the cur line) within
      LAGMIN..LAGMAX (default 2..15: next line complete, cur not yet
      overwritten in a 16-line ring), and in time (the write side's
      position inside its line counted) >= LAGMIN at the line's first read
      and < LAGMAX + 1 at its last (not with a 5th argument 'notime': in
      the line-rate mode the vsync lines do not start buffers, so the time
      since the last one says nothing there).  Prints the frames' extremes.
  scl_check.py geom PHASEFILE FRAME HZ Y0 [TOL]
      the exact-ratio stepping in HD frame FRAME (tb_crt_frame +out's
      PREFIX_phase.txt): every active HD line in the ratio mode, y steps
      exactly 2/5 (HZ 50) or 1/3 (HZ 60) line per HD line (the RTL's
      2^-20 fixed point: 419430 / 349525), and the absolute source position
      of HD row 0's centre (cur line's vcnt + frac(y) + 0.5, extrapolated
      from the first row with a >= 0) is Y0 +- TOL (default 0.002), modulo
      the field (312 / 262 lines: with VPOS the window may start in the
      field before).
  scl_check.py lin UNITLOG
      tb_crt_post_unit's "lin" lines (the linear-light blend, every kernel
      of both tables, 16 phases, 6 value pairs each): the output equals
      scl_mkroms.py's bit-exact model (decode, weights, rounding, encode)
      in all three channels.
  scl_check.py rows REF.hex REFPHASE X.hex XPHASE FRAME
      the exact-ratio picture (crt_post's vertical effects off: each HD row
      shows line a = floor(y)) against a line-rate picture of the same
      source: every HD row of X with a >= 0 equals a row of REF that shows
      the same source line (tb phase file: cur vcnt), rows with a < 0 are
      black.  So the ring hands over the line the stepping asks for, and
      the write side samples it as in the line-rate mode.  With the
      linear-light blend (step 5) only the rows whose weight is 1.0 on line a
      (Scaling sharp: 2 of every 5 at 2.5x) are compared: they also show
      that the exact-ratio picture sits where the line-rate one does
      sideways (the linear path's 3 extra pixels taken back), and that
      decode -> encode returns every code.  (Reference rows:
      the line-rate picture's rows 10..718; source lines it does not show
      are counted, not checked.)
"""
import re, sys
import numpy as np

STEP = {50: 419430, 60: 349525}

# the picture's row 0 is HD line TOP of the frame (pal_to_ddr.sv's generator
# window, PAL_VT_TOP, since 2026-10-27); geom keeps the frame's lines (its
# wanted y0 is the y of the frame's line 0, RATIO_YB)
TOP = 15

def phases(fn, frame, top=0):
    """per HD line: f h phase hires vphase ratio y cur next, keyed h - top
    (h: the frame's line, line starts since the restart)"""
    out = {}
    for l in open(fn):
        f = l.split()
        if int(f[0]) == frame:
            out[int(f[1]) - top] = [int(x) for x in f[2:]]
    return out

def geom(fn, frame, hz, y0w, tol=0.002):
    p = phases(fn, frame)
    rows = sorted(j for j in p if 0 <= j < 720 and p[j][3] == 1)
    if len(rows) < 700:
        print('frame %d: %d HD lines in the ratio mode' % (frame, len(rows))); return False
    bad = [j for j in rows[1:] if j - 1 in p and p[j][4] - p[j - 1][4] != STEP[hz]]
    ys = [(j, p[j][5] + (p[j][4] & 0xFFFFF) / 2 ** 20 + 0.5) for j in rows if p[j][4] >= 0]
    j1, yy = ys[0]
    y0 = yy - j1 * STEP[hz] / 2 ** 20
    last = int(ys[-1][1] - 0.5)
    L = 312 if hz == 50 else 262          # VPOS can put the window into the field before
    d = (y0 - y0w + L / 2) % L - L / 2
    ok = not bad and abs(d) <= tol
    print('frame %d: %d HD lines stepping %d/2^20 = %.6f line (%s), row 0 centre at source line %.4f (want %.4f), rows %d..719 from source lines %d..%d'
          % (frame, len(rows), STEP[hz], STEP[hz] / 2 ** 20, 'all' if not bad else '%d off, first at %d' % (len(bad), bad[0]),
             y0, y0w, j1, p[j1][5], last))
    return ok

def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32)
    return a.reshape(720, 1280)

def rows(ref, refph, x, xph, frame, hz=50):
    R, X = load(ref), load(x)
    pr, px = phases(refph, frame, TOP), phases(xph, frame, TOP)   # keyed by picture row
    byline = {}
    # reference rows: not the line-rate picture's top rows (they show
    # buffers written before the restart, whatever the bookkeeping says)
    # nor its last (cut by the restart)
    for j in range(10, 719):
        if j in pr:
            byline.setdefault(pr[j][5], set()).add(R[j].tobytes())
    bad = black = ok = nolook = blended = 0
    for j in range(720):
        if j not in px: continue
        a = px[j][4] >> 20
        if a == -1 and px[j][3] == 1:
            import scl_mkroms as RM
            if RM.qweights(0 if hz == 50 else 1, 0, px[j][2])[1] != 0:
                blended += 1; continue       # black blended with the window's first line
        if a < 0:
            black += 1
            if X[j].any(): bad += 1
            continue
        if px[j][3] == 1:
            # the linear-light blend (step 5): only rows that take the cur
            # line alone (sharp: weight 1.0 on line a) are the line-rate row
            import scl_mkroms as RM
            q0, q1 = RM.qweights(0 if hz == 50 else 1, 0, px[j][2])
            if q1 != 0:
                blended += 1; continue
        want = byline.get(px[j][5])
        if want is None: nolook += 1; continue
        if X[j].tobytes() in want: ok += 1
        else: bad += 1
    print('frame %d: %d rows = the line-rate rows of their source line, %d black (a < 0), %d wrong, %d without a reference row, %d blended (not compared)' % (frame, ok, black, bad, nolook, blended))
    return bad == 0 and ok > 250

def ring(log, frm, lo=2, hi=15, timed=True):
    rows = []
    for l in open(log):
        m = re.match(r'ring (\d+): (\d+) lines, lag (-?\d+)\.\.(-?\d+), rd-wr (\d+), overwritten (\d+), wrongline (\d+), ratio (\d+) \(top (\d+)\), time lag (-?[\d.]+)\.\.(-?[\d.]+)', l)
        if m and int(m[1]) >= frm:
            rows.append(tuple(int(x) for x in m.groups()[:9]) + m.groups()[9:])
    if not rows:
        print('no ring lines from frame %d' % frm); return False
    fmin = min(float(r[9]) for r in rows); fmax = max(float(r[10]) for r in rows)
    lmin = min(r[2] for r in rows); lmax = max(r[3] for r in rows)
    rw = sum(r[4] for r in rows); ow = sum(r[5] for r in rows); wl = sum(r[6] for r in rows)
    lines = sum(r[1] for r in rows); top = sum(r[8] for r in rows)
    ratio = sorted(set(r[7] for r in rows))
    ok = rw == 0 and ow == 0 and wl == 0 and lmin >= lo and lmax <= hi and min(r[1] for r in rows) >= 600
    ok = ok and (not timed or (fmin >= lo and fmax < hi + 1))
    print('frames %d..%d, %d HD lines: lag %d..%d (allowed %d..%d), in time %.2f..%.2f, rd-wr %d, overwritten %d, wrongline %d, ratio %s, stale top-line reads %d'
          % (rows[0][0], rows[-1][0], lines, lmin, lmax, lo, hi, fmin, fmax, rw, ow, wl, ratio, top))
    return ok

def lin(log):
    import scl_mkroms as R
    n = bad = 0
    for l in open(log):
        f = l.split()
        if f[:1] != ['lin']: continue
        k, ph, c0, c1, o, same = map(int, f[1:])
        q0, q1 = R.qweights(k >> 2, k & 3, ph)
        want = int(R.rtl_blend(c0, c1, q0, q1))
        n += 1
        if o != want or not same:
            bad += 1
            if bad <= 5: print('kernel %d phase %d: %d %d -> %d, model %d' % (k, ph, c0, c1, o, want))
    print('linear blend: %d of %d outputs = the bit-exact model' % (n - bad, n))
    return n >= 700 and bad == 0

if __name__ == '__main__':
    if sys.argv[1] == 'lin':
        sys.exit(0 if lin(sys.argv[2]) else 1)
    if sys.argv[1] == 'geom':
        a = sys.argv[2:]
        sys.exit(0 if geom(a[0], int(a[1]), int(a[2]), float(a[3]), *(float(x) for x in a[4:5])) else 1)
    if sys.argv[1] == 'rows':
        a = sys.argv[2:]
        sys.exit(0 if rows(a[0], a[1], a[2], a[3], int(a[4])) else 1)
    if sys.argv[1] == 'ring':
        a = sys.argv[2:]
        ok = ring(a[0], int(a[1]), *(int(x) for x in a[2:4]), timed=(a[4:5] != ['notime']))
        sys.exit(0 if ok else 1)
