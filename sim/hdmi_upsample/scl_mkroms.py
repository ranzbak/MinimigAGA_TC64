#!/usr/bin/env python3
"""Tables for the linear-light vertical scaler in crt_post.v (findings/scaler
plan step 5).  Usage: scl_mkroms.py DIR  -> DIR/crt_sdec.mem, crt_senc.mem,
crt_swrom.mem; scl_mkroms.py check: the chain against the float model,
exhaustively (see Widths).  Bit-exact model of the RTL arithmetic:
rtl_blend() below.

crt_sdec.mem   256 x 18: 8-bit code -> linear light, L = round(LMAX (c/255)^2.4),
               LMAX = 2^18 - 1, except code 1 -> 1 (it rounds to 0: see below).
crt_senc.mem  4096 x 8:  linear -> code.  Index idx(y) = y for y < 2048, else
               2032 + (y >> 7) (2048 + (y - 2048) / 128: buckets of 128 above
               2048); the entry is the code of the bucket's centre.
crt_swrom.mem 2048 x 36: address {hz60, kernel[1:0], phase[7:0]}, entry
               {wq[3:0], w1[15:0], w0[15:0]}, weights in LINEAR light,
               32768 = 1.0.
               phase = the HD line's centre below the centre of source line
               a (the "cur" line), in 1/256 line; the table holds the weights
               at the bucket centre d0 = (phase + 0.5) / 256.  hz60 0: 2.5x
               (PAL 288 -> 720), 1: 3x (NTSC 240 -> 720).  kernel:
                 0 sharp-bilinear 0.5: a box half an HD line high (0.5 / r
                   source lines) over the unit source lines -- the overlap
                 1 area (Winscale): the box one HD line high (1 / r)
                 2 CRT, scanlines dim:   the two-line gaussian beam at the
                   fractional position, crt_mkroms.py's sigma for gap depth
                   0.60, normalised to 1 at a line centre (scale.py crt_lin2)
                 3 CRT, scanlines black: the same, depth 0.80
               wq: the bloom stage's gap measure (crt_post stage F) from the
               line's total beam weight W = 256 (w0 + w1)^(1/2.4) as code
               weight: 0 below 128, 15 from 248 (no gap), else (W - 128) / 8.

Widths (findings/scaler/plan.md, Implementation notes).  Linear light
18 bits: with the pure 2.4 power law code 1 is 1.6e-6 of full scale;
against the float model (scale.py) over every code pair and every weight
k/512 the largest error of decode -> MAC -> encode is 7 codes at 12 bits
(codes 1..5 decode to 0), 4 at 14, 2 at 16 and 1 at 18.  Even at 18 bits
code 1 decodes to 0.42 and rounds to 0, which the beam's LUT page gain
(1.43 / 1.67 in light) turns into errors of 2: DEC[1] = 1 (code 1 still
encodes back to 1).  Weights 15 bits (32768 = 1.0): the beam's far tail
is tiny -- g(0.9) = 5.8e-4 at gap depth 0.80 -- and at 1/512 it rounds to 0,
14 codes of the next line's light lost (bench, scanlines black); at 1/32768
the chain is within +-1 code of the model for EVERY code pair, phase and
kernel of both tables (exhaustive, scanlines through crt_lut.mem's pages).
18 x 16-bit products fit one DSP48E1 each (25 x 18).
"""
import math, os, sys
import numpy as np

G = 2.4
LB = 18
LMAX = (1 << LB) - 1
WONE = 32768
WSH = 15
DEC = [int(round(LMAX * (c / 255) ** G)) for c in range(256)]
DEC[1] = 1
RATIO = {0: 2.5, 1: 3.0}
DEPTH = {2: 0.60, 3: 0.80}


def enc_idx(y):
    y = min(max(int(y), 0), LMAX)
    return y if y < 2048 else 2032 + (y >> 7)


def _encv(v):
    return int(round(255 * (min(max(v, 0), LMAX) / LMAX) ** (1 / G)))


ENC = [_encv(i) if i < 2048 else _encv(2048 + (i - 2048) * 128 + 63.5) for i in range(4096)]


def sigma(D):                       # crt_mkroms.py / scale.py _sigma
    return 0.5 / math.sqrt(2 * math.log(2 / (1 - D)))


