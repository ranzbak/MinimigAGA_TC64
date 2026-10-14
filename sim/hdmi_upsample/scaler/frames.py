"""Source frames for the scaler comparison (all drawn here, except the two
real 16-colour pictures read from ~/work/amiga/PyDPainter/images).

native_frame(n)   720 x n hires-grid Amiga frame (n = 288 PAL, 240 NTSC):
                  3 rows x 2 regions, lowres content pixel-doubled.
rtg_frame(W, H)   Workbench-style desktop at W x H, 2 x 3 panels.
scroll_frame(...) the 1-px line pattern for the scroll test.
Each returns (img uint8 HxWx3, regions {name: (x0, y0, w, h, ax, ay)})
where (ax, ay) is the source point the comparison crop starts at.
"""
import os
import numpy as np
from PIL import Image
from font8 import text

def c12(x):
    return np.array((((x >> 8) & 15) * 17, ((x >> 4) & 15) * 17, (x & 15) * 17), np.uint8)

BLACK, WHITE = c12(0x000), c12(0xFFF)
# Workbench 1.3 and 3.x palettes
W13_BLUE, W13_WHITE, W13_BLACK, W13_ORANGE = c12(0x05A), c12(0xFFF), c12(0x002), c12(0xF80)
W3_GREY, W3_BLACK, W3_WHITE, W3_BLUE = c12(0xAAA), c12(0x000), c12(0xFFF), c12(0x68B)

BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]])
IMGDIR = os.path.expanduser('~/work/amiga/PyDPainter/images')


def canvas(w, h, col):
    a = np.zeros((h, w, 3), np.uint8)
    a[:] = col
    return a

def rect(a, x0, y0, x1, y1, col):          # inclusive corners
    a[max(0, y0):y1 + 1, max(0, x0):x1 + 1] = col

def frame(a, x0, y0, x1, y1, col):
    a[y0, x0:x1 + 1] = col; a[y1, x0:x1 + 1] = col
    a[y0:y1 + 1, x0] = col; a[y0:y1 + 1, x1] = col

def bevel(a, x0, y0, x1, y1, raised=True, lt=W3_WHITE, dk=W3_BLACK):
    t, b = (lt, dk) if raised else (dk, lt)
    a[y0, x0:x1 + 1] = t; a[y0:y1 + 1, x0] = t
    a[y1, x0:x1 + 1] = b; a[y0:y1 + 1, x1] = b


