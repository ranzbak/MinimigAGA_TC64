#!/usr/bin/env python3
"""ROM contents for crt_post.v (rtl/openaars/adv7511/crt_wrom.mem, crt_lut.mem).
Usage: crt_mkroms.py WROM_OUT LUT_OUT

crt_wrom.mem  2048 x 18: address {hz60, vblend, scan[1:0], phase[6:0]},
              entry {w1[8:0], w0[8:0]}, 256 = 1.0.
crt_lut.mem   4096 x 8:  address {page[1:0], mstate[1:0], v[7:0]}.

Line phase: pal_to_hd_upsample.v counts clk_148 from the buffer toggle
(the write side finished an Amiga line) to the HD line's hsync; the line
shows that buffer for counts T_HD .. T_HD + T_A.  idx = count / 128.
The HD line's centre in Amiga-line units, from the start of its buffer's
display interval:  p = (count - T_HD/2) / T_A, in [T_HD/2T_A, 1 + T_HD/2T_A).
"""
import math, sys
T_A = 7264 * 148.5 / 113.4375       # one Amiga line (227 CCK) in clk_148: 9509
T_HD = {0: 3960, 1: 3300}           # 720p50 / 720p60 line, clk_148
DEPTH = {1: 0.35, 2: 0.60, 3: 0.80} # gap depth in LINEAR light per scan level
GAMMA = 2.4
# The weights multiply gamma-encoded pixels; a gamma-space weight w gives
# w^GAMMA in linear light for any pixel value, so the profiles are defined
# in linear light and stored as w_lin^(1/GAMMA).  (Defining them in gamma
# space puts harmonics into the light profile, which alias against the
# 2.4 HD lines per Amiga line: ~3x the low-frequency beat, tb/beat.py.)

def sigma(D):                       # beam sigma whose flat-field gap is 1-D
    return 0.5 / math.sqrt(2 * math.log(2 / (1 - D)))

def weights(hz60, vblend, scan, idx):
    thd = T_HD[hz60]
    cnt = idx * 128 + 64
    p = (cnt - thd / 2) / T_A
    off = thd / 2 / T_A             # first line centre after the switch
    if scan == 0 and not vblend:
        return 256, 0               # bypass
    if not vblend:
        d = p - (0.5 + off)         # distance from this line's beam centre
        d = max(-0.5, min(0.5, d))
        D = DEPTH[scan]
        wl = 1 - D * (1 - math.cos(2 * math.pi * d)) / 2
        return round(256 * wl ** (1 / GAMMA)), 0
    d0 = min(max(p - off, 0.0), 1.0)    # from line k's centre (above)
    d1 = 1 - d0                         # from line k+1's centre (below)
    if scan == 0:                       # plain linear blend (gamma space)
        return round(256 * (1 - d0)), round(256 * d0)
    sg = sigma(DEPTH[scan])
    g = lambda x: math.exp(-x * x / (2 * sg * sg))
    n = max(g(t / 100) + g(1 - t / 100) for t in range(101))
    g0, g1 = g(d0) / n, g(d1) / n       # linear light of each beam here
    s = (g0 + g1) ** (1 / GAMMA)        # flat field: (w0+w1)^GAMMA = g0+g1
    return round(256 * s * g0 / (g0 + g1)), round(256 * s * g1 / (g0 + g1))

with open(sys.argv[1] if len(sys.argv) > 1 else 'crt_wrom.mem', 'w') as f:
    for a in range(2048):
        hz60, vb, scan, idx = a >> 10, (a >> 9) & 1, (a >> 7) & 3, a & 127
        w0, w1 = weights(hz60, vb, scan, idx)
        f.write('%05x\n' % ((w1 << 9) | w0))

# LUT: per page a gain that undoes the mean darkening of scan level <page>
# (linear light: single-line cosine mean = 1 - D/2), then the mask
PAGE_GAIN = {0: 1.0}
for pg in (1, 2, 3):
    PAGE_GAIN[pg] = (1 / (1 - DEPTH[pg] / 2)) ** (1 / GAMMA)
MASK_DIM = 0.55                     # linear light of a dimmed mask column
def softclip(x, k=0.80):
    return x if x <= k else k + (1 - k) * (1 - math.exp(-(x - k) / (1 - k)))
with open(sys.argv[2] if len(sys.argv) > 2 else 'crt_lut.mem', 'w') as f:
    for a in range(4096):
        page, ms, v = a >> 10, (a >> 8) & 3, a & 255
        if page == 0 and ms in (0, 3):
            out = v                                     # identity
        else:
            L = (v / 255) ** GAMMA * PAGE_GAIN[page] ** GAMMA
            if ms == 2: L *= MASK_DIM
            if ms in (1, 2) and page != 0:
                L /= (1 + 2 * MASK_DIM) / 3             # mask compensation
            out = round(255 * softclip(L) ** (1 / GAMMA))
        f.write('%02x\n' % max(0, min(255, out)))
