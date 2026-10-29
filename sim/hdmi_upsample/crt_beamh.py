#!/usr/bin/env python3
"""Horizontal CRT beam spot (rtl/openaars/adv7511/crt_beamh.v): bit-exact
integer model, its tables, and the gate checks (crt_run.sh beam* legs).

The filter (study 2026-10-09, sheets approved by Paul) runs on the Amiga RGB
stream before the HDMI upsamplers capture it: one superhires sample per
CLK_28 (4 clk_114), whatever the screen mode -- a lowres pixel is 4 equal
samples, a hires pixel 2.  The spot is a gaussian of constant width ON
SCREEN, so the kernel is the same for every resolution: sigma 0.6 lowres px
= 1.2 hires px = 2.4 superhires px = 2.4 samples.  The OSD's "Beam width"
picks the lowres sigma, "Bloom" (when the beam is on) widens the spot of
bright pixels.

Per channel:
  1. decode   L = DEC[v]  (8-bit gamma code -> 16-bit linear, gamma 2.4) and
              B = BDEC[level][v] = round(L * b(v)), the bloom share of the
              pixel's light (0 with bloom off)
  2. pre      s = 2: P = L[-1] + 2 L + L[+1]                    (sum 4)
              s = 4: P = L[-2] + 2 L[-1] + 2 L + 2 L[+1] + L[+2] (sum 8)
  3. FIR      acc = sum_{j=-4..4} kn[j] P[n + s j] + dk[j] PB[n + s j]
              kn: narrow gaussian, 9 integer taps summing to 256; dk = kw - kn
              (wide minus narrow, sums to 0) on the bloom share
  4. y = (acc + half) >> (8 + log2(pre sum)), clamped to 0..65535
  5. encode   ENC[idx], idx = y (y < 2048) else 2048 + (y - 2048) >> 5

The RTL scales the s = 2 pre-stage by 2 (sum 8 for both) and always shifts
by 11: (2 acc + 2^10) >> 11 == (acc + 2^9) >> 10, bit for bit.

Usage:
  crt_beamh.py roms DIR              crt_hdec.mem, crt_henc.mem, crt_hk.mem
  crt_beamh.py kernels               the kernel table, effective sigmas
  crt_beamh.py prefilter IN.hex OUT.hex WIDTH BLOOM
                                     the bench's Amiga frame (312 x 1816
                                     samples, RRGGBB) filtered as one
                                     continuous stream, field after field,
                                     as the RTL sees it
  crt_beamh.py stream IN.hex DUMP WIDTH BLOOM
                                     RTL output stream (tb +sdump) against
                                     the model: prints the offset and the
                                     number of samples that differ
  crt_beamh.py metrics REGIONS.json X.hex [X.hex ...]
                                     dither frame (crt_mkdither.py) 720p
                                     picture: checkerboard blend metrics
"""
import sys, json
import numpy as np

G = 2.4
LB = 16
LMAX = (1 << LB) - 1
DEC = np.array([int(round(LMAX * (v / 255) ** G)) for v in range(256)], np.int64)

def _enc_val(y):
    return int(round(255 * (min(max(y, 0), LMAX) / LMAX) ** (1 / G)))
ENC = np.zeros(4096, np.int64)
for _i in range(4096):
    if _i < 2048:
        ENC[_i] = _enc_val(_i)
    else:
        ENC[_i] = _enc_val(2048 + (_i - 2048) * 32 + 15.5)
def encode(y):
    y = np.clip(y, 0, LMAX)
    idx = np.where(y < 2048, y, 2048 + ((y - 2048) >> 5))
    return ENC[np.minimum(idx, 4095)]

# OSD "Beam width": lowres sigma in lowres pixels (1 sharp, 2 medium, 3 soft)
WIDTH = {1: 0.5, 2: 0.6, 3: 0.8}
SPP = 4                                  # superhires samples per lowres pixel
# OSD "Bloom" with the beam on: (sigma_w / sigma, S, T)
BLOOM = {0: None, 1: (1.5, 0.6, 0.35), 2: (2.0, 1.0, 0.20)}

def bdec(level):
    if not BLOOM.get(level):
        return np.zeros(256, np.int64)
    _, S, T = BLOOM[level]
    lin = (np.arange(256) / 255) ** G
    b = S * np.clip((lin - T) / (1 - T), 0, 1)
    return np.round(DEC * b).astype(np.int64)

PRE = {1: np.array([1]), 2: np.array([1, 2, 1]), 4: np.array([1, 2, 2, 2, 1])}
PRESH = {1: 0, 2: 2, 4: 3}

