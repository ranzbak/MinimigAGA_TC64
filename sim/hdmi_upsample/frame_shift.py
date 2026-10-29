#!/usr/bin/env python3
"""frame_shift.py A B [--png OUT.png] -- where B's picture sits against A's.

A and B are 1280 x 720 pictures of tb_crt_frame, each either
  *.hex  a frame dump (+out=PREFIX: PREFIX_<n>.hex, RRGGBB per line, raster
         order): the picture adv_ddr gets, in the signal generator's window
  *.txt  a pin dump (+pins=F): the picture the ADV7511 gets, decoded under
         the pin DE -- one row per DE pulse, two bus words per pixel,
         {r, g[7:4]} with o_clk_pixel low then {g[3:0], b} (see load_pins);
         its DE geometry is printed too
Finds the (dx, dy), dx in -80..80 and dy in -20..20, at which
A[y][x] != B[y + dy][x + dx] for the fewest pixels where either is
non-black (B's picture is A's moved dx right and dy down; outside the
frame is black), the smallest |dx| + |dy| on a tie, and reports the differing pixels left
at that shift: 'appear' (black in A, picture in B), 'vanish' (the
reverse), 'change' (both picture, different), with the rows and columns
they are in.  Exit 0 when no pixel differs at (0, 0), 1 otherwise, 2 on a
bad input.  --png writes A, B and the per-pixel difference at the found
shift side by side (needs PIL).  Needs numpy.
"""
import sys
import numpy as np

W, H = 1280, 720
DXR, DYR = 80, 20


LUT = np.zeros(256, dtype=np.int32)
for _c in b'0123456789abcdef':
    LUT[_c] = int(chr(_c), 16)


