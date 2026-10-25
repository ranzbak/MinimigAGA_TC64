#!/usr/bin/env python3
"""Format-parity tooling (python3 stdlib only; run as `python3 -I fmtcheck.py`).

  fmtcheck.py cover <formats.txt> <fmt_cases.h>
      every line of formats.txt has a case in fmt_cases.h
  fmtcheck.py digest [--subset] <fmt_x.txt>
      the S and P records of a full record file as the L1 bench prints them
      (fmt_run.h, FMT_DIGEST), all cases or with --subset (FMT_SUBSET) the first
      and last case of each run of equal format strings: `FMT <n> S|P h=<32-bit FNV-1a of ret, buf/out, side>`
  fmtcheck.py iso <fmt_rv.txt> <fmt_cases.h>
      exits 1 unless fmt_rv.txt holds exactly the cases of fmt_cases.h, in
      order (format and argument text), and every S and P record equals
      this file's model of ISO C printf for those arguments (sprintf sends
      nothing to putchar: side is empty).  The model is independent of the
      producers: it is the golden.

Record formats (fmt_run.h):
  FMT <n> C fmt=<hex> args=<hex>
  FMT <n> S ret=<r> buf=<hex> side=<hex>
  FMT <n> P ret=<r> out=<hex>
"""
import re
import sys

# --------------------------------------------------------------------------
# Not format strings: inline-assembly templates the grep that builds
# formats.txt also finds (a "%0" operand reference).
NOT_FORMATS = {'"rol.w #8,%0\\n\\t"', '"swap %0\\n\\t"', '"mv %0, sp"'}


def die(msg):
    print('fmtcheck: ' + msg, file=sys.stderr)
    sys.exit(1)


def cmd_cover(formats, cases_h):
    src = open(cases_h).read()
    literals = re.findall(r'^FMT_CASE\((.*)$', src, re.M)
    missing = []
    for line in open(formats).read().splitlines():
        if not line or line in NOT_FORMATS:
            continue
        frag = line[1:-1]
        if not any(frag in lit for lit in literals):
            missing.append(line)
    for m in missing:
        print('no case for ' + m)
    if missing:
        die('%d lines of %s have no case' % (len(missing), formats))
    print('cover: every format of %s has a case' % formats)


# --------------------------------------------------------------------------
# record files
def load(path):
    cases, recs = {}, {}
    for line in open(path):
        f = line.split()
        if len(f) < 4 or f[0] != 'FMT':
            continue
        n, kind = int(f[1]), f[2]
        d = {}
        for kv in f[3:]:
            k, _, v = kv.partition('=')
            d[k] = v
        if kind == 'C':
            cases[n] = (bytes.fromhex(d['fmt']).decode('latin1'),
                        bytes.fromhex(d['args']).decode('latin1'))
        else:
            recs[(n, kind)] = d
    return cases, recs


def parse_defines(cases_h):
    out = {}
    for m in re.finditer(r'^#define (\w+)\s+"([^"]*)"', open(cases_h).read(), re.M):
        out[m.group(1)] = m.group(2)
    return out


def split_args(text):
    args, depth, cur, instr = [], 0, '', False
    for ch in text:
        if ch == '"':
            instr = not instr
        if not instr:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch == ',' and depth == 0:
                args.append(cur.strip())
                cur = ''
                continue
        cur += ch
    if cur.strip():
        args.append(cur.strip())
    return args


def eval_arg(a, defs):
    m = re.fullmatch(r'(I|U|L|UL)\((.*)\)', a)
    if m:
        t, v = m.groups()
        v = 'INT32_MIN' == v and -2**31 or int(v.rstrip('uU'), 0)
        v &= 0xFFFFFFFF
        if t in ('I', 'L') and v >= 2**31:
            v -= 2**32
        return v
    if a.startswith('"'):
        return a[1:-1]
    if a in defs:
        return defs[a]
    die('cannot evaluate argument ' + a)


