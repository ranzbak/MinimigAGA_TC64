#!/usr/bin/env python3
"""golden.sh's bookkeeping.
  golden.py record LOG ARGS     the leg's records (from frame / field 2 on)
  golden.py check LOG GOLDEN    compare
Records: 'pic N HASH PIXELS' (HD frame N's picture), 'hd N LINES VSYNCS',
'sig N HASH CLOCKS' (the output pins from one o_vsync to the next),
'fsig N HASH CLOCKS' (the output pins during input field N), 'path A B F G'
(a 50/60 Hz path change in HD frame F, input field G; not compared).
Around a path change the designs may differ (the one-frame refill of plan
step 2): pic and hd of HD frames F and F + 1 and fsig of input fields
G - 1 .. G + 1 are skipped.  A leg with a path change after frame 1 skips
the 'sig' records altogether: the two-chain design put out one vsync more
in its 50 -> 60 Hz splice, which renumbers every later one ('fsig' covers
the pins there, by fixed time windows).
GOLDEN_KINDS in the environment (a comma list of pic,hd,sig,fsig; default
all four) limits the kinds check compares; its summary names them.
"""
import os, re, sys

PAT = {'pic': r'pic (\d+): (\w+) (\d+)', 'sig': r'sig (\d+): (\w+) (\d+)',
       'fsig': r'fsig (\d+): (\w+) (\d+)', 'hd': r'hd frame (\d+): (\d+) lines, (\d+) vsync'}
KINDS = ('pic', 'hd', 'sig', 'fsig')

def parse(fn):
    d = {k: {} for k in KINDS}
    paths = []
    for l in open(fn):
        for k, p in PAT.items():
            m = re.match(p, l)
            if m:
                d[k][int(m[1])] = (m[2], m[3])
                break
        m = re.match(r'path (\d+) -> (\d+) at frame (\d+) field (\d+)', l)
        if m: paths.append((m[1], m[2], int(m[3]), int(m[4])))
    return d, paths

def load(fn):
    g = {k: {} for k in KINDS}
    paths = []
    for l in open(fn):
        if l.startswith('#'): continue
        f = l.split()
        if f[0] == 'path': paths.append((f[1], f[2], int(f[3]), int(f[4]))); continue
        g[f[0]][int(f[1])] = tuple(f[2:])
    return g, paths

if __name__ == '__main__':
    cmd, log = sys.argv[1], sys.argv[2]
    d, paths = parse(log)
    if cmd == 'record':
        print('# tb_crt_frame %s (RTL 3987b84, the HDMI path before the scaler work)' % sys.argv[3])
        for p in paths:
            print('path %s %s %d %d' % p)
        for k in KINDS:
            for n in sorted(d[k]):
                if n >= 2:
                    print(k, n, *d[k][n])
        sys.exit(0)
    kinds = [k for k in os.environ.get('GOLDEN_KINDS', '').split(',') if k] or list(KINDS)
    if set(kinds) - set(KINDS):
        print('GOLDEN_KINDS: unknown kind %s (pic,hd,sig,fsig)' % ','.join(sorted(set(kinds) - set(KINDS))))
        sys.exit(2)
    g, gp = load(sys.argv[3])
    skip = {k: set() for k in KINDS}
    for _, _, f, fld in gp + paths:
        if f >= 2:
            skip['pic'] |= {f, f + 1}; skip['hd'] |= {f, f + 1}
            skip['fsig'] |= {fld - 1, fld, fld + 1}
            skip['sig'] |= set(g['sig']) | set(d['sig'])
    bad, cmp = [], 0
    for k in kinds:
        for n in sorted(g[k]):
            if n in skip[k]: continue
            if n not in d[k]:
                bad.append('%s %d missing' % (k, n)); continue
            cmp += 1
            if d[k][n] != g[k][n]:
                bad.append('%s %d' % (k, n))
    np_ = sorted(n for n in g['pic'] if n not in skip['pic'])
    msg = '%d of %d records equal (kinds %s, frames %s' % (cmp - len([b for b in bad if 'missing' not in b]), cmp,
            ','.join(kinds), ','.join(map(str, np_)) if len(np_) < 12 else '%d..%d' % (np_[0], np_[-1]))
    if skip['pic']:
        msg += ', skipped frames %s fields %s, sig by fields' % (sorted(skip['pic']), sorted(skip['fsig']))
    msg += ')'
    if bad:
        msg += '; differ: ' + ' '.join(bad[:12])
    print(msg)
    sys.exit(1 if bad else 0)