def bad(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def read(fn):
    try:
        return np.fromfile(fn, dtype=np.uint8)
    except OSError as e:
        bad('%s: %s' % (fn, e))


def load_hex(fn):
    raw = read(fn)
    if raw.size != W * H * 7:
        bad('%s: not a 1280 x 720 frame dump (lines "RRGGBB")' % fn)
    r = raw.reshape(-1, 7)
    v = np.zeros(W * H, dtype=np.int32)
    for k in range(6):
        v = (v << 4) | LUT[r[:, k]]
    return v.reshape(H, W)


def load_pins(fn, info=True):
    raw = read(fn)
    if raw.size == 0 or raw.size % 12:
        bad('%s: not a pin dump (lines of 12 bytes "C D V H XXX")' % fn)
    r = raw.reshape(-1, 12)
    c, d, v, h = (r[:, k] == ord('1') for k in (0, 2, 4, 6))
    word = (LUT[r[:, 8]] << 8) | (LUT[r[:, 9]] << 4) | LUT[r[:, 10]]
    # edges, the level before the first line taken as low
    rise = lambda s: np.nonzero(s & ~np.concatenate(([False], s[:-1])))[0]
    fall = lambda s: np.nonzero(~s & np.concatenate(([False], s[:-1])))[0]
    de_r, de_f = rise(d), fall(d)
    de_f = de_f[de_f > de_r[0]] if de_r.size else de_f
    n = min(de_r.size, de_f.size)
    if n == 0:
        bad('%s: no complete DE pulse' % fn)
    lens = de_f[:n] - de_r[:n]
    # A line samples the pins just before a clk_148 edge.  pad_de switches
    # on the negedge, the other pins on the posedge: a DE rise first shows
    # in line R, and the bus words it covers show in lines R+1, R+3, ...
    # (one per clk_148).  A pixel is two words, o_clk_pixel low then high:
    # {r, g[7:4]}, {g[3:0], b}.
    pic = np.zeros((H, W), dtype=np.int32)
    k4 = np.arange(W) * 4
    for y in range(min(n, H)):
        if lens[y] != 4 * W:
            continue
        hi = word[de_r[y] + 1 + k4]
        lo = word[de_r[y] + 3 + k4]
        pic[y] = ((hi >> 4) << 16) | (((hi & 0xF) << 4 | (lo >> 8)) << 8) | (lo & 0xFF)
    if info:
        bad_ph = int(np.count_nonzero(c[de_r[:n] + 1]))   # first word with the clock high
        inside = np.zeros(d.size, dtype=bool)
        for y in range(n):
            inside[de_r[y] + 1:de_f[y]:2] = True
        wl = np.zeros(d.size, dtype=bool)
        wl[(de_r[0] + 1) % 2::2] = True                  # the lines that carry the words
        out_de = int(np.count_nonzero(wl & ~inside & (word != 0)))
        # hsync -> DE: half-cycles from the line's hsync rise; vsync -> DE:
        # the first DE line, counting the line the dump starts in (the
        # o_vsync rise) as 0
        hpre = np.searchsorted(hs_r := rise(h), de_r[:n], side='right') - 1
        hoff = de_r[:n] - hs_r[hpre]
        first_line = int(np.searchsorted(hs_r, de_r[0], side='right')) - 1 if n else -1
        hs_f = fall(h)
        hsw = (hs_f[hs_f > hs_r[1]][0] - hs_r[1]) / 4.0 if hs_r.size > 1 else -1
        vs_f = fall(v)
        vsw = int(np.count_nonzero(hs_r < vs_f[0])) if vs_f.size else -1
        lines = sorted(set(np.searchsorted(hs_r, de_r[:n], side='right') - 1))
        print('%s: DE %d pulses x %s pixels, in %d lines (%d..%d); hsync->DE %s half-cycles '
              '(%s pixels); vsync->DE %d lines; hsync %g pixels, vsync %d lines; '
              'DE starting on a clock-high word: %d; non-zero words outside DE: %d'
              % (fn, n, ','.join('%g' % (u / 4.0) for u in np.unique(lens)), len(lines),
                 lines[0], lines[-1], ','.join('%d' % u for u in np.unique(hoff)),
                 ','.join('%g' % (u / 4.0) for u in np.unique(hoff)),
                 first_line, hsw, vsw, bad_ph, out_de))
    return pic


def load(fn):
    return load_pins(fn) if fn.endswith('.txt') else load_hex(fn)


def shifted(b, dx, dy):
    """s[y][x] = b[y + dy][x + dx], black outside"""
    s = np.zeros_like(b)
    ys, yd = (slice(dy, H), slice(0, H - dy)) if dy >= 0 else (slice(0, H + dy), slice(-dy, H))
    xs, xd = (slice(dx, W), slice(0, W - dx)) if dx >= 0 else (slice(0, W + dx), slice(-dx, W))
    s[yd, xd] = b[ys, xs]
    return s


def ranges(idx):
    idx = list(idx)
    if not idx:
        return '-'
    out, a, p = [], idx[0], idx[0]
    for i in idx[1:] + [None]:
        if i is not None and i == p + 1:
            p = i
            continue
        out.append('%d' % a if a == p else '%d..%d' % (a, p))
        if i is not None:
            a = p = i
    return ' '.join(out[:12]) + (' ... (%d ranges)' % len(out) if len(out) > 12 else '')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    png = None
    if '--png' in sys.argv:
        png = sys.argv[sys.argv.index('--png') + 1]
        args.remove(png)
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    a, b = load(args[0]), load(args[1])
    an, bn = a != 0, b != 0
    span = lambda m: '%d..%d' % tuple(np.nonzero(m)[0][[0, -1]]) if m.any() else '-'
    print('A: %d non-black pixels, rows %s, columns %s; B: %d, rows %s, columns %s'
          % (an.sum(), span(an.any(1)), span(an.any(0)), bn.sum(), span(bn.any(1)), span(bn.any(0))))
    # every shift in the range, scored on the pixels where either is non-black
    best = None
    for dy in range(-DYR, DYR + 1):
        for dx in range(-DXR, DXR + 1):
            s = shifted(b, dx, dy)
            m = (a != 0) | (s != 0)
            bad = int(np.count_nonzero((a != s) & m))
            key = (bad, abs(dx) + abs(dy))
            if best is None or key < best[0]:
                best = (key, dx, dy)
    (bad, _), dx, dy = best
    s = shifted(b, dx, dy)
    diff = a != s
    app = diff & (a == 0)
    van = diff & (s == 0)
    chg = diff & (a != 0) & (s != 0)
    print('shift dx %+d dy %+d: %d pixels differ (appear %d, vanish %d, change %d)'
          % (dx, dy, diff.sum(), app.sum(), van.sum(), chg.sum()))
    for nm, mk in (('appear', app), ('vanish', van), ('change', chg)):
        if mk.any():
            print('  %-6s rows %s' % (nm, ranges(np.nonzero(mk.any(1))[0])))
            print('  %-6s cols %s' % (nm, ranges(np.nonzero(mk.any(0))[0])))
    if (dx, dy) != (0, 0):
        z = int(np.count_nonzero(a != b))
        print('at (0, 0): %d pixels differ' % z)
    if png:
        from PIL import Image
        rgb = lambda p: np.stack([(p >> 16) & 255, (p >> 8) & 255, p & 255], -1).astype(np.uint8)
        dimg = np.zeros((H, W, 3), dtype=np.uint8)
        dimg[app] = (0, 255, 0)
        dimg[van] = (255, 0, 0)
        dimg[chg] = (255, 255, 0)
        Image.fromarray(np.concatenate([rgb(a), rgb(s), dimg], 1)).save(png)
        print('png %s (A | B moved back by the shift | appear green, vanish red, change yellow)' % png)
    sys.exit(0 if (dx, dy) == (0, 0) and bad == 0 else 1)


if __name__ == '__main__':
    main()
