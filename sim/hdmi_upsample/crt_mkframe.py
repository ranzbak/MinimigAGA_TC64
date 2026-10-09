#!/usr/bin/env python3
"""Make the Amiga test frame for tb_crt.v.

The frame is what Denise puts on the RGB pins, on the superhires grid
(28.375 MHz, 4 clk_114 per sample): 312 lines x 1816 samples (227 CCK =
454 lowres = 908 hires = 1816 shres per line).  Blanking (hpos 13..88,
lines 0..25) is black, the border COLOR00, the display window DIW
h 129..448 (lowres), v 44..299.  Writes amiga_frame.hex (RRGGBB per word,
line-major) and amiga_frame.png (the source, 1 shres sample = 1 pixel wide,
lines doubled, for reference).

Bands inside the window (lines relative to DIW top):
   0- 31  lowres colour bars (OCS 12-bit colours)
  32- 47  lowres 16-step grey ramp
  48- 63  lowres 16-step red / green / blue ramps (5 lines each)
  64-119  lowres text, Workbench 1.3 colours, 40 columns, + 1-px lines
 120-183  hires text, 80 columns, + 1-px hires lines and dither
 184-207  superhires text strip (160 columns) -- the capture limit today
 208-255  lowres: diagonal 1-px lines, Boing-style checker, small circle
"""
import gzip, struct, sys
import numpy as np

W, H = 1816, 312
DIW_H0, DIW_H1 = 129, 449          # lowres hpos
DIW_V0, DIW_V1 = 44, 300
HB0, HB1 = 13, 89                   # hblank in lowres hpos
VB = 26                             # vblank lines

def c12(x):                         # OCS $RGB -> 8-bit triple
    return ((x >> 8) & 15) * 17, ((x >> 4) & 15) * 17, (x & 15) * 17

WB_BLUE, WB_WHITE, WB_BLACK, WB_ORANGE = c12(0x05A), c12(0xFFF), c12(0x002), c12(0xF80)

# 8x8 font
d = gzip.open('/usr/share/consolefonts/Lat15-VGA8.psf.gz').read()
FONT = d[4:4 + 256 * 8]
def glyph(ch):
    o = ord(ch) * 8
    return [[(FONT[o + r] >> (7 - c)) & 1 for c in range(8)] for r in range(8)]

img = np.zeros((H, W, 3), np.uint8)

# border = COLOR00 everywhere outside blanking
for v in range(VB, H):
    for x in range(W):
        hp = x // 4
        if not (HB0 <= hp < HB1):
            img[v, x] = WB_BLUE

def put(v, x0, x1, col):            # shres columns [x0, x1)
    img[v, x0:x1] = col

def lowres_px(v, lx, col):          # lowres pixel lx inside DIW
    x = (DIW_H0 + lx) * 4
    img[v, x:x + 4] = col

def hires_px(v, hx, col):
    x = DIW_H0 * 4 + hx * 2
    img[v, x:x + 2] = col

def shres_px(v, sx, col):
    x = DIW_H0 * 4 + sx
    img[v, x] = col

def text(v0, s, res, fg, bg, col0=0):
    """one 8-line text row; res 1 lowres, 2 hires, 4 shres"""
    px = {1: lowres_px, 2: hires_px, 4: shres_px}[res]
    for r in range(8):
        for i, ch in enumerate(s):
            g = glyph(ch)
            for c in range(8):
                px(v0 + r, (col0 + i) * 8 + c, fg if g[r][c] else bg)

def fill_lowres(v, col):
    for lx in range(320):
        lowres_px(v, lx, col)

V = DIW_V0
# window background: WB blue
for v in range(DIW_V0, DIW_V1):
    fill_lowres(v, WB_BLUE)

