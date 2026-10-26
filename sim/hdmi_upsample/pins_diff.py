#!/usr/bin/env python3
"""pins_diff.py A B -- compare two pin dumps of tb_crt_frame (+pins=F).

Each dump has one line per clk_148 half-cycle, 'C D V H XXX' (pal_to_ddr's
o_clk_pixel o_de o_vsync o_hsync o_data).  Finds the constant offset k
(half-cycles, -64..+64) at which B matches A best: line i of A against line
i + k of B (k > 0: B's pins come k half-cycles later), over the lines both
have.  The dumps' lengths may differ by up to |k|; a length difference
beyond that counts as that many more differing lines.  Prints
'offset k: N of M lines differ' for the best k (the fewest N, the smallest
|k| on a tie) and the first 10 differing lines; exits 0 only when N == 0,
printing 'IDENTICAL' (k == 0) or 'UNIFORM SHIFT k'.  Needs numpy.
"""
import sys
import numpy as np

KMAX = 64

def load(fn, ids):
    with open(fn) as f:
        return np.array([ids.setdefault(l.rstrip('\n'), len(ids)) for l in f], dtype=np.int32)

def mismatches(a, b, k):
    """(differing overlap positions in A, overlap length, excess length) at offset k"""
    lo, hi = max(0, -k), min(len(a), len(b) - k)
    if hi <= lo:
        return np.arange(0), 0, abs(len(a) - len(b))
    d = np.nonzero(a[lo:hi] != b[lo + k:hi + k])[0] + lo
    return d, hi - lo, max(0, abs(len(a) - len(b)) - abs(k))

def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().split('\n')[0]); sys.exit(2)
    ids = {}
    a, b = load(sys.argv[1], ids), load(sys.argv[2], ids)
    best = None
    for k in sorted(range(-KMAX, KMAX + 1), key=abs):
        d, m, ex = mismatches(a, b, k)
        n = len(d) + ex
        if best is None or n < best[0]:
            best = (n, k, d, m, ex)
        if n == 0:
            break
    n, k, d, m, ex = best
    print('%s: %d lines, %s: %d lines' % (sys.argv[1], len(a), sys.argv[2], len(b)))
    print('offset %d: %d of %d lines differ' % (k, n, m + ex))
    if ex:
        print('  lengths differ by %d, %d more than |k|' % (abs(len(a) - len(b)), ex))
    if len(d):
        print('  first differing lines (A line / B line, 1-based): ' +
              ' '.join('%d/%d' % (i + 1, i + k + 1) for i in d[:10]))
    if n == 0:
        print('IDENTICAL' if k == 0 else 'UNIFORM SHIFT %d' % k)
        sys.exit(0)
    sys.exit(1)

if __name__ == '__main__':
    main()
