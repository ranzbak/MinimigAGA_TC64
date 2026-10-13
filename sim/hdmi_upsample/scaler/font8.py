"""Hand-drawn 8x8 bitmap font, Topaz-8-like weight (2-pixel vertical stems).
Typed in for this study (no font file read or downloaded).  Rows top to
bottom, MSB = leftmost pixel."""
import numpy as np

_HEX = r"""
20 00 00 00 00 00 00 00 00
21 30 78 78 30 30 00 30 00
22 6C 6C 6C 00 00 00 00 00
23 6C 6C FE 6C FE 6C 6C 00
24 30 7C C0 78 0C F8 30 00
25 00 C6 CC 18 30 66 C6 00
26 38 6C 38 76 DC CC 76 00
27 60 60 C0 00 00 00 00 00
28 18 30 60 60 60 30 18 00
29 60 30 18 18 18 30 60 00
2A 00 66 3C FF 3C 66 00 00
2B 00 30 30 FC 30 30 00 00
2C 00 00 00 00 00 30 30 60
2D 00 00 00 FC 00 00 00 00
2E 00 00 00 00 00 30 30 00
2F 06 0C 18 30 60 C0 80 00
30 7C C6 CE DE F6 E6 7C 00
31 30 70 30 30 30 30 FC 00
32 78 CC 0C 38 60 CC FC 00
33 78 CC 0C 38 0C CC 78 00
34 1C 3C 6C CC FE 0C 1E 00
35 FC C0 F8 0C 0C CC 78 00
36 38 60 C0 F8 CC CC 78 00
37 FC CC 0C 18 30 30 30 00
38 78 CC CC 78 CC CC 78 00
39 78 CC CC 7C 0C 18 70 00
3A 00 30 30 00 00 30 30 00
3B 00 30 30 00 00 30 30 60
3C 18 30 60 C0 60 30 18 00
3D 00 00 FC 00 00 FC 00 00
3E 60 30 18 0C 18 30 60 00
3F 78 CC 0C 18 30 00 30 00
40 7C C6 DE DE DE C0 78 00
41 30 78 CC CC FC CC CC 00
42 FC 66 66 7C 66 66 FC 00
43 3C 66 C0 C0 C0 66 3C 00
44 F8 6C 66 66 66 6C F8 00
45 FE 62 68 78 68 62 FE 00
46 FE 62 68 78 68 60 F0 00
47 3C 66 C0 C0 CE 66 3E 00
48 CC CC CC FC CC CC CC 00
49 78 30 30 30 30 30 78 00
4A 1E 0C 0C 0C CC CC 78 00
4B E6 66 6C 78 6C 66 E6 00
4C F0 60 60 60 62 66 FE 00
4D C6 EE FE FE D6 C6 C6 00
4E C6 E6 F6 DE CE C6 C6 00
4F 38 6C C6 C6 C6 6C 38 00
50 FC 66 66 7C 60 60 F0 00
51 78 CC CC CC DC 78 1C 00
52 FC 66 66 7C 6C 66 E6 00
53 78 CC E0 70 1C CC 78 00
54 FC B4 30 30 30 30 78 00
55 CC CC CC CC CC CC FC 00
56 CC CC CC CC CC 78 30 00
57 C6 C6 C6 D6 FE EE C6 00
58 C6 C6 6C 38 38 6C C6 00
59 CC CC CC 78 30 30 78 00
5A FE C6 8C 18 32 66 FE 00
5B 78 60 60 60 60 60 78 00
5C C0 60 30 18 0C 06 02 00
5D 78 18 18 18 18 18 78 00
5E 10 38 6C C6 00 00 00 00
5F 00 00 00 00 00 00 00 FF
60 30 30 18 00 00 00 00 00
61 00 00 78 0C 7C CC 76 00
62 E0 60 60 7C 66 66 DC 00
63 00 00 78 CC C0 CC 78 00
64 1C 0C 0C 7C CC CC 76 00
65 00 00 78 CC FC C0 78 00
66 38 6C 60 F0 60 60 F0 00
67 00 00 76 CC CC 7C 0C F8
68 E0 60 6C 76 66 66 E6 00
69 30 00 70 30 30 30 78 00
6A 0C 00 0C 0C 0C CC CC 78
6B E0 60 66 6C 78 6C E6 00
6C 70 30 30 30 30 30 78 00
6D 00 00 CC FE FE D6 C6 00
6E 00 00 F8 CC CC CC CC 00
6F 00 00 78 CC CC CC 78 00
70 00 00 DC 66 66 7C 60 F0
71 00 00 76 CC CC 7C 0C 1E
72 00 00 DC 76 66 60 F0 00
73 00 00 7C C0 78 0C F8 00
74 10 30 7C 30 30 34 18 00
75 00 00 CC CC CC CC 76 00
76 00 00 CC CC CC 78 30 00
77 00 00 C6 D6 FE FE 6C 00
78 00 00 C6 6C 38 6C C6 00
79 00 00 CC CC CC 7C 0C F8
7A 00 00 FC 98 30 64 FC 00
7B 1C 30 30 E0 30 30 1C 00
7C 18 18 18 00 18 18 18 00
7D E0 30 30 1C 30 30 E0 00
7E 76 DC 00 00 00 00 00 00
"""

GLYPH = {}
for _ln in _HEX.strip().splitlines():
    _p = _ln.split()
    _rows = [int(v, 16) for v in _p[1:]]
    GLYPH[chr(int(_p[0], 16))] = np.array([[(r >> (7 - c)) & 1 for c in range(8)] for r in _rows], bool)


def text(img, x, y, s, fg, bg=None):
    """draw string s at pixel (x, y) of an HxWx3 uint8 array, clipped"""
    H, W = img.shape[:2]
    for i, ch in enumerate(s):
        g = GLYPH.get(ch, GLYPH['?'])
        x0 = x + 8 * i
        for r in range(8):
            yy = y + r
            if not 0 <= yy < H:
                continue
            for c in range(8):
                xx = x0 + c
                if 0 <= xx < W:
                    if g[r, c]:
                        img[yy, xx] = fg
                    elif bg is not None:
                        img[yy, xx] = bg
