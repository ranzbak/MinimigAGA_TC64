#!/usr/bin/env python3
"""Format-parity tooling (python3 stdlib only; run as `python3 -I fmtcheck.py`).

  fmtcheck.py cover <formats.txt> <fmt_cases.h>
      every line of formats.txt has a case in fmt_cases.h
  fmtcheck.py digest [--subset] <fmt_x.txt>
      the S and P records of a full record file as the L1 bench prints them
      (fmt_run.h, FMT_DIGEST), all cases or with --subset (FMT_SUBSET) the first
      and last case of each run of equal format strings: `FMT <n> S|P h=<32-bit FNV-1a of ret, buf/out, side>`
  fmtcheck.py diff <fmt_832.txt> <fmt_rv.txt> <fmt_cases.h>
      writes the 832-versus-RV difference report on stdout (the content of
      fmt_diff_expected.txt) and exits 1 when
        - the two files do not hold the same cases,
        - fmt_832.txt differs from this file's model of lib832's printf
          (model_832(): a transcription of small_printf.c's _printfcore),
        - fmt_rv.txt differs from the model of ISO printf (the same function
          with every bug switched off), or
        - a difference cannot be explained by the known 832 printf bugs.
      The model is independent of both producers: it is the golden.

Record formats (fmt_run.h):
  FMT <n> C fmt=<hex> args=<hex>
  FMT <n> S ret=<r> buf=<hex> side=<hex>
  FMT <n> P ret=<r> out=<hex>
"""
import itertools
import re
import sys

# --------------------------------------------------------------------------
# Not format strings: inline-assembly templates the grep that builds
# formats.txt also finds (a "%0" operand reference).
NOT_FORMATS = {'"rol.w #8,%0\\n\\t"', '"swap %0\\n\\t"'}

# The known deviations of lib832's printf (the model's switches).  UPPER is a
# difference, not a bug; the others are bugs (README, "Differences").  The
# flags '-', '+', ' ', '#' are ignored by both sides of the model (lib832 ignores
# them; no firmware format uses them).
BUGS = ('UPPER', 'ZERO', 'SIGNW', 'SIGNUART', 'PREC', 'WIDTHPARSE')


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
# The model: lib832's _printfcore (small_printf.c) with switches.  A bug that
# is not in `bugs` is replaced by the C standard's behaviour for the
# conversions the firmware uses.  Returns (ret, items) with items a list of
# (char, via_uart): via_uart marks the '-' that lib832's sprintf sends to
# putchar instead of the buffer.
def model(fmt, args, bugs):
    items = []
    ret = 0

    def emit(s, uart=False):
        for ch in s:
            items.append((ch, uart))

    ai = 0
    i = 0
    while i < len(fmt):
        c = fmt[i]
        i += 1
        if c != '%':
            emit(c)
            continue
        padzero, width, prec = False, 0, None
        while i < len(fmt):
            c = fmt[i]
            i += 1
            if c == 'l':
                continue
            # WIDTHPARSE: lib832 takes a '0' anywhere as the zero flag (so %10d
            # has width 1) and does not parse the digit 9; no firmware format
            # has either, so no case ever shows it
            if c == '0' and ('WIDTHPARSE' in bugs or width == 0):
                padzero = True
                continue
            if c.isdigit() and not (c == '9' and 'WIDTHPARSE' in bugs):
                width = width * 10 + int(c)
                continue
            if c == '.' and 'PREC' not in bugs:
                prec = 0
                while i < len(fmt) and fmt[i].isdigit():
                    prec = prec * 10 + int(fmt[i])
                    i += 1
                continue
            if c in 'dDuxX':
                val = args[ai]
                ai += 1
                base = 10 if c in 'dDu' else 16
                neg = c in 'dD' and val < 0
                mag = -val if neg else val
                if c in 'uxX':
                    mag &= 0xFFFFFFFF
                digs = '0123456789ABCDEF'
                s = ''
                m = mag
                while m:
                    s = digs[m % base] + s
                    m //= base
                s = s or '0'
                if c == 'x' and 'UPPER' not in bugs:
                    s = s.lower()
                if mag == 0 and 'ZERO' in bugs:
                    emit(s)
                    ret += 1
                    break
                if 'SIGNW' in bugs:        # width counts digits only
                    if neg:
                        emit('-', 'SIGNUART' in bugs)
                    pad = max(0, width - len(s))
                    emit(('0' if padzero else ' ') * pad + s)
                    ret += pad + len(s)
                else:                      # ISO: width counts the sign
                    sign = '-' if neg else ''
                    pad = max(0, width - len(s) - len(sign))
                    if padzero:
                        emit(sign, neg and 'SIGNUART' in bugs)
                        emit('0' * pad + s)
                    else:
                        emit(' ' * pad)
                        emit(sign, neg and 'SIGNUART' in bugs)
                        emit(s)
                    ret += pad + len(s)
                break
            if c == 's':
                val = args[ai]
                ai += 1
                if prec is not None:
                    val = val[:prec]
                emit(val)
                ret += len(val) - 1
                break
            if c == '%':
                emit('%')
                ret += 1
                break
            if c in "'# -+":
                continue
            break                          # swallowed (the '.' of "%.8s")
    if 'RET' not in bugs:                  # ISO return value: bytes produced
        ret = len(items)
    return ret, items


