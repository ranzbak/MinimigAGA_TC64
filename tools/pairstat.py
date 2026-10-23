#!/usr/bin/env python3
"""Dual-issue statistics from tools/vivado/ila_pairstat.tcl captures.

    tools/pairstat.py <out-prefix>

Counter layout and sample format: rtl/soc/ap68040_minimig.sv (PSTAT).  D1's
counts include wrong-path instructions; the retire counts do not.
"""
import collections
import glob
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib', 'AP68040-faster', 'tools'))
import isa  # noqa: E402

NAMES = ['clocks', 'retired', 'retired2', 'start', 'slow', 'absent', 'notslot2',
         'companion', 'paired', 'split_dep', 'split_first']
EA = ['Dn', 'An', '(An)', '(An)+', '-(An)', 'd16(An)', 'd8(An,Xn)']
EA7 = ['abs.w', 'abs.l', 'd16(PC)', 'd8(PC,Xn)', '#imm', '?', '?', '?']


def ea(mode, reg):
    return EA[mode] if mode < 7 else EA7[reg]


def label(w):
    """The instruction class of an operation word: mnemonic and EA modes,
    registers left out."""
    if (w & 0xF100) == 0x7000:
        return 'MOVEQ'
    e = isa.lookup(w)
    if e is None:
        return 'ILLEGAL/%04x' % w if (w >> 12) not in (0xA, 0xF) else 'LINE-%X' % (w >> 12)
    n = e.name
    src = ea((w >> 3) & 7, w & 7)
    if n in ('MOVE', 'MOVEA'):
        sz = {1: 'B', 3: 'W', 2: 'L'}.get(w >> 12, '?')
        return '%s.%s %s,%s' % (n, sz, src, ea((w >> 6) & 7, (w >> 9) & 7))
    if (w >> 12) in (0x6,) or n in ('DBcc', 'RTS', 'RTE', 'NOP', 'TRAP', 'LINK', 'UNLK'):
        return n
    if (w >> 12) == 0xE:
        return n + (' mem' if ((w >> 6) & 3) == 3 else (' #q' if not (w & 0x20) else ' Dx'))
    return '%s %s' % (n, src)


def rows(path):
    with open(path) as f:
        lines = f.read().splitlines()
    hdr = lines[0].split(',')
    col = [i for i, h in enumerate(hdr) if 'dbg_phist' in h][0]
    for ln in lines[2:]:
        c = ln.split(',')
        if len(c) > col and c[col]:
            yield int(c[col], 16)


def counts(v):
    return [(v >> (32 * i)) & 0xFFFFFFFF for i in range(11)]


def main(prefix):
    snaps = sorted(glob.glob(prefix + '_c*.csv'))
    vals = [counts(next(rows(p))) for p in snaps]
    print('== counters (%d snapshots)' % len(vals))
    for a, b in zip(vals, vals[1:]):
        d = dict(zip(NAMES, [(y - x) & 0xFFFFFFFF for x, y in zip(a, b)]))
        clk = d['clocks'] or 1
        ret = d['retired'] + d['retired2']
        st = d['start'] or 1
        fast = d['start'] - d['slow']
        other = fast - d['absent'] - d['notslot2'] - d['companion']
        print('  %.2f s: %d instructions retired, IPC %.3f (%.1f MIPS at 56.72 MHz)'
              % (clk / 56.71875e6, ret, ret / clk, ret / clk * 56.71875))
        print('  second slot retired %d = %.1f%% of instructions'
              % (d['retired2'], 100.0 * d['retired2'] / (ret or 1)))
        print('  D1 starts %d (wrong path included):' % d['start'])
        for k, n in (('slow (multi-step decode)', d['slow']),
                     ('fast, next word not queued', d['absent']),
                     ('fast, next word not slot-2 class', d['notslot2']),
                     ('fast, other (prediction, fault, BTB)', other),
                     ('companion taken', d['companion'])):
            print('    %-40s %10d  %5.1f%%' % (k, n, 100.0 * n / st))
        cv = d['companion'] or 1
        print('  companions %d: paired %.1f%%, split by dependency %.1f%%, '
              'split because the first may not pair %.1f%%'
              % (d['companion'], 100.0 * d['paired'] / cv, 100.0 * d['split_dep'] / cv,
                 100.0 * d['split_first'] / cv))
    hist = {1: collections.Counter(), 2: collections.Counter(), 3: collections.Counter()}
    pair = collections.Counter()
    for p in sorted(glob.glob(prefix + '_s*.csv')):
        prev = None
        for v in rows(p):
            s = (v >> 352) & 0xFFFFFFFF
            if not (s >> 31) or s == prev:   # a strobe is two ILA clocks
                prev = s
                continue
            prev = s
            kind, w, before = (s >> 29) & 3, s & 0xFFFF, ((s >> 16) & 0x1FFF) << 3
            if kind in hist:
                hist[kind][label(w)] += 1
                if kind == 1:
                    pair['%s -> %s' % (label(before), label(w))] += 1
    for k, t in ((1, 'next word, not slot-2 class'), (2, 'slow-path instructions'),
                 (3, 'first instructions that may not pair')):
        n = sum(hist[k].values())
        print('== %s (%d samples)' % (t, n))
        for name, c in hist[k].most_common(25):
            print('    %-34s %5d  %5.1f%%' % (name, c, 100.0 * c / (n or 1)))
    n = sum(pair.values())
    print('== not-slot-2 pairs: instruction -> next (%d samples)' % n)
    for name, c in pair.most_common(25):
        print('    %-50s %5d  %5.1f%%' % (name, c, 100.0 * c / (n or 1)))


if __name__ == '__main__':
    main(sys.argv[1])