def kernel(sig_s, s):
    """9 taps at spacing s samples, gaussian sigma sig_s samples (after the
    pre-stage's own variance is taken out), integer, sum 256"""
    vpre = {1: 0.0, 2: 0.5, 4: 2.5}[s]
    sg = np.sqrt(max(sig_s ** 2 - vpre, 0.05))
    x = np.arange(-4, 5) * s
    w = np.exp(-x * x / (2 * sg * sg))
    w = w / w.sum() * 256
    k = np.round(w).astype(np.int64)
    k[4] += 256 - k.sum()
    return k

def spacing(sig_s):
    for s in (1, 2, 4):
        if 4 * s + s // 2 >= 2.2 * sig_s:
            return s
    return 4

def design(sigma, spp=SPP, bloom=0):
    """-> dict(s, kn, dk, sh, bd) for sigma in lowres px, spp samples per px"""
    sw = sigma * (BLOOM[bloom][0] if BLOOM.get(bloom) else 1.0)
    s = spacing(max(sigma, sw) * spp)
    kn = kernel(sigma * spp, s)
    kw = kernel(sw * spp, s) if BLOOM.get(bloom) else kn
    return dict(s=s, kn=kn, dk=kw - kn, sh=8 + PRESH[s], bd=bdec(bloom))

def osd_design(width, bloom):
    return design(WIDTH[width], SPP, bloom)

def eff_sigma(d, spp=SPP):
    k = np.zeros(8 * d['s'] + 1); k[::d['s']] = d['kn']
    k = np.convolve(k, PRE[d['s']])
    x = np.arange(len(k)) - (len(k) - 1) / 2
    return np.sqrt((k * x * x).sum() / k.sum()) / spp

def _shift(a, o):
    """a (B, N, ...) -> a[:, n + o], zero outside"""
    N = a.shape[1]
    b = np.zeros_like(a)
    if o >= 0: b[:, :N - o] = a[:, o:]
    else:      b[:, -o:] = a[:, :N + o]
    return b

def _pre(a, s):
    p = PRE[s]; h = len(p) // 2
    out = np.zeros_like(a)
    for i, c in enumerate(p):
        out += int(c) * _shift(a, i - h)
    return out

def filt_lin(x, d):
    """x: (B, N, 3) int 8-bit codes -> filtered 8-bit codes, linear light"""
    L = DEC[x]; Bl = d['bd'][x]
    s = d['s']
    P = _pre(L, s); PB = _pre(Bl, s)
    acc = np.zeros_like(L)
    for j, k in zip(range(-4, 5), d['kn']):
        acc += int(k) * _shift(P, s * j)
    if d['dk'].any():
        for j, k in zip(range(-4, 5), d['dk']):
            acc += int(k) * _shift(PB, s * j)
    y = (acc + (1 << (d['sh'] - 1))) >> d['sh']
    return encode(y)

# ---------------------------------------------------------------- tables
def roms(outdir):
    # decode: address {level[1:0], v[7:0]}, entry {B[15:0], L[15:0]}
    with open(outdir + '/crt_hdec.mem', 'w') as f:
        for lvl in range(4):
            bd = bdec(lvl if lvl < 3 else 0)
            for v in range(256):
                f.write('%08x\n' % ((int(bd[v]) << 16) | int(DEC[v])))
    with open(outdir + '/crt_henc.mem', 'w') as f:
        for i in range(4096):
            f.write('%02x\n' % ENC[i])
    # kernels: address {bloom[1:0], width[1:0]}; entry (96 bits)
    # {s4, kn0..kn4 (9 bits each, kn0 the centre), dk0..dk4 (10 bits signed)}
    with open(outdir + '/crt_hk.mem', 'w') as f:
        for a in range(16):
            bl, w = a >> 2, a & 3
            if w == 0 or bl == 3:
                f.write('%024x\n' % 0)
                continue
            d = osd_design(w, bl)
            assert d['s'] in (2, 4)
            kn = [int(d['kn'][4 + j]) for j in range(5)]
            dk = [int(d['dk'][4 + j]) for j in range(5)]
            assert all(0 <= k < 512 for k in kn) and all(-512 <= k < 512 for k in dk)
            v = 1 if d['s'] == 4 else 0
            for k in kn: v = (v << 9) | k
            for k in dk: v = (v << 10) | (k & 1023)
            f.write('%024x\n' % v)

