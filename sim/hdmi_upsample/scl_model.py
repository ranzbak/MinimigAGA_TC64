#!/usr/bin/env python3
"""The scaler's RTL pictures against the Python model (findings/scaler plan
step 5; scaler_run.sh lin* legs), and the PNGs for the eye.

  scl_model.py compare LR.hex,LRPHASE[+LR2.hex,LR2PHASE] X.hex XPHASE FRAME KERNEL HZ [PNG]
      X: an exact-ratio picture (tb_crt_frame +out, HD frame FRAME) with
      crt_post's linear-light blend; KERNEL sharp | area | dim | black
      (Scaling sharp / area, or scanlines dim / black: the two-line beam);
      HZ 50 (2.5x) or 60 (3x).  LR: line-rate pictures of the same source,
      cfg 0 (two: VPOS 0 and -16, which between them show every line of
      the window; Agnus' vertical blank is black) -- crt_post passes them through, so their rows ARE the
      line-buffer rows crt_post gets, one per source line (the phase file
      says which).  For every active HD row of X the model (scaler/scale.py,
      the study's model that made the PNGs Paul judged) blends the two
      source rows the RTL read (cur = line a, next = a + 1, black outside
      the frame) at the RTL's phase -- the table's (phase + 0.5) / 256 --
      in linear light: box kernels by scale.box_matrix (box 0.5 / r or 1 / r
      source lines high), the beam by scale.crt_row + crt_post (gap depth
      0.60 / 0.80, page gain, soft clip).  Pass: every pixel and channel
      within +-1 code.  Prints the error histogram.  PNG: write the model
      picture there.

The comparison is per row, so the geometry is the RTL's own (scl_check.py
geom checks that against the exact ratio).
"""
import os, sys, collections
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scaler'))
import scale

RATIO = {50: 2.5, 60: 3.0}
DEPTH = {'dim': 0.60, 'black': 0.80}


def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32).reshape(720, 1280)
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.uint8)


# the picture's row 0 is HD line TOP of the frame (pal_to_ddr.sv's generator
# window, PAL_VT_TOP, since 2026-10-27); the phase file counts frame lines
TOP = 15


def phases(fn, frame):
    out = {}
    for l in open(fn):
        f = l.split()
        if int(f[0]) == frame:
            out[int(f[1]) - TOP] = [int(x) for x in f[2:]]   # keyed by picture row
    return out


def source_rows(lrs, frame):
    """line-buffer row of each source line (vcnt), from line-rate pictures
    [(hex, phasefile), ...]; not their top rows (buffers written before the
    restart, whatever the bookkeeping says) nor their last (cut)"""
    rows, clash = {}, 0
    for lr, lrph in lrs:
      R, p = load(lr), phases(lrph, frame)
      for j in range(10, 719):
        if j in p and p[j][3] == 0:
            v = p[j][5]
            if v in rows and not np.array_equal(rows[v], R[j]):
                clash += 1
            rows.setdefault(v, R[j])
    return rows, clash


def model_row(cur, nxt, d0, kern, hz):
    c = 0.5 + d0                      # centre, in a 2-line source: cur = [0, 1), next = [1, 2)
    src = np.stack([cur, nxt])
    if kern in ('sharp', 'area'):
        w = (0.5 if kern == 'sharp' else 1.0) / RATIO[hz]
        M = scale.box_matrix(2, 1, 1.0, 0.5 - c, w)        # one output row centred at c
        # scale.apply_sep's linear path with the identity horizontally
        return scale.enc(np.einsum('j,jkc->kc', M[0], scale.dec(src)))
    D = DEPTH[kern]
    L = scale.dec(src)
    row = scale.crt_row(L, src.astype(np.float64), c, 'crt_lin2', D)
    return scale.crt_post(row[None], D)[0]


def compare(lrs, x, xph, frame, kern, hz, png=None):
    H, clash = source_rows(lrs, frame)
    X, p = load(x), phases(xph, frame)
    M = np.zeros_like(X)
    hist = collections.Counter()
    rows = skipped = 0
    worst = (0, None)
    for j in range(720):
        if j not in p or p[j][3] != 1:
            continue
        y, cv, nv, vph = p[j][4], p[j][5], p[j][6], p[j][2]
        a = y >> 20
        z = np.zeros((1280, 3), np.uint8)
        vb = 26 if hz == 50 else 21          # Agnus' vertical blank: black lines
        cur = z if a < 0 or cv < vb else H.get(cv)
        nxt = z if a < -1 or nv < vb else H.get(nv)
        if cur is None or nxt is None:
            skipped += 1
            continue
        M[j] = model_row(cur, nxt, (vph + 0.5) / 256, kern, hz)
        e = np.abs(X[j].astype(int) - M[j].astype(int))
        hist.update(e.ravel().tolist())
        if e.max() > worst[0]:
            worst = (int(e.max()), (j, int(e.max(-1).argmax())))
        rows += 1
    if png:
        from PIL import Image
        Image.fromarray(M).save(png)
    n = sum(hist.values())
    over = sum(v for k, v in hist.items() if k > 1)
    print('%s %d Hz frame %d: %d rows (%d without source rows, line-rate row clashes %d), %d values: '
          'error 0: %.3f%%, 1: %.3f%%, >1: %d (max %d at row/x %s)'
          % (kern, hz, frame, rows, skipped, clash, n, 100 * hist[0] / max(n, 1), 100 * hist[1] / max(n, 1), over, worst[0], worst[1]))
    return rows >= 700 and over == 0 and clash == 0


if __name__ == '__main__':
    if sys.argv[1] == 'compare':
        a = sys.argv[2:]
        lrs = [tuple(p.split(',')) for p in a[0].split('+')]
        ok = compare(lrs, a[1], a[2], int(a[3]), a[4], int(a[5]), a[6] if len(a) > 6 else None)
        sys.exit(0 if ok else 1)