# --------------------------------------------------------------------------
# The model: ISO C printf for the conversions the firmware uses (%d %u %x %X
# %s %%, the flag '0', a width, a precision on %s, the length modifier l).
# Anything else is not modelled and fails the check.  Returns the bytes
# produced; the return value is their count.
def model(fmt, args):
    out = []
    ai = 0
    i = 0
    while i < len(fmt):
        c = fmt[i]
        i += 1
        if c != '%':
            out.append(c)
            continue
        padzero, width, prec = False, 0, None
        while True:
            if i >= len(fmt):
                die('format %r: ends inside a conversion' % fmt)
            c = fmt[i]
            i += 1
            if c == 'l':
                continue
            if c == '0' and width == 0:
                padzero = True
                continue
            if c.isdigit():
                width = width * 10 + int(c)
                continue
            if c == '.':
                prec = 0
                while i < len(fmt) and fmt[i].isdigit():
                    prec = prec * 10 + int(fmt[i])
                    i += 1
                continue
            if c in 'duxX':
                val = args[ai]
                ai += 1
                neg = c == 'd' and val < 0
                mag = -val if neg else val & 0xFFFFFFFF
                base = 10 if c in 'du' else 16
                digs = '0123456789abcdef' if c == 'x' else '0123456789ABCDEF'
                s = ''
                while mag:
                    s = digs[mag % base] + s
                    mag //= base
                s = s or '0'
                sign = '-' if neg else ''
                pad = max(0, width - len(s) - len(sign))
                if padzero:
                    out.append(sign + '0' * pad + s)
                else:
                    out.append(' ' * pad + sign + s)
                break
            if c == 's':
                val = args[ai]
                ai += 1
                out.append(val if prec is None else val[:prec])
                break
            if c == '%':
                out.append('%')
                break
            die('format %r: conversion character %r is not in the model' % (fmt, c))
    return ''.join(out)


def render(fmt, args, kind):
    out = model(fmt, args).encode('latin1')
    if kind == 'S':                        # sprintf: nothing reaches putchar
        return {'ret': str(len(out)), 'buf': out.hex(), 'side': ''}
    return {'ret': str(len(out)), 'out': out.hex()}


C_ESC = {'n': '\n', 'r': '\r', 't': '\t', '"': '"', '\\': '\\'}


def parse_cases(cases_h):
    """The FMT_CASE lines of fmt_cases.h in order: (format, argument text)."""
    out = []
    for line in open(cases_h).read().splitlines():
        if not line.startswith('FMT_CASE('):
            continue
        m = re.fullmatch(r'FMT_CASE\("((?:[^"\\]|\\.)*)"\s*(?:,\s*(.*?))?\s*\)', line)
        if not m:
            die('cannot parse ' + line)
        lit, args = m.group(1), m.group(2) or ''

        def unesc(e):
            if e.group(1) not in C_ESC:
                die('escape \\%s not handled: %s' % (e.group(1), line))
            return C_ESC[e.group(1)]
        out.append((re.sub(r'\\(.)', unesc, lit), re.sub(r'\s+', ' ', args)))
    return out


def cmd_iso(frv, cases_h):
    cases, recs = load(frv)
    defs = parse_defines(cases_h)
    want = parse_cases(cases_h)
    if not want:
        die('%s holds no case' % cases_h)
    if sorted(cases) != list(range(len(want))) or \
            set(recs) != {(n, k) for n in range(len(want)) for k in 'SP'}:
        die('%s does not hold the %d cases of %s (S and P each)' % (frv, len(want), cases_h))
    bad = 0
    for n, (fmt, argtxt) in enumerate(want):
        if cases[n] != (fmt, argtxt):
            print('case %d: %s has %r %s, %s has %r %s' % (n, frv, cases[n][0], cases[n][1],
                  cases_h, fmt, argtxt), file=sys.stderr)
            bad += 1
            continue
        args = [eval_arg(a, defs) for a in split_args(argtxt)]
        for kind in 'SP':
            if recs[(n, kind)] != render(fmt, args, kind):
                print('model of ISO printf disagrees with %s: case %d %s: %r %s' % (frv, n, kind, fmt, argtxt),
                      file=sys.stderr)
                bad += 1
    if bad:
        die('%d problems' % bad)
    print('iso: the %d cases of %s, sprintf and printf, == the model of ISO printf' % (len(want), frv))


def cmd_digest(path, subset):
    cases, recs = load(path)
    nums = sorted(cases)

    def selected(n):
        i = nums.index(n)
        return (i == 0 or i == len(nums) - 1 or cases[nums[i - 1]][0] != cases[n][0]
                or cases[nums[i + 1]][0] != cases[n][0])

    def fnv(parts):
        h = 2166136261
        for b in b''.join(parts):
            h = ((h ^ b) * 16777619) & 0xFFFFFFFF
        return h

    for n in nums:
        if subset and not selected(n):
            continue
        for kind in ('S', 'P'):
            r = recs[(n, kind)]
            body = [bytes.fromhex(r['buf' if kind == 'S' else 'out']) + b'\0']
            if kind == 'S':
                body.append(bytes.fromhex(r['side']) + b'\0')
            h = fnv([r['ret'].encode() + b'\0'] + body)
            print('FMT %d %s h=%08x' % (n, kind, h))


def main(argv):
    if len(argv) == 4 and argv[1] == 'cover':
        cmd_cover(argv[2], argv[3])
    elif len(argv) in (3, 4) and argv[1] == 'digest':
        cmd_digest(argv[-1], argv[2] == '--subset')
    elif len(argv) == 4 and argv[1] == 'iso':
        cmd_iso(argv[2], argv[3])
    else:
        die(__doc__)


main(sys.argv)
