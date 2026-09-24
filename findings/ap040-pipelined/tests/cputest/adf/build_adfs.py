#!/usr/bin/env python3
"""Build bootable cputest ADFs from the data040 corpus.

Each disk is self-contained:
  :cputest                       (runner from cputester.7z, unmodified)
  :s/startup-sequence            runs  cputest <group>/all -continue -68040
  :data/4_<GROUP>/tmem.daz       gzip -9 -n of the group's tmem.dat (runner tries .daz first)
  :data/4_<GROUP>/lmem.daz       gzip -9 -n of the group's lmem.dat
  :data/4_<GROUP>/<INSN>/0000.daz  original file, or a slice subset ("chunk")

A chunk keeps member 0 (the header, unchanged) plus a contiguous run of slice
members; the final slice's last byte is set to 0xFF (CT_END_FINISH = "last
slice"), which is how the runner decides an instruction is complete.

usage: build_adfs.py OUTDIR EMUDIR   (EMUDIR gets variants that log to DH1:)
"""
import os, sys, struct, zlib, gzip, subprocess, json, math

SP = os.path.dirname(os.path.abspath(__file__))
DATA = '/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/findings/ap040-pipelined/tests/cputest/data040'
RUNNER = os.path.join(SP, 'cputester', 'cputest')
XDF = os.path.join(SP, 'xdf')
STAGE = os.path.join(SP, 'stage')
OUT, EMU = sys.argv[1], sys.argv[2]

# groups in priority order: (dir suffix, runner group name, allow chunking)
GROUPS = [('BASIC', 'basic', False), ('AE', 'ae', True), ('ODDSTK', 'oddstk', True),
          ('ODDIRQ', 'oddirq', True), ('ODDEXC', 'oddexc', True), ('IRQ', 'irq', True),
          ('EXTDST', 'extdst', True), ('EXTSRC', 'extsrc', True)]
PREFIX = {'BASIC': 'B', 'AE': 'AE', 'ODDSTK': 'OS', 'ODDIRQ': 'OI', 'ODDEXC': 'OE',
          'IRQ': 'IQ', 'EXTDST': 'XD', 'EXTSRC': 'XS'}

BUDGET = 444   # free FFS blocks per disk for instruction data (measured: 452 after fixed files)


def members(path):
    b = open(path, 'rb').read()
    o, out = 0, []
    while b[o:o + 4] == b'\xafMRG':
        n = struct.unpack('>I', b[o + 4:o + 8])[0]
        if n == 0:
            break
        out.append(b[o + 8:o + 8 + n])
        o += 8 + n
    return out


def rec(blob):
    return b'\xafMRG' + struct.pack('>I', len(blob)) + blob


def blocks(size):
    d = max(1, math.ceil(size / 512))
    return 1 + d + max(0, math.ceil(d / 72) - 1)   # header + data + extension blocks


def chunk_file(mem, lo, hi, total_slices):
    """header + slices lo..hi-1 (1-based slice numbers are lo..hi-1 of 1..total)."""
    parts = [rec(mem[0])]
    for i in range(lo, hi):
        blob = mem[i]
        if i == hi - 1 and hi - 1 != total_slices:
            raw = bytearray(zlib.decompress(blob, 31))
            assert raw[-2] == 0xff
            raw[-1] = 0xff
            blob = gzip.compress(bytes(raw), compresslevel=9, mtime=0)
        parts.append(rec(blob))
    return b''.join(parts) + b'\0\0\0\0'


def sort_key(n):
    return n.lower()


def plan():
    """Per group: chunk instructions that exceed one disk (if allowed) into full-disk
    chunks plus a tail, then first-fit-decreasing pack all items."""
    disks = []
    hdf_only = []
    for gdir, gname, can_chunk in GROUPS:
        gpath = os.path.join(DATA, '4_' + gdir)
        insns = sorted([d for d in os.listdir(gpath) if os.path.isdir(os.path.join(gpath, d))], key=sort_key)
        items = []
        for ins in insns:
            f = os.path.join(gpath, ins, '0000.daz')
            size = os.path.getsize(f)
            cost = 1 + blocks(size)
            if cost <= BUDGET:
                items.append({'insn': ins, 'src': f, 'whole': True, 'size': size, 'cost': cost})
                continue
            if not can_chunk:
                hdf_only.append((gdir, ins, size))
                continue
            mem = members(f)
            nsl = len(mem) - 1
            lo = 1
            while lo <= nsl:
                hi = lo + 1
                while hi <= nsl and 1 + blocks(sum(len(m) + 8 for m in [mem[0]] + mem[lo:hi + 1]) + 4) <= BUDGET:
                    hi += 1
                data = chunk_file(mem, lo, hi, nsl)
                items.append({'insn': ins, 'data': data, 'whole': False, 'size': len(data),
                              'slices': (lo, hi - 1, nsl), 'cost': 1 + blocks(len(data))})
                lo = hi
        bins = []
        for it in sorted(items, key=lambda x: -x['cost']):
            for b in bins:
                if b['used'] + it['cost'] <= BUDGET and it['insn'] not in [x['insn'] for x in b['items']]:
                    b['items'].append(it)
                    b['used'] += it['cost']
                    break
            else:
                bins.append({'group': gdir, 'gname': gname, 'items': [it], 'used': it['cost']})
        for b in bins:
            b['items'].sort(key=lambda x: (sort_key(x['insn']), x.get('slices', (0,))[0]))
        bins.sort(key=lambda b: (sort_key(b['items'][0]['insn']), b['items'][0].get('slices', (0,))[0]))
        for i, b in enumerate(bins):
            b['k'], b['n'] = i + 1, len(bins)
        disks += bins
    return disks, hdf_only