# ---------------------------------------------------------------- GUIs
def gui_wb3(w, h, title='Workbench 3.1', lines=None, shell=False):
    """Workbench 3.x style window: 1-px bevels, blue title bar, list view
    with a selected row, scroll bar, two buttons."""
    a = canvas(w, h, W3_GREY)
    x0, y0, x1, y1 = 1, 1, w - 2, h - 2
    bevel(a, x0, y0, x1, y1)
    rect(a, x0 + 1, y0 + 1, x1 - 1, y0 + 10, W3_BLUE)          # title bar 10 rows
    a[y0 + 11, x0 + 1:x1] = W3_BLACK
    # close gadget
    rect(a, x0 + 1, y0 + 1, x0 + 18, y0 + 10, W3_GREY)
    bevel(a, x0 + 1, y0 + 1, x0 + 18, y0 + 10)
    rect(a, x0 + 7, y0 + 4, x0 + 12, y0 + 7, W3_WHITE)
    frame(a, x0 + 7, y0 + 4, x0 + 12, y0 + 7, W3_BLACK)
    text(a, x0 + 24, y0 + 2, title, W3_BLACK)
    # depth gadget
    gx = x1 - 20
    rect(a, gx, y0 + 1, x1 - 1, y0 + 10, W3_GREY)
    bevel(a, gx, y0 + 1, x1 - 1, y0 + 10)
    frame(a, gx + 4, y0 + 3, gx + 12, y0 + 7, W3_BLACK)
    rect(a, gx + 8, y0 + 5, gx + 16, y0 + 9, W3_WHITE)
    frame(a, gx + 8, y0 + 5, gx + 16, y0 + 9, W3_BLACK)
    # scroll bar
    sx0, sx1 = x1 - 13, x1 - 2
    sy0, sy1 = y0 + 14, y1 - 22
    bevel(a, sx0, sy0, sx1, sy1, raised=False)
    ky1 = sy0 + 2 + max(8, (sy1 - sy0) // 3)
    rect(a, sx0 + 2, sy0 + 2, sx1 - 2, ky1, W3_GREY)
    bevel(a, sx0 + 2, sy0 + 2, sx1 - 2, ky1)
    # list view
    lx0, ly0, lx1, ly1 = x0 + 5, y0 + 14, sx0 - 4, y1 - 22
    bevel(a, lx0, ly0, lx1, ly1, raised=False)
    bg = W3_GREY if shell else W3_WHITE
    rect(a, lx0 + 1, ly0 + 1, lx1 - 1, ly1 - 1, bg)
    lines = lines or ['Workbench  3.1 hires', 'Disk  Prefs  Tools', 'System    Utilities',
                      'The quick brown fox', 'jumps over 13 dogs.', 'RAM: 1,234,567 free',
                      'DH0: Work  CD0: CDDA', 'abcdefghijklmnopqrst', 'ABCDEFGHIJKLMNOPQRST',
                      '0123456789 !@#$%&*()', 'Topaz 8  80 columns', 'HD lines per pixel?']
    ncols = max(1, (lx1 - lx0 - 4) // 8)
    y = ly0 + 2
    for i, s in enumerate(lines):
        if y + 9 > ly1:
            break
        if i == 0 and not shell:
            rect(a, lx0 + 1, y - 1, lx1 - 1, y + 8, W3_BLUE)
            text(a, lx0 + 3, y, s[:ncols], W3_WHITE)
        else:
            text(a, lx0 + 3, y, s[:ncols], W3_BLACK)
        y += 9
    # buttons
    by0, by1 = y1 - 18, y1 - 5
    for bx0, lab in ((x0 + 6, 'OK'), (x0 + 6 + 58, 'Cancel')):
        bx1 = bx0 + 54
        if bx1 > x1 - 2:
            break
        bevel(a, bx0, by0, bx1, by1)
        text(a, bx0 + (54 - 8 * len(lab)) // 2, by0 + 3, lab, W3_BLACK)
    # sizing gadget
    bevel(a, x1 - 13, y1 - 12, x1 - 1, y1 - 1)
    for k in range(7):
        a[y1 - 4 - k, x1 - 4 - 6 + k] = W3_BLACK
    a[y1 - 4, x1 - 10:x1 - 3] = W3_BLACK
    return a


def gui_wb13(w, h):
    """Workbench 1.3 style lowres window: white frame, white title bar,
    1-px orange line, white text on blue, a disk icon."""
    a = canvas(w, h, W13_BLUE)
    x0, y0, x1, y1 = 2, 2, w - 3, h - 3
    frame(a, x0, y0, x1, y1, W13_WHITE)
    rect(a, x0 + 1, y0 + 1, x1 - 1, y0 + 10, W13_WHITE)
    # drag bar: 1-px blue stripes right of the title
    for yy in range(y0 + 2, y0 + 10, 2):
        a[yy, x0 + 100:x1 - 22] = W13_BLUE
    rect(a, x0 + 1, y0 + 1, x0 + 12, y0 + 10, W13_BLUE)         # close gadget
    rect(a, x0 + 4, y0 + 4, x0 + 9, y0 + 7, W13_WHITE)
    rect(a, x0 + 6, y0 + 5, x0 + 7, y0 + 6, W13_BLACK)
    text(a, x0 + 16, y0 + 2, 'AmigaDOS', W13_BLUE)
    for k, gx in enumerate((x1 - 21, x1 - 11)):                   # depth gadgets
        rect(a, gx, y0 + 1, gx + 10, y0 + 10, W13_BLUE)
        frame(a, gx + 2, y0 + 3, gx + 6, y0 + 6, W13_WHITE if k else W13_BLACK)
        rect(a, gx + 4, y0 + 5, gx + 8, y0 + 8, W13_BLACK if k else W13_WHITE)
    a[y0 + 11, x0 + 1:x1] = W13_ORANGE
    lines = ['1> dir df0:', ' c  s  l  devs', ' libs  fonts', '1> echo "Hi!"',
             'Workbench 1.3', '512K CHIP RAM', 'Topaz 8 lowres', 'ABCDEFGHIJKLMN']
    y = y0 + 14
    for s in lines:
        if y + 8 > y1 - 1:
            break
        text(a, x0 + 4, y, s[:(x1 - x0 - 6) // 8], W13_WHITE)
        y += 9
    # disk icon bottom right
    ix, iy = x1 - 34, y1 - 30
    if ix > x0 + 120 or h > 60:
        rect(a, ix, iy, ix + 24, iy + 22, W13_BLACK)
        rect(a, ix + 1, iy + 1, ix + 23, iy + 21, W13_WHITE)
        rect(a, ix + 6, iy + 1, ix + 18, iy + 7, W13_BLACK)
        rect(a, ix + 13, iy + 2, ix + 16, iy + 6, W13_WHITE)
        rect(a, ix + 4, iy + 11, ix + 20, iy + 21, W13_ORANGE)
        for yy in range(iy + 13, iy + 21, 2):
            a[yy, ix + 6:ix + 19] = W13_BLUE
    return a


# --------------------------------------------------------- pixel art
SPRITE = ["....KKKK....",
          "...KRRRRK...",
          "..KRRRRRRK..",
          "..KSSKSSK...",
          "..KSSSSSSK..",
          "...KSSSSK...",
          "..KBBRRBBK..",
          ".KBBBRRBBBK.",
          "KSKBBBBBBKSK",
          "KSKBBBBBBKSK",
          ".K.KBBBBK.K.",
          "...KBBBBK...",
          "...KBK.KBK..",
          "..KBBK.KBBK.",
          "..KKKK.KKKK.",
          "............"]
SPR_COL = {'K': c12(0x000), 'R': c12(0xD22), 'S': c12(0xFCA), 'B': c12(0x22C)}

def pixel_art(w, h):
    """game-like scene: Bayer-dithered sky, sun, mountains with 1:1 and 1:2
    diagonals and checker shading, 50 % checker-dithered grass, brick wall,
    1-px diagonal rope and laser, Boing-style ball, a sprite."""
    a = canvas(w, h, BLACK)
    sky = [c12(0x113), c12(0x25A), c12(0x6BF)]
    hz = int(0.62 * h)
    yy, xx = np.mgrid[0:h, 0:w]
    t = np.clip(yy / max(1, hz - 1), 0, 1) * 2
    seg = np.minimum(t.astype(int), 1)
    f = t - seg
    thr = (BAYER4[yy % 4, xx % 4] + 0.5) / 16
    upper = f > thr
    c0 = np.array(sky)[seg]
    c1 = np.array(sky)[seg + 1]
    a[:] = np.where(upper[..., None], c1, c0)
    # sun
    cx, cy, r = int(0.82 * w), int(0.2 * h), max(5, int(0.1 * h))
    d2 = (xx - cx) ** 2 + (yy - cy) ** 2
    a[d2 <= r * r] = c12(0xF90)
    a[(d2 <= r * r) & (d2 > (r - 1) ** 2)] = c12(0xFF4)
    # mountains: peaks with slopes 1:1 (left) and 1:2 (right)
    top = np.full(w, hz, float)
    for px, ph in ((0.15, 0.30), (0.42, 0.18), (0.70, 0.34)):
        X, P = px * w, ph * h
        left = P + (X - np.arange(w))          # slope 1
        right = P + (np.arange(w) - X) / 2     # slope 1/2
        top = np.minimum(top, np.where(np.arange(w) < X, left, right))
    mt = (yy >= top[None, :]) & (yy < hz)
    shade = mt & (xx > 0) & ((xx + yy) % 2 == 0) & (np.arange(w)[None, :] % 97 > 48)
    a[mt] = c12(0x636)
    a[shade] = c12(0x424)
    edge = (np.abs(yy - np.ceil(top[None, :])) < 1) & (yy < hz)
    a[edge] = c12(0xC9C)
    # ground: checker-dither band (50 %) then solid
    g = yy >= hz
    a[g] = c12(0x272)
    band = g & (yy < hz + max(4, h // 10))
    a[band & ((xx + yy) % 2 == 0)] = c12(0x5C5)
    # brick wall bottom-left
    bx0, by0, bx1, by1 = 2, hz + h // 10 + 2, int(0.32 * w), h - 2
    if by1 > by0 + 4:
        sub = a[by0:by1, bx0:bx1]
        sy, sx = np.mgrid[0:by1 - by0, 0:bx1 - bx0]
        mort = (sy % 5 == 4) | (((sx + 4 * ((sy // 5) % 2)) % 8) == 7)
        sub[:] = np.where(mort[..., None], c12(0x111), c12(0xB42))
    # Boing-style ball
    bcx, bcy, br = int(0.5 * w), int(0.55 * h), max(6, int(0.17 * h))
    bd = (xx - bcx) ** 2 + (yy - bcy) ** 2 <= br * br
    chk = (((xx - bcx + 64) // 4) + ((yy - bcy + 64) // 4)) % 2 == 0
    a[bd & chk] = c12(0xE11)
    a[bd & ~chk] = WHITE
    # 1-px diagonals: rope slope 1/3 and 45 deg laser
    for x in range(int(0.05 * w), int(0.45 * w)):
        y = int(2 + (x - 0.05 * w) / 3)
        if 0 <= y < h:
            a[y, x] = c12(0xDB7)
    for k in range(int(0.3 * h)):
        x, y = int(0.62 * w) + k, int(0.08 * h) + k
        if x < w and y < h:
            a[y, x] = c12(0x0FF)
    # sprite
    sx0, sy0 = int(0.7 * w), hz - 6
    for r_, row in enumerate(SPRITE):
        for c_, ch in enumerate(row):
            if ch in SPR_COL and 0 <= sy0 + r_ < h and 0 <= sx0 + c_ < w:
                a[sy0 + r_, sx0 + c_] = SPR_COL[ch]
    return a


# --------------------------------------------------------- line test
def line_test(w, h):
    """columns: 1-px white lines spacing 2/3/4, black lines on white,
    1x1 and 2x2 checker, vertical 1-px lines, 8-px grid + diagonal"""
    a = canvas(w, h, BLACK)
    n = 8
    cw = w // n
    labels = ['2', '3', '4', 'B4', 'c1', 'c2', 'V', 'G']
    yy, xx = np.mgrid[0:h, 0:cw]
    for i in range(n):
        x0 = i * cw
        y0 = 10
        sub = a[y0:, x0:x0 + cw - 2]
        Y, X = yy[:h - y0, :cw - 2], xx[:h - y0, :cw - 2]
        if i < 3:
            m = (Y % (i + 2)) == 0
            sub[m] = WHITE
        elif i == 3:
            sub[:] = WHITE
            sub[(Y % 4) == 0] = BLACK
        elif i == 4:
            sub[((X + Y) % 2) == 0] = WHITE
        elif i == 5:
            sub[((X // 2 + Y // 2) % 2) == 0] = WHITE
        elif i == 6:
            sub[(X % 2) == 0] = WHITE
        else:
            sub[((X % 8) == 0) | ((Y % 8) == 0)] = c12(0x888)
            sub[(X == Y) | (X == Y // 2)] = WHITE
        a[y0:, x0 + cw - 2:x0 + cw] = c12(0x333)
        text(a, x0 + 2, 1, labels[i], c12(0x888))
    return a


# ------------------------------------------------------ colour/gamma
def hsv_row(n):
    hh = np.linspace(0, 6, n, endpoint=False)
    i = hh.astype(int); f = hh - i
    v = np.ones(n); p = np.zeros(n); q = 1 - f; t = f
    r = np.choose(i, [v, q, p, p, t, v]); g = np.choose(i, [t, v, v, q, p, p]); b = np.choose(i, [p, p, t, v, v, q])
    return np.round(255 * np.stack([r, g, b], -1)).astype(np.uint8)

def colour_test(w, h):
    """hue sweep and grey ramp on top; below on black, from the left (the
    first ~96 px are what the comparison crop shows): 1-px R, G, B, W lines
    (every 3rd line), alternating 1-px red/green lines, patch g = gamma-space
    average of R+G (128,128,0), patch L = linear-light average (186,186,0);
    then Y, C, M lines, blue/yellow stripes, a red/green 1x1 checker."""
    a = canvas(w, h, BLACK)
    h1 = max(6, int(0.18 * h)); h2 = h1 + max(4, int(0.09 * h))
    a[:h1] = hsv_row(w)[None]
    ramp = np.round(np.linspace(0, 255, w)).astype(np.uint8)
    a[h1:h2] = ramp[None, :, None]
    y0 = h2 + 2
    R, Gc, B, Y = c12(0xF00), c12(0x0F0), c12(0x00F), c12(0xFF0)
    x = 0
    for c in (R, Gc, B, WHITE):
        for y in range(y0, h, 3):
            a[y, x:x + 10] = c
        x += 12
    for y in range(y0, h):                               # R/G stripes
        a[y, x:x + 20] = R if y % 2 == 0 else Gc
    x += 22
    a[y0:h, x:x + 12] = (128, 128, 0); text(a, x + 2, y0 + 1, 'g', BLACK)
    a[y0:h, x + 13:x + 25] = (186, 186, 0); text(a, x + 15, y0 + 1, 'L', BLACK)
    x += 28
    for c in (Y, c12(0x0FF), c12(0xF0F)):
        for y in range(y0, h, 3):
            a[y, x:x + 10] = c
        x += 12
    for y in range(y0, h):                               # B/Y stripes
        a[y, x:x + 20] = B if y % 2 == 0 else Y
    x += 22
    yy, xx = np.mgrid[y0:h, x:w]
    a[y0:h, x:w] = np.where(((xx + yy) % 2 == 0)[..., None], R, Gc)
    return a


# --------------------------------------------------- real pictures
def real_defeest(w, h):
    """PyDPainter sample 'defeest-jungle-1' (640x537, 16 colours, made of
    2x2 blocks) -> lowres by taking every 2nd pixel, crop w x h"""
    im = np.array(Image.open(os.path.join(IMGDIR, 'defeest-jungle-1.png')).convert('RGB'))[::2, ::2]
    y0, x0 = 70, 40
    return np.ascontiguousarray(im[y0:y0 + h, x0:x0 + w])

def real_pirate(w, h):
    """PyDPainter sample 'pirate-island-5-640x512x16' 1:1 crop w x h"""
    im = np.array(Image.open(os.path.join(IMGDIR, 'pirate-island-5-640x512x16.png')).convert('RGB'))
    y0 = min(60, im.shape[0] - h); x0 = max(0, min(40, im.shape[1] - w))
    c = im[y0:y0 + h, x0:x0 + w]
    out = canvas(w, h, BLACK)
    out[:c.shape[0], :c.shape[1]] = c
    return out


# --------------------------------------------------------- frames
def native_frame(n):
    """720 x n hires grid.  Row 0: lowres WB1.3 GUI | hires WB3 GUI.
    Row 1: lowres pixel art | lowres real picture.  Row 2: hires line
    test | hires colour test."""
    rh = n // 3
    a = canvas(720, n, BLACK)
    dbl = lambda x: np.repeat(x, 2, axis=1)
    a[0:rh, 0:360] = dbl(gui_wb13(180, rh))
    a[0:rh, 360:720] = gui_wb3(360, rh, title='Workbench Hires')
    a[rh:2 * rh, 0:360] = dbl(pixel_art(180, rh))
    a[rh:2 * rh, 360:720] = dbl(real_defeest(180, rh))
    a[2 * rh:3 * rh, 0:360] = line_test(360, rh)
    a[2 * rh:3 * rh, 360:720] = colour_test(360, rh)
    regions = {
        'gui_lowres': (0, 0, 360, rh, 4, 2),
        'gui_hires': (360, 0, 360, rh, 362, 2),
        'pixelart': (0, rh, 360, rh, 150, rh + 18),
        'real': (360, rh, 360, rh, 470, rh + 10),
        'lines': (0, 2 * rh, 360, rh, 88, 2 * rh + 4),
        'colour': (360, 2 * rh, 360, rh, 358, 2 * rh + int(0.27 * rh) - 6),
    }
    return a, regions


def rtg_frame(W, H):
    a = canvas(W, H, W3_GREY)
    a[0:10] = W3_WHITE
    a[10] = W3_BLACK
    text(a, 4, 1, 'Workbench Screen   RTG %dx%d' % (W, H), W3_BLACK)
    m = 8
    pw = (W - 3 * m) // 2
    ph = (H - 12 - 4 * m) // 3
    pos = lambda i, j: (m + i * (pw + m), 12 + m + j * (ph + m))
    shell_lines = ['1.Work:> dir sys:', '  C (dir)  Devs (dir)  Fonts (dir)',
                   '  L (dir)  Libs (dir)  Prefs (dir)  S (dir)',
                   '  Disk.info  Prefs.info  Utilities.info',
                   '1.Work:> version', 'Kickstart 40.68, Workbench 40.42',
                   '1.Work:> avail', 'Type  Available    In-Use   Maximum',
                   'chip     1879104    218048   2097152', 'fast    10010304    475456  10485760',
                   'total   11889408    693504  12582912', '1.Work:> _']
    panels = {
        'gui': (0, 0, lambda w, h: gui_wb3(w, h, title='Workbench 3.1')),
        'lines': (1, 0, line_test),
        'pixelart': (0, 1, pixel_art),
        'colour': (1, 1, colour_test),
        'real': (0, 2, real_pirate),
        'shell': (1, 2, lambda w, h: gui_wb3(w, h, title='AmigaShell', lines=shell_lines, shell=True)),
    }
    regions = {}
    for name, (i, j, fn) in panels.items():
        x0, y0 = pos(i, j)
        a[y0:y0 + ph, x0:x0 + pw] = fn(pw, ph)
        anchor = {'gui': (x0 - 2, y0 - 2), 'lines': (x0 + 2 * (pw // 8) - 2, y0 + 2), 'pixelart': (x0 + int(0.3 * pw), y0 + int(0.35 * ph)),
                  'colour': (x0 - 2, y0 + int(0.27 * ph) - 6), 'real': (x0 + 60, y0 + 30), 'shell': (x0 + 4, y0 + 10)}[name]
        regions[name] = (x0, y0, pw, ph) + anchor
    return a, regions


def scroll_frame(W, n, s_l, res_lowres=True, text_pitch=10):
    """the scroll test source: 4 blocks of W/4 columns:
    white 1-px lines every s_l on black | black lines on white |
    grey ($888) lines on black | white Topaz text rows on black"""
    a = canvas(W, n, BLACK)
    bw = W // 4
    for y in range(0, n, s_l):
        a[y, 0:bw - 2] = WHITE
        a[y, 2 * bw:3 * bw - 2] = c12(0x888)
    a[:, bw:2 * bw - 2] = WHITE
    for y in range(0, n, s_l):
        a[y, bw:2 * bw - 2] = BLACK
    words = 'Scroll test: does this text breathe? 0123456789 ABCDEFGHIJ'
    if res_lowres:
        t = canvas(bw // 2, n, BLACK)
        for k, y in enumerate(range(1, n - 8, text_pitch)):
            text(t, 1, y, words[(k * 3) % 20:][: (bw // 2) // 8], WHITE)
        a[:, 3 * bw:4 * bw] = np.repeat(t, 2, axis=1)[:, :bw]
    else:
        t = canvas(bw, n, BLACK)
        for k, y in enumerate(range(1, n - 8, text_pitch)):
            text(t, 1, y, words[(k * 3) % 20:][: bw // 8], WHITE)
        a[:, 3 * bw:4 * bw] = t
    return a, bw