def render(fmt, args, bugs, kind):
    ret, items = model(fmt, args, bugs)
    if kind == 'S':
        buf = ''.join(ch for ch, u in items if not u)
        side = ''.join(ch for ch, u in items if u)
        return {'ret': str(ret), 'buf': buf.encode('latin1').hex(),
                'side': side.encode('latin1').hex()}
    out = ''.join(ch for ch, u in items)
    return {'ret': str(ret), 'out': out.encode('latin1').hex()}


def show(h):
    return repr(bytes.fromhex(h).decode('latin1'))


def content(rec):
    return {k: v for k, v in rec.items() if k != 'ret'}


def cmd_diff(f832, frv, cases_h):
    c1, r1 = load(f832)
    c2, r2 = load(frv)
    defs = parse_defines(cases_h)
    if c1 != c2 or set(r1) != set(r2) or not c1:
        die('%s and %s do not hold the same cases' % (f832, frv))
    ALL = set(BUGS) | {'RET'}
    bad = 0
    lines = []
    ret_stat = {}
    for (n, kind) in sorted(r1):
        fmt, argtxt = c1[n]
        args = [eval_arg(a, defs) for a in split_args(argtxt)]
        a, b = r1[(n, kind)], r2[(n, kind)]
        if a != render(fmt, args, ALL, kind):
            print('model of lib832 disagrees with %s: case %d %s' % (f832, n, kind), file=sys.stderr)
            bad += 1
        if b != render(fmt, args, set(), kind):
            print('model of ISO printf disagrees with %s: case %d %s' % (frv, n, kind), file=sys.stderr)
            bad += 1
        st = ret_stat.setdefault(fmt, [0, 0])
        st[1] += 1
        if a['ret'] != b['ret']:
            st[0] += 1
        fields = [k for k in content(a) if a[k] != b[k]]
        if not fields:
            continue
        # smallest set of bugs whose removal turns the 832 output into the RV output
        found = None
        for k in range(1, len(BUGS) + 1):
            for sub in itertools.combinations(BUGS, k):
                if content(render(fmt, args, ALL - set(sub), kind)) == content(b):
                    found = sub
                    break
            if found:
                break
        tag = '+'.join(found) if found else 'UNEXPLAINED'
        if not found:
            bad += 1
        lines.append('case %d %s %s: %s | 832 %s | rv %s' % (
            n, kind, tag, repr(fmt) + ' ' + argtxt,
            ' '.join('%s=%s' % (k, show(a[k])) for k in fields),
            ' '.join('%s=%s' % (k, show(b[k])) for k in fields)))
    for fmt, (nd, nt) in sorted(ret_stat.items()):
        if nd:
            lines.append('RET %r: return value differs in %d of %d cases' % (fmt, nd, nt))
    sys.stdout.write('\n'.join(lines) + '\n')
    if bad:
        die('%d problems' % bad)


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
    elif len(argv) == 5 and argv[1] == 'diff':
        cmd_diff(argv[2], argv[3], argv[4])
    else:
        die(__doc__)


main(sys.argv)
