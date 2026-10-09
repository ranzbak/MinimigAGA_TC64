#!/usr/bin/env python3
"""ROM contents for crt_post.v (rtl/openaars/adv7511/crt_wrom.mem, crt_lut.mem).
Usage: crt_mkroms.py WROM_OUT LUT_OUT BLOOM_OUT

crt_wrom.mem  2048 x 18: address {hz60, vblend, scan[1:0], phase[6:0]},
              entry {w1[8:0], w0[8:0]}, 256 = 1.0.
crt_lut.mem   8192 x 8:  address {page[1:0], mstate[2:0], v[7:0]}.
crt_bloom.mem 8192 x 8:  address {level, Wq[3:0], v[7:0]}.

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
# (linear light: single-line cosine mean = 1 - D/2), then the phosphor mask.
# Mask state (crt_post.v mstate): 0 none, 1 lit (compensation A), 2 dimmed
# 0.70 (A), 3 lit (B), 4 dimmed 0.45 (B), 5 dimmed 0.60 (A); 6, 7 = 0.
# A mask of period P with one column in P lit at 1 and the rest at DIM has
# the mean light (1 + (P-1) DIM) / P; every column is divided by that, so a
# flat field keeps its light (up to the soft clip at the top):
#   grille (R G B stripes, P 3), dim 0.70: (1 + 1.4) / 3 = 0.80  -> A
#   grille strong,               dim 0.45: (1 + 0.9) / 3 = 0.633 -> B
#   shadow (R+B / G, P 2),       dim 0.60: (1 + 0.6) / 2 = 0.80  -> A
# 720p has 2.4 HD pixels per lowres pixel: no mask is pixel-true to a tube,
# so the levels stay mild (the gaps the eye sees are 30 / 55 / 40 %).
PAGE_GAIN = {0: 1.0}
for pg in (1, 2, 3):
    PAGE_GAIN[pg] = (1 / (1 - DEPTH[pg] / 2)) ** (1 / GAMMA)
MASK = {1: (1.0, 0.80), 2: (0.70, 0.80), 3: (1.0, 1.9 / 3), 4: (0.45, 1.9 / 3), 5: (0.60, 0.80)}
def softclip(x, k=0.80):
    return x if x <= k else k + (1 - k) * (1 - math.exp(-(x - k) / (1 - k)))
with open(sys.argv[2] if len(sys.argv) > 2 else 'crt_lut.mem', 'w') as f:
    for a in range(8192):
        page, ms, v = a >> 11, (a >> 8) & 7, a & 255
        if ms > 5: ms = 0
        if page == 0 and ms == 0:
            out = v                                     # identity
        else:
            L = (v / 255) ** GAMMA * PAGE_GAIN[page] ** GAMMA
            if ms:
                dim, comp = MASK[ms]
                L *= dim / comp
            out = round(255 * softclip(L) ** (1 / GAMMA))
        f.write('%02x\n' % max(0, min(255, out)))

# Bloom: a bright beam is wider, so on bright pixels the scanline gap
# fills in.  Per HD line the beam weights give W = w0 + w1 (256 = no gap);
# per pixel and channel the table gets v (after the vertical beam) and
# Wq = clamp((W - 128) / 8, 0, 15).  Y = v * 256 / W is the pixel's own
# value, Y^GAMMA its light (the beam current); with
# k = S * clamp((Y^GAMMA - T) / (1 - T), 0, 1) the line's linear weight
# w = (W / 256)^GAMMA becomes w + k (1 - w): k = 0 leaves v, k = 1 no gap
# at all.  The threshold is in light, so mid colours (the Workbench blue,
# $A = 0.38 light) keep their scanlines and white text loses them.
# Wq 15 stands for W >= 248, no gap to fill.
# Address {level, Wq[3:0], v[7:0]}: level 0 low, 1 high.
BLOOM = {0: (0.35, 0.50), 1: (1.00, 0.30)}         # (S, T)
with open(sys.argv[3] if len(sys.argv) > 3 else 'crt_bloom.mem', 'w') as f:
    for a in range(8192):
        lvl, wq, v = a >> 12, (a >> 8) & 15, a & 255
        S, T = BLOOM[lvl]
        W = 256 if wq == 15 else 128 + 8 * wq + 4
        Y = min(1.0, v * 256 / W / 255)
        wl = (W / 256) ** GAMMA
        k = S * min(1.0, max(0.0, (Y ** GAMMA - T) / (1 - T)))
        L = Y ** GAMMA * (wl + k * (1 - wl))
        out = max(v, round(255 * L ** (1 / GAMMA)))   # fills, never darkens
        f.write('%02x\n' % min(255, out))