def kernels():
    for w in (1, 2, 3):
        for bl in (0, 1, 2):
            d = osd_design(w, bl)
            print('width %d (sigma %.1f lowres px = %.1f samples) bloom %d: s %d kn %s dk %s  narrow eff sigma %.3f lowres px'
                  % (w, WIDTH[w], WIDTH[w] * SPP, bl, d['s'], list(d['kn']), list(d['dk']), eff_sigma(d)))

# ---------------------------------------------------------------- frames
W_A, H_A = 1816, 312
def load_amiga(fn):
    a = np.array([int(l, 16) for l in open(fn)], np.uint32).reshape(H_A, W_A)
    return np.stack([a >> 16, (a >> 8) & 255, a & 255], -1).astype(np.int64)

def filt_frames(img, width, bloom):
    """the frame filtered as ONE stream, lines back to back and frame after
    frame (the bench sends the same 312-line field over and over), as the
    RTL sees it"""
    a = img.reshape(-1, 3)
    E = 64
    ext = np.concatenate([a[-E:], a, a[:E]])[None]
    return filt_lin(ext, osd_design(width, bloom))[0, E:-E]

def prefilter(fin, fout, width, bloom):
    """a re-run with the filter off on this source must give the RTL's
    picture exactly"""
    out = filt_frames(load_amiga(fin), width, bloom).reshape(H_A, W_A, 3)
    with open(fout, 'w') as f:
        for r in out.reshape(-1, 3):
            f.write('%02x%02x%02x\n' % tuple(r))

def stream(fin, dump, width, bloom):
    """dump: tb +sdump lines 'V S RRGGBB' -- the filter's output sample
    and the bench's line V / sample S being sent at that clock.  Finds the
    offset (in samples) at which the RTL stream equals the model's"""
    ref = filt_frames(load_amiga(fin), width, bloom)
    pos, val = [], []
    for l in open(dump):
        v, s, x = l.split()
        pos.append(int(v) * W_A + int(s)); x = int(x, 16)
        val.append(((x >> 16) & 255, (x >> 8) & 255, x & 255))
    if not val:
        print('beam stream width %d bloom %d: no output samples' % (width, bloom))
        return False
    pos = np.array(pos); val = np.array(val)
    best = None
    for off in range(0, 64):
        p = (pos - off) % len(ref)
        n = int((ref[p] != val).any(-1).sum())
        if best is None or n < best[1]:
            best = (off, n)
    print('beam stream width %d bloom %d: %d samples, offset %d samples, %d differ'
          % (width, bloom, len(val), best[0], best[1]))
    return best[1] == 0 and len(val) > 100000

def metrics(regfn, fns):
    """checkerboard / column dither blending on the 720p picture of the
    dither frame (as the study's sheets/metrics.txt): per 50 % dither patch
    the linear-light mean against the ideal linear mix (err, codes) and the
    residual pattern contrast cv (%)"""
    REG = json.load(open(regfn))
    # dump coordinates; the dump is the display window since 2026-10-27,
    # 60 HD pixels left of and 15 lines above the old one (crt_check.py DX, DY)
    def col(lx): return 110.6 - 60 + 3.2 * lx
    def row(v): return 101 - 15 + (v - 44) * 2.4
    def dec(a): return (a.astype(float) / 255) ** G
    def enc(l): return np.round(255 * np.clip(l, 0, 1) ** (1 / G)).astype(int)
    pats = [r for r in REG if r['kind'] == 'dither50']
    res = {}
    for fn in fns:
        a = np.array([int(l, 16) for l in open(fn)], np.uint32).reshape(720, 1280)
        fr = np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1)
        out = {}
        for r in pats:
            x0 = int(np.ceil(col(r['lx0']))) + 8; x1 = int(col(r['lx1'])) - 8
            y0 = int(np.ceil(row(r['v0']))) + 3; y1 = int(row(r['v1'])) - 3
            p = dec(fr[y0:y1, x0:x1].reshape(-1, 3))
            m = p.mean(0)
            cv = 100 * np.sqrt(p.var(0).mean()) / max(m.mean(), 1e-6)
            err = int(np.abs(enc(m) - np.array(r['lin'])).max())
            out[r['name']] = (err, cv)
        res[fn] = out
        print(fn + ': ' + '  '.join('%s e%d cv%.1f' % (k, e, c) for k, (e, c) in out.items()))
    return res

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'roms':
        roms(sys.argv[2])
    elif cmd == 'kernels':
        kernels()
    elif cmd == 'prefilter':
        prefilter(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))
    elif cmd == 'stream':
        sys.exit(0 if stream(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])) else 1)
    elif cmd == 'metrics':
        metrics(sys.argv[2], sys.argv[3:])