def weights(hz60, kern, phase):
    """float linear weights (w0, w1) of lines a, a+1 at phase index"""
    d0 = (phase + 0.5) / 256
    r = RATIO[hz60]
    if kern in (0, 1):
        w = (0.5 if kern == 0 else 1.0) / r
        lo, hi = d0 - w / 2, d0 + w / 2           # source units, line a's centre = 0
        w1 = max(0.0, min(hi, 1.5) - max(lo, 0.5)) / w
        return 1 - w1, w1
    sg = sigma(DEPTH[kern])
    g = lambda x: math.exp(-x * x / (2 * sg * sg))
    norm = 1 + math.exp(-1 / (2 * sg * sg))
    return g(d0) / norm, g(1 - d0) / norm


def qweights(hz60, kern, phase):
    w0, w1 = weights(hz60, kern, phase)
    if kern in (0, 1):
        q1 = int(round(WONE * w1))
        return WONE - q1, q1
    return int(round(WONE * w0)), int(round(WONE * w1))


def wq_of(q0, q1):
    W = int(round(256 * ((q0 + q1) / WONE) ** (1 / G)))
    return 0 if W < 128 else 15 if W >= 248 else (W & 127) >> 3


def rtl_blend(c0, c1, q0, q1):
    """bit-exact: crt_post's linear path for one channel (numpy arrays ok)"""
    y = (np.asarray(DEC)[c0] * q0 + np.asarray(DEC)[c1] * q1 + (WONE >> 1)) >> WSH
    y = np.clip(y, 0, LMAX)
    idx = np.where(y < 2048, y, 2032 + (y >> 7))
    return np.asarray(ENC)[idx]


def check():
    """every code pair x every phase x every kernel x both tables through
    the bit-exact chain (the beam through crt_lut.mem's page 2 / 3, as
    crt_post does) against the float model (scaler/scale.py): max error"""
    import warnings
    warnings.simplefilter('ignore')
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scaler'))
    import scale
    here = os.path.dirname(os.path.abspath(__file__))
    LUT = np.array([int(l, 16) for l in open(os.path.join(here, '../../rtl/openaars/adv7511/crt_lut.mem'))])
    c = np.arange(256)
    C0, C1 = [a.ravel() for a in np.meshgrid(c, c, indexing='ij')]
    worst = {}
    for hz60 in (0, 1):
        for k in range(4):
            w = 0
            for ph in range(256):
                q0, q1 = qweights(hz60, k, ph)
                w0, w1 = weights(hz60, k, ph)
                v = rtl_blend(C0, C1, q0, q1)
                L = np.clip(w0 * (C0 / 255) ** G + w1 * (C1 / 255) ** G, 0, None)
                if k < 2:
                    rtl, model = v, np.round(255 * L ** (1 / G))
                else:
                    rtl, model = LUT[(k << 11) | v], scale.crt_post(L[None, :], DEPTH[k])[0]
                w = max(w, int(np.abs(rtl.astype(int) - model.astype(int)).max()))
            worst[(hz60, k)] = w
    names = ('sharp', 'area', 'beam dim', 'beam black')
    print('tables against the float model, all 65536 code pairs x 256 phases: ' +
          ', '.join('%s %s max %d' % ('3x' if h else '2.5x', names[k], w) for (h, k), w in sorted(worst.items())))
    return max(worst.values()) <= 1


if __name__ == '__main__':
    if sys.argv[1:2] == ['check']:
        sys.exit(0 if check() else 1)
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    with open(os.path.join(out, 'crt_sdec.mem'), 'w') as f:
        f.writelines('%05x\n' % v for v in DEC)
    with open(os.path.join(out, 'crt_senc.mem'), 'w') as f:
        f.writelines('%02x\n' % v for v in ENC)
    with open(os.path.join(out, 'crt_swrom.mem'), 'w') as f:
        for a in range(2048):
            hz60, kern, ph = a >> 10, (a >> 8) & 3, a & 255
            q0, q1 = qweights(hz60, kern, ph)
            f.write('%09x\n' % ((wq_of(q0, q1) << 32) | (q1 << 16) | q0))