def describe(it):
    if it['whole']:
        return it['insn']
    lo, hi, n = it['slices']
    return '%s[slices %d-%d of %d]' % (it['insn'], lo, hi, n)


def sseq(d, total, idx, logname=None):
    tag = '%s-%02d' % (PREFIX[d['group']], d['k'])
    items = [describe(it) for it in d['items']]
    lines = ['; MinimigAGA 68040 cputest baseline, disk %d/%d = %s' % (idx, total, tag),
             '; group 4_%s (%d/%d of this group); runs exactly what is in :data/4_%s' % (d['group'], d['k'], d['n'], d['group'])]
    line = ';'
    for s in items:
        if len(line) + len(s) + 1 > 76:
            lines.append(line)
            line = ';'
        line += ' ' + s
    lines.append(line)
    first, last = items[0], items[-1]
    rng = first if len(items) == 1 else '%s .. %s (%d instructions)' % (first, last, len(items))
    redir = (' >DH1:%s.log' % logname) if logname else ''
    lines += [
        'Stack 16384',
        'Echo "*N=== cputest disk %s (%d/%d): group %s: %s ==="' % (tag, idx, total, d['gname'].upper(), rng),
        'Echo "Hold the left mouse button to abort."',
        ':cputest%s %s/all -continue -68040' % (redir, d['gname']),
        'Echo "*N=== END OF DISK %s. Each instruction that passed ends with *"All tests complete (total N).*" ==="' % tag,
    ]
    return '\n'.join(lines) + '\n', tag


def xdf(*args):
    r = subprocess.run([XDF] + list(args), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('xdftool failed: %s\n%s%s' % (' '.join(args), r.stdout, r.stderr))
    return r.stdout


def build(d, path, ss_text, label):
    tmpdir = os.path.join(STAGE, 'tmp')
    os.makedirs(tmpdir, exist_ok=True)
    ssf = os.path.join(tmpdir, 'startup-sequence')
    open(ssf, 'w').write(ss_text)
    g = 'data/4_' + d['group']
    cmd = ['-f', path, 'create', '+', 'format', label, 'ffs', '+', 'boot', 'install', '+',
           'makedir', 's', '+', 'write', ssf, 's/startup-sequence', '+',
           'write', RUNNER, 'cputest', '+', 'makedir', 'data', '+', 'makedir', g, '+',
           'write', os.path.join(STAGE, 'tmem.daz'), g + '/tmem.daz', '+',
           'write', os.path.join(STAGE, 'lmem.daz'), g + '/lmem.daz']
    for it in d['items']:
        src = it.get('src')
        if not it['whole']:
            src = os.path.join(tmpdir, 'chunk_%s.daz' % it['insn'])
            open(src, 'wb').write(it['data'])
        cmd += ['+', 'makedir', g + '/' + it['insn'], '+', 'write', src, g + '/' + it['insn'] + '/0000.daz']
    xdf(*cmd)
    info = xdf(path, 'info')
    free = int([l for l in info.splitlines() if l.startswith('free:')][0].split()[1])
    return free


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(EMU, exist_ok=True)
    disks, hdf_only = plan()
    total = len(disks)
    manifest = []
    for idx, d in enumerate(disks, 1):
        ss, tag = sseq(d, total, idx)
        fname = 'ct040_%02d_%s.adf' % (idx, tag)
        label = 'CT040 %02d %s' % (idx, tag)
        free = build(d, os.path.join(OUT, fname), ss, label)
        ss_emu, _ = sseq(d, total, idx, logname='%02d_%s' % (idx, tag))
        build(d, os.path.join(EMU, fname), ss_emu, label)
        manifest.append({'disk': idx, 'file': fname, 'tag': tag, 'group': d['group'],
                         'items': [describe(it) for it in d['items']], 'free_blocks': free,
                         'startup_sequence': ss})
        print('%-26s free=%3d  %s: %s' % (fname, free, d['group'], ' '.join(describe(it) for it in d['items'])))
    json.dump({'disks': manifest, 'hdf_only': hdf_only}, open(os.path.join(EMU, 'manifest.json'), 'w'), indent=1)
    print('HDF only (too big for one disk, BASIC not chunked):')
    for g, i, s in hdf_only:
        print('  %s %s %d' % (g, i, s))


if __name__ == '__main__':
    main()
