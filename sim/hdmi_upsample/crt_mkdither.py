#!/usr/bin/env python3
"""crt_mkdither.py -- dither test frame for the HDMI CRT bench (tb_crt_frame.v input format:
312 lines x 1816 superhires samples, RRGGBB hex per word, line-major) plus a
per-line hires flag file (312 x 0/1) for tb_crt_frame.v +hires=.

Visible on the 720p50 output: hpos 89..456 (HD col = 101 + (hpos-89)*3.2),
lines 26..301 (HD row ~ 101 + (line-44)*2.4).  Canvas: lowres px lx 0..359
at hpos 92+lx.  Two sections with the same physical layout: lowres (lines
30..163) and hires (lines 166..299, patterns in hires pixels).

Usage: crt_mkdither.py [OUTDIR] (default build/).  Writes dither.hex,
dither_hires.hex, dither_regions.json and dither_source.png (superhires
samples 1:1 wide, lines x2) there.  Needs the console font
/usr/share/consolefonts/Lat15-VGA8.psf.gz (Debian/Ubuntu "console-setup").

(The study's frame, 2026-10-09: the beam* legs of crt_run.sh and the
sheets Paul approved were made from it.)
"""
import gzip, json, os, sys
import numpy as np

W, H = 1816, 312
HB0, HB1 = 13, 89
VB = 26
G = 2.4
HP0 = 92                      # hpos of lx 0

def c12(x):
    return (((x >> 8) & 15) * 17, ((x >> 4) & 15) * 17, (x & 15) * 17)

def dec(c): return (np.asarray(c, float) / 255.0) ** G
def enc(l): return tuple(int(round(255 * v ** (1 / G))) for v in np.clip(l, 0, 1))
def linmix(c1, c2, t):        # fraction t of c2, in linear light
    return enc((1 - t) * dec(c1) + t * dec(c2))
def gammix(c1, c2, t):
    return tuple(int(round((1 - t) * a + t * b)) for a, b in zip(c1, c2))

BAYER2 = np.array([[0, 2], [3, 1]])
BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]])

d = gzip.open('/usr/share/consolefonts/Lat15-VGA8.psf.gz').read()
FONT = d[4:4 + 256 * 8]
def glyph(ch):
    o = ord(ch) * 8
    return [[(FONT[o + r] >> (7 - c)) & 1 for c in range(8)] for r in range(8)]

