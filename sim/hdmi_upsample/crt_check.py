#!/usr/bin/env python3
"""Measurements for the CRT gates (crt_run.sh).  Pictures are tb_crt_frame
dumps: 1280x720, one RRGGBB hex word per line, raster order.

crt_check.py flat X.hex
    The left border (COLOR00 $05A, x 120..200, HD rows 70..710), blue channel
    in linear light (gamma 2.4): light relative to the source colour, and the
    low-frequency beat (spectral content below 0.3 cycles per HD row, RMS /
    mean): the scanline structure the eye does not blur away.
crt_check.py ripple crt_wrom.mem
    From the weight table the design uses: a flat field through the RTL's
    line-phase measurement (2.4 HD lines per input line, arbitrary toggle
    phase), per two-line-beam profile: the light each input line gets
    (linear, sum of its share over the HD lines) max/min, and the beat.
crt_check.py lace PHASEFILE FIELD_A FIELD_B
    Line phase shift between two fields of an interlaced run (tb +lace),
    in input lines: mean |shift| over HD lines 100..700.
crt_check.py split X.hex
    tb +split picture with the H filters on (scanlines off): every HD row
    with stripes must show exactly one horizontal kernel -- edge values
    {63, 191} = [1 2 1]/4 (lowres) or {31, 223} = [1 6 1]/8 (hires) -- and
    the one for its input line: green stripes lowres, red stripes hires,
    blue C8 (switched to hires before the mid-line sample) hires, blue 64
    (switched after it) lowres.
"""
import sys, math, collections, statistics
import numpy as np

def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32).reshape(720, 1280)
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.int32)

def flat(fn):
    a = load(fn).astype(float)
    col = (a[70:710, 120:200, 2] / 255) ** 2.4
    r = col.mean(1); m = r.mean()
    F = np.fft.rfft(r - m); f = np.fft.rfftfreq(len(r))
    low = np.sqrt((np.abs(F[(f > 0) & (f < 0.3)]) ** 2).sum() * 2) / len(r)
    light = m / (170 / 255) ** 2.4
    print('%s: light %.4f  beat %.3f%%' % (fn, light, 100 * low / m))
    return light, 100 * low / m

T_A = 7264 * 148.5 / 113.4375       # one input line (227 CCK) in clk_148
T_HD = {0: 3960, 1: 3300}           # 720p50 / 720p60 line, clk_148

def ripple(memfn):
    rom = [int(l, 16) for l in open(memfn)]
    out = []
    for hz60 in (0, 1):
        for scan in (1, 2, 3):
            thd = T_HD[hz60]; t0 = 1234.5
            rows = []; energy = collections.defaultdict(float)
            for j in range(6000):
                L = j * thd
                k = math.floor((L - thd - t0) / T_A)       # buffer this HD line shows
                cnt = L - (t0 + k * T_A)                    # clk_148 since its toggle
                idx = min(127, int(cnt // 128))
                e = rom[(hz60 << 10) | (1 << 9) | (scan << 7) | idx]
                w0, w1 = (e & 511) / 256, (e >> 9) / 256
                tot = (w0 + w1) ** 2.4
                rows.append(tot)
                if w0 + w1 > 0:
                    energy[k] += tot * w0 / (w0 + w1)
                    energy[k + 1] += tot * w1 / (w0 + w1)
            r = np.array(rows[100:-100]); m = r.mean()
            F = np.fft.rfft(r - m); f = np.fft.rfftfreq(len(r))
            low = np.sqrt((np.abs(F[(f > 0) & (f < 0.3)]) ** 2).sum() * 2) / len(r)
            e = np.array([energy[k] for k in sorted(energy)][20:-20])
            rip = e.max() / e.min()
            print('two-line beam %s Hz scan %d: ripple %.4f  beat %.3f%%' % ('60' if hz60 else '50', scan, rip, 100 * low / m))
            out.append((hz60, scan, rip))
    return out

def lace(fn, a, b):
    ph = collections.defaultdict(dict)
    for l in open(fn):
        f, h, p = map(int, l.split()[:3]); ph[f][h] = p
    d = [((ph[b][h] - ph[a][h]) * 128 / T_A + 0.5) % 1 - 0.5 for h in range(100, 700)]
    v = statistics.mean(abs(x) for x in d)
    print('line phase, field %d -> %d: mean |shift| %.4f input line (min %.3f, max %.3f)' % (a, b, v, min(d), max(d)))
    return v

def split(fn):
    a = load(fn)
    LO, HI = {63, 191}, {31, 223}
    seen = collections.Counter(); bad = 0
    for y in range(720):
        row = a[y]
        r, g, bl = row[:, 0], row[:, 1], row[:, 2]
        if r.max() == 0 and g.max() == 0:
            continue
        mid = set(int(v) for v in np.concatenate([r[(r > 0) & (r < 255)], g[(g > 0) & (g < 255)]]))
        bvals = collections.Counter(int(v) for v in bl if v != 0)
        mark = bvals.most_common(1)[0][0] if bvals else 0
        if mark == 0xC8:   kind, want = 'switch-early', 'hires'
        elif mark == 0x64: kind, want = 'switch-late', 'lowres'
        elif r.max() > 0 and g.max() == 0: kind, want = 'hires', 'hires'
        elif g.max() > 0 and r.max() == 0: kind, want = 'lowres', 'lowres'
        else:
            # a marked row also has the blur of its blue marker against the
            # black border in blue only; anything else mixed is an error
            kind, want = 'mixed', None
        got = 'lowres' if mid and mid <= LO else 'hires' if mid and mid <= HI else ('none' if not mid else 'both:%s' % sorted(mid))
        ok = (want is not None and got == want)
        if not ok:
            bad += 1
            if bad <= 10: print('row %d: %s line, edge values %s -> %s (want %s)' % (y, kind, sorted(mid), got, want))
        seen[kind] += 1
    print('split: rows checked %s, wrong %d' % (dict(seen), bad))
    return bad == 0 and all(seen[k] > 0 for k in ('lowres', 'hires', 'switch-early', 'switch-late'))

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'flat':
        flat(sys.argv[2])
    elif cmd == 'ripple':
        ripple(sys.argv[2])
    elif cmd == 'lace':
        lace(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif cmd == 'split':
        sys.exit(0 if split(sys.argv[2]) else 1)
