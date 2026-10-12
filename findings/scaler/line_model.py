#!/usr/bin/env python3
"""1-D vertical line model for findings/scaler/scaling-survey.md (2026-10-13).

A white line one source line high on black, at every source position k
(= vertical scroll by whole lines), rendered onto output lines of height h
(source-line units; 50 Hz native h = 3960/9509.4 = 1/2.40).  Per method,
over k: light per line max/min (linear light), centroid jitter and RMS
width spread (output lines), and the share of the line's light that sits
in partially lit output lines (a sharpness proxy: 0 % = all hard edges).
'win' scales the area window: 1.0 = exact overlap (box of one output
line), 0.5 = half an output line (sharper, less even).  'gamma' blends
8-bit codes (what crt_post does today), 'linear' blends light.
No dependencies beyond numpy.  Usage: python3 line_model.py
"""
import math, warnings, numpy as np
warnings.simplefilter('ignore')
G = 2.4
def kernel_weights(method, d, h, sharp=1.0):
    """weight of source line whose centre is at distance d (output centre - source centre,
    source units) -- 2-tap families; returns gamma-space weight in [0,1]"""
    ad = abs(d)
    if method == 'nearest':
        return 1.0 if ad < 0.5 else (0.5 if ad == 0.5 else 0.0)
    if method == 'bilinear':
        return max(0.0, 1 - ad)
    if method == 'area':        # box of width h*sharp (window) against unit box
        w = h * sharp
        lo, hi = -d - w / 2, -d + w / 2
        return max(0.0, min(hi, 0.5) - max(lo, -0.5)) / w
    if method == 'sharpbil':    # libretro sharp-bilinear-simple, integer prescale
        s = max(1, math.floor(1 / h))
        r = 0.5 - 0.5 / s
        # weight of line at distance d via the warped coordinate
        return max(0.0, min(1.0, (0.5 - ad) * s + 0.5)) if ad < 1 else 0.0
    raise ValueError
def render(method, h, k0, lin, sharp=1.0, n=None):
    n = n or int(40 / h) + 10
    # output line j centre at y = j*h + phase; source line k0 white
    out = []
    for j in range(n):
        y = j * h + 0.123  # arbitrary phase
        # weights over the source lines near y
        ws = {}
        for k in range(math.floor(y) - 2, math.floor(y) + 3):
            ws[k] = kernel_weights(method, y - k, h, sharp)
        tot = sum(ws.values()) or 1
        w = ws.get(k0, 0) / tot
        out.append(w if lin else w ** G)   # linear light of output line
    return np.array(out)
def metrics(method, h, lin, sharp=1.0):
    L, C, W, P = [], [], [], []
    for k0 in range(5, 25):
        o = render(method, h, k0, lin, sharp)
        tl = o.sum(); L.append(tl * h)        # light in source-line units
        j = np.arange(len(o)); c = (o * j).sum() / tl
        C.append(c - k0 / h)
        W.append(math.sqrt((o * (j - c) ** 2).sum() / tl))
        P.append(o[(o > 0.02) & (o < 0.98)].sum() / tl)
    C = np.array(C); C -= C.mean()
    return max(L) / min(L), np.abs(C).max(), (max(W) - min(W)), np.mean(P)
for name, h in [('50Hz 2.40x', 3960 / 9509.4), ('60Hz PAL 2.88x', 3300 / 9509.4), ('RTG 1.5x', 1 / 1.5), ('RTG 1.2x', 1 / 1.2), ('RTG 0.9375x', 1 / 0.9375), ('NTSC 60Hz 2.86x', 3300 / 9437.0), ('2x', 0.5), ('3x', 1 / 3)]:
    print('==', name)
    for m, sh in [('nearest', 1), ('area', 1), ('area', 0.5), ('bilinear', 1), ('sharpbil', 1)]:
        for lin in (False, True):
            if m == 'nearest' and lin: continue
            r = metrics(m, h, lin, sh)
            print('  %-9s win %.1f %-6s light max/min %.3f  centroid jitter %.3f  width spread %.3f  light in mixed lines %3.0f%%' % (m, sh, 'linear' if lin else 'gamma', r[0], r[1], r[2], 100 * r[3]))