img = np.zeros((H, W, 3), np.uint8)
hires_line = np.zeros(H, np.uint8)
BG = c12(0x222)
for v in range(VB, H):
    for x in range(W):
        if not (HB0 <= x // 4 < HB1):
            img[v, x] = BG

regions = []

def patch(name, res, lx0, lx1, v0, v1, fn, kind='', meta=None):
    """fill physical lowres columns [lx0, lx1) x lines [v0, v1) with fn(u, v)
    where u is the pixel index in the patch at resolution res (1 lowres, 2 hires)"""
    sw = 4 // res
    for v in range(v0, v1):
        for u in range((lx1 - lx0) * res):
            x = (HP0 + lx0) * 4 + u * sw
            img[v, x:x + sw] = fn(u, v)
    regions.append(dict(name=name, res=res, lx0=lx0, lx1=lx1, v0=v0, v1=v1, kind=kind, **(meta or {})))

def text(name, res, lx0, v0, s, fg, bg):
    n = len(s)
    def fn(u, v):
        ch = s[u // 8]
        return fg if glyph(ch)[v - v0][u % 8] else bg
    patch(name, res, lx0, lx0 + (n * 8) // res, v0, v0 + 8, fn, 'text')

def section(res, V):
    tag = 'lo' if res == 1 else 'hi'
    # ---- L1: two-colour 50 % dithers, refs below (linear mix, gamma mix)
    pairs = [('chk_bw', 'checker', c12(0x000), c12(0xFFF)),
             ('chk_rb', 'checker', c12(0xF00), c12(0x00F)),
             ('chk_close', 'checker', c12(0x469), c12(0x68B)),
             ('col_bw', 'column', c12(0x000), c12(0xFFF)),
             ('chk_gm', 'checker', c12(0x0F0), c12(0xF0F)),
             ('col_rb', 'column', c12(0xF00), c12(0x00F))]
    for i, (nm, k, a, b) in enumerate(pairs):
        lx0 = 12 + i * 58; lx1 = lx0 + 48
        if k == 'checker':
            fn = lambda u, v, a=a, b=b: b if (u + v) % 2 else a
        else:
            fn = lambda u, v, a=a, b=b: b if u % 2 else a
        patch('%s_%s' % (nm, tag), res, lx0, lx1, V, V + 20, fn, 'dither50',
              dict(c1=a, c2=b, lin=linmix(a, b, .5), gam=gammix(a, b, .5)))
        lm, gm = linmix(a, b, .5), gammix(a, b, .5)
        patch('%s_%s_lin' % (nm, tag), res, lx0, lx1, V + 20, V + 24, lambda u, v, c=lm: c, 'ref')
        patch('%s_%s_gam' % (nm, tag), res, lx0, lx1, V + 24, V + 28, lambda u, v, c=gm: c, 'ref')
    # ---- L2: ordered-dither wedges 0/25/50/75/100 % (Bayer 2x2) and a Bayer 4x4 ramp
    V2 = V + 32
    for nm, lx0, a, b in (('wedge_bw', 4, c12(0x000), c12(0xFFF)),
                          ('wedge_blue', 112, c12(0x226), c12(0x88E))):
        for st in range(5):
            t = st / 4
            fn = lambda u, v, a=a, b=b, t=t: b if BAYER2[v % 2, u % 2] < 4 * t else a
            x0 = lx0 + st * 20
            patch('%s%d_%s' % (nm, st * 25, tag), res, x0, x0 + 20, V2, V2 + 16, fn, 'wedge',
                  dict(c1=a, c2=b, t=t, lin=linmix(a, b, t), gam=gammix(a, b, t)))
            patch('%s%d_%s_lin' % (nm, st * 25, tag), res, x0, x0 + 20, V2 + 16, V2 + 20, lambda u, v, c=linmix(a, b, t): c, 'ref')
            patch('%s%d_%s_gam' % (nm, st * 25, tag), res, x0, x0 + 20, V2 + 20, V2 + 24, lambda u, v, c=gammix(a, b, t): c, 'ref')
    a, b = c12(0x000), c12(0xFFF)
    n = 140 * res
    def ramp(u, v):
        t = u / (n - 1)
        return b if BAYER4[v % 4, u % 4] + 0.5 < 16 * t else a
    patch('ramp4_%s' % tag, res, 218, 358, V2, V2 + 16, ramp, 'ramp')
    patch('ramp4_%s_lin' % tag, res, 218, 358, V2 + 16, V2 + 20, lambda u, v: linmix(a, b, u / (n - 1)), 'ref')
    patch('ramp4_%s_gam' % tag, res, 218, 358, V2 + 20, V2 + 24, lambda u, v: gammix(a, b, u / (n - 1)), 'ref')
    # ---- L3: game art: Bayer-dithered sky with hills and sun; dithered colour gradient
    V3 = V + 58
    sky = [c12(x) for x in (0x113, 0x225, 0x337, 0x459, 0x68B, 0x9BD, 0xEC9, 0xF94)]
    hill, hill2 = c12(0x231), c12(0x452)
    sun, sun2 = c12(0xFF8), c12(0xFC4)
    nw = 180 * res
    def art(u, v):
        y = v - V3                          # 0..39 lines
        xw = u / res                         # lowres units 0..180
        # sun: disc + dithered halo
        dx, dy = (xw - 130) * 1.0, (y - 22) * 1.0
        rr = dx * dx + dy * dy
        hy = 30 + 5 * np.sin(xw / 17.0) + 3 * np.sin(xw / 5.3)
        if y >= hy:
            # hill, Bayer highlight on the top rows
            t = max(0.0, 1 - (y - hy) / 6)
            return hill2 if BAYER4[v % 4, u % 4] < 16 * t * 0.75 else hill
        if rr <= 36: return sun
        if rr <= 100:
            t = (100 - rr) / 64
            if BAYER4[v % 4, u % 4] < 16 * t: return sun2
        s = y / 31 * (len(sky) - 1)
        i = min(int(s), len(sky) - 2); f = s - i
        return sky[i + 1] if BAYER4[v % 4, u % 4] < 16 * f else sky[i]
    patch('art_%s' % tag, res, 4, 184, V3, V3 + 40, art, 'art')
    rain = [c12(x) for x in (0xF00, 0xF80, 0xFF0, 0x0F0, 0x0FF, 0x00F, 0x80F, 0xF0F)]
    ng = 168 * res
    def grad(u, v):
        s = u / ng * (len(rain) - 1)
        i = min(int(s), len(rain) - 2); f = s - i
        return rain[i + 1] if BAYER4[v % 4, u % 4] < 16 * f else rain[i]
    patch('grad_%s' % tag, res, 190, 358, V3, V3 + 18, grad, 'grad')
    fire = [c12(x) for x in (0x200, 0x810, 0xE60, 0xFE8)]
    def grad2(u, v):
        s = u / ng * (len(fire) - 1)
        i = min(int(s), len(fire) - 2); f = s - i
        return fire[i + 1] if BAYER4[v % 4, u % 4] < 16 * f else fire[i]
    patch('grad2_%s' % tag, res, 190, 358, V3 + 20, V3 + 40, grad2, 'grad')
    # ---- L4: Topaz-like text, then an edge target
    V4 = V + 100
    cols = 45 * res
    s1 = ('1> dir df0: The quick brown fox jumps over 13 lazy dogs. AmigaDOS topaz.font 8 ' * 3)[:cols]
    s2 = ('Workbench 1.3  RAM: DH0: System Trash  Insert disk  !@#$%^&*()  ' * 3)[:cols]
    s3 = ('Workbench 2.0 style: black on grey  ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ' * 3)[:cols]
    text('txt_wb_%s' % tag, res, 0, V4, s1, c12(0xFFF), c12(0x05A))
    text('txt_or_%s' % tag, res, 0, V4 + 9, s2, c12(0xF80), c12(0x05A))
    text('txt_gy_%s' % tag, res, 0, V4 + 18, s3, c12(0x000), c12(0xAAA))
    patch('edge_%s' % tag, res, 40, 280, V4 + 27, V4 + 32,
          lambda u, v: c12(0xFFF) if 120 * res <= u < 200 * res else c12(0x000), 'edge',
          dict(e0=40 + 120, e1=40 + 200))
    if res == 2:
        hires_line[V:V4 + 34] = 1

section(1, 30)
section(2, 166)

O = sys.argv[1] if len(sys.argv) > 1 else 'build'
os.makedirs(O, exist_ok=True)
with open(O + '/dither.hex', 'w') as f:
    for v in range(H):
        f.write(''.join('%02x%02x%02x\n' % tuple(img[v, x]) for x in range(W)))
with open(O + '/dither_hires.hex', 'w') as f:
    f.write(''.join('%x\n' % h for h in hires_line))
json.dump(regions, open(O + '/dither_regions.json', 'w'), indent=0)
from PIL import Image
Image.fromarray(np.repeat(img, 2, axis=0)).save(O + '/dither_source.png')
print('regions', len(regions), 'hires lines', hires_line.sum())