# 0-31 colour bars
bars = [0xFFF, 0xFF0, 0x0FF, 0x0F0, 0xF0F, 0xF00, 0x00F, 0x000]
for v in range(V, V + 32):
    for lx in range(320):
        lowres_px(v, lx, c12(bars[lx // 40]))
# 32-47 grey ramp
for v in range(V + 32, V + 48):
    for lx in range(320):
        g = lx // 20
        lowres_px(v, lx, c12(g * 0x111))
# 48-63 r/g/b ramps
for k, sh in enumerate((8, 4, 0)):
    for v in range(V + 48 + k * 5, V + 48 + k * 5 + 5):
        for lx in range(320):
            lowres_px(v, lx, c12((lx // 20) << sh))
# 64-119 lowres text
lines_lo = ["Workbench 1.3  Lowres 320x256  40 cols",
            "AMIGA 500  Kickstart 1.3  512K CHIP RAM",
            "1> dir df0:  c/  s/  l/  devs/  libs/",
            "The quick brown fox jumps over 13 dogs.",
            "Insert disk  RAM:  DH0:  System  Trash",
            "!@#$%^&*()_+-=[]{};':\",./<>?|\\~`  0123"]
for i, s in enumerate(lines_lo):
    fg = WB_ORANGE if i == 1 else WB_WHITE
    text(V + 64 + i * 9, s.ljust(40)[:40], 1, fg, WB_BLUE)
# 1-px lowres features under the text: vertical lines, checker
for v in range(V + 118, V + 120):
    for lx in range(320):
        lowres_px(v, lx, WB_WHITE if lx % 2 == 0 else WB_BLACK)
# 120-183 hires text
lines_hi = ["Workbench 1.3 hires 640x256, 80 columns: the CLI and Workbench text font on a 1084S",
            "1> list sys:c  Assign  Copy  Delete  Dir  Ed  Execute  Format  Info  Install  Join",
            "AmigaDOS  topaz.font 8  The quick brown fox jumps over the lazy dog.  0123456789",
            "!@#$%^&*()_+-=[]{};':\",./<>?|\\~`  ABCDEFGHIJKLMNOPQRSTUVWXYZ  abcdefghijklmnopq"]
for i, s in enumerate(lines_hi):
    fg = WB_ORANGE if i == 2 else WB_WHITE
    text(V + 120 + i * 9, s.ljust(80)[:80], 2, fg, WB_BLUE)
for v in range(V + 156, V + 184):
    for hx in range(640):
        b = (v - V - 156)
        if b < 8:   col = WB_WHITE if hx % 2 == 0 else WB_BLACK          # 1-px hires columns
        elif b < 16: col = WB_WHITE if (hx + v) % 2 == 0 else WB_BLACK   # hires checker (WB2 dither)
        elif b < 24: col = WB_WHITE if (hx // 2) % 2 == 0 else WB_BLUE   # 2-px stripes
        else:       col = WB_BLUE
        hires_px(v, hx, col)
# 184-207 superhires text
lines_sh = ["Superhires 1280: today's capture samples ~0.8 times per shres pixel; this strip aliases. ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
            "0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 012345678"]
for i, s in enumerate(lines_sh):
    text(V + 186 + i * 10, s.ljust(160)[:160], 4, WB_WHITE, WB_BLUE)
# 208-255: diagonals, checker ball, circle
for v in range(V + 208, V + 256):
    y = v - V - 208
    for lx in range(320):
        col = WB_BLUE
        if lx < 96:
            if (lx - y) % 12 == 0 or (lx + y) % 12 == 0: col = WB_WHITE
        elif lx < 208:
            cx, cy, r = 152, 24, 23
            dx, dy = lx - cx, y - cy
            if dx * dx + dy * dy <= r * r:
                col = c12(0xF00) if ((lx // 8) + (y // 8)) % 2 == 0 else c12(0xFFF)
            else:
                col = c12(0x888) if (lx % 8 == 0 or y % 8 == 0) else c12(0xAAA)
        else:
            dx, dy = lx - 264, y - 24
            dd = dx * dx + dy * dy
            if 18 * 18 <= dd <= 20 * 20: col = WB_ORANGE
            elif dd < 10 * 10: col = c12(0x0F0)
        lowres_px(v, lx, col)

with open('amiga_frame.hex', 'w') as f:
    for v in range(H):
        for x in range(W):
            r, g, b = img[v, x]
            f.write('%02x%02x%02x\n' % (r, g, b))
try:
    from PIL import Image
    Image.fromarray(np.repeat(img, 2, axis=0)).save('amiga_frame_source.png')
except Exception as e:
    print('png:', e)
print('wrote amiga_frame.hex', H, 'x', W)
