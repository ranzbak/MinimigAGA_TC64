#!/usr/bin/env python3
"""Kickstart boot checkpoints from one tb_kick trace.

usage: analyze.py <trace> --rom <kickstart image>   (ROM read by path only)

Reports: exec cold start, checksum loop, OVL release, ExecBase, the
CPU/FPU/MMU probe instructions executed (MOVEC, CINV/CPUSH, PFLUSH/PTEST,
F-line) and the exceptions that followed, every RomTag in the ROM with the
instruction index at which its init code first ran, and the final loop
(PC histogram of the last instructions).
"""
import argparse, collections, struct, sys, os
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romdis

BASE = 0xF80000


def is_floppy(a):
    a &= 0xFFFFFF
    if (a & 0xFFF000) == 0xBFD000 and ((a >> 8) & 0xF) == 1:
        return True                     # CIA-B PRB (select, motor, step, dir, side)
    if (a & 0xFFF000) == 0xBFE000 and ((a >> 8) & 0xF) == 0:
        return True                     # CIA-A PRA (/CHNG /WPRO /TK0 /RDY)
    if (a & 0xFF0000) == 0xDF0000 and (a & 0x1FE) in (0x010, 0x01A, 0x020, 0x022, 0x024, 0x07E, 0x09E):
        return True                     # ADKCONR, DSKBYTR, DSKPT, DSKLEN, DSKSYNC, ADKCON
    return False


def fdd_line(t, a, d):
    a &= 0xFFFFFF
    if (a & 0xFFF000) == 0xBFD000:
        b = d & 0xFF
        sel = [n for n in range(4) if not (b >> (3 + n)) & 1]
        return ("CIA-B PRB %s %02x  motor=%s sel=%s step=%s dir=%s side=%s"
                % (t, b, '0' if (b >> 7) & 1 else '1(on)', sel or '-',
                   'lo' if not b & 1 else 'hi', 'out' if (b >> 1) & 1 else 'in',
                   'upper' if (b >> 2) & 1 else 'lower'))
    if (a & 0xFFF000) == 0xBFE000:
        b = d & 0xFF
        return ("CIA-A PRA %s %02x  /RDY=%d /TK0=%d /WPRO=%d /CHNG=%d"
                % (t, b, (b >> 5) & 1, (b >> 4) & 1, (b >> 3) & 1, (b >> 2) & 1))
    names = {0x010: 'ADKCONR', 0x01A: 'DSKBYTR', 0x020: 'DSKPTH', 0x022: 'DSKPTL',
             0x024: 'DSKLEN', 0x07E: 'DSKSYNC', 0x09E: 'ADKCON'}
    return "%s %s %04x" % (names.get(a & 0x1FE, '???'), t, d)


def romtags(rom):
    tags = []
    off = 0
    while off < len(rom) - 26:
        if rom[off:off + 2] == b'\x4a\xfc' and struct.unpack('>I', rom[off + 2:off + 6])[0] == BASE + off:
            mt, es, fl, ver, typ, pri, name, ids, init = struct.unpack('>IIBBBbIII', rom[off + 2:off + 26])
            def cstr(a):
                if (a >> 19) != 0x1F:
                    return '?'
                o = a - BASE
                e = rom.index(b'\0', o)
                return rom[o:e].decode('latin1').strip()
            entry = init
            if fl & 0x80 and (init >> 19) == 0x1F:
                o = init - BASE
                entry = struct.unpack('>I', rom[o + 12:o + 16])[0]
            tags.append(dict(addr=BASE + off, flags=fl, ver=ver, type=typ, pri=pri, name=cstr(name),
                             ids=cstr(ids), init=init, entry=entry))
            off += 26
        else:
            off += 2
    return tags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace"); ap.add_argument("--rom", required=True)
    ap.add_argument("--tail", type=int, default=200000)
    a = ap.parse_args()
    rom = romdis.load(a.rom)
    first_pc = {}
    tail = collections.deque(maxlen=a.tail)
    exc = []
    irqs = []
    fdd = []
    writes_first = {}
    execbase = None
    n = 0
    last = None
    with open(a.trace) as f:
        for ln in f:
            if ln[0] == '#':
                continue
            p = ln.split()
            if p[0] == 'W':
                adr = int(p[2], 16)
                if is_floppy(adr):
                    fdd.append((int(p[1]), 'W', adr, int(p[4], 16)))
                if adr in (0x4, 0x6, 0xBFE001, 0xBFE201) and adr not in writes_first:
                    writes_first[adr] = (int(p[1]), p[4])
                if adr in (4, 6):
                    execbase = (execbase or 0)
                continue
            if p[0] in ('R', 'I'):
                if p[0] == 'I':
                    irqs.append((int(p[1]), int(p[2])))
                elif is_floppy(int(p[2], 16)):
                    fdd.append((int(p[1]), 'R', int(p[2], 16), int(p[3], 16)))
                continue
            if p[0] == 'X':
                exc.append((n, int(p[1], 16), p[3], p[4]))
                continue
            pc = int(p[1], 16)
            if pc not in first_pc:
                first_pc[pc] = n
            tail.append(pc)
            last = p
            n = int(p[0]) + 1
    print(f"{a.trace}: {n} instructions")
    print(f"  cold start at {int(last and 0) or 0xF800D2:08x}: {'yes' if 0xF800D2 in first_pc else 'NO'} (reset vector PC $F800D2 at #{first_pc.get(0xF800D2)})")
    # probes
    probes = []
    for pc, i in sorted(first_pc.items(), key=lambda x: x[1]):
        if (pc >> 19) != 0x1F:
            continue
        o = pc - BASE
        w = (rom[o] << 8) | rom[o + 1]
        kind = None
        if w in (0x4E7A, 0x4E7B):
            kind = 'MOVEC'
        elif (w & 0xFF00) == 0xF400:
            kind = 'CINV/CPUSH'
        elif (w & 0xFF00) == 0xF500:
            kind = 'PFLUSH/PTEST'
        elif (w & 0xF000) == 0xF000:
            kind = 'F-line'
        elif (w & 0xF000) == 0xA000:
            kind = 'A-line'
        elif w in (0x4E72,):
            kind = 'STOP'
        elif w == 0x4E70:
            kind = 'RESET'
        if kind:
            probes.append((i, pc, kind, romdis.dis1(rom, pc)[1]))
    print("  control/FPU/MMU instructions executed (first time):")
    for i, pc, kind, t in probes:
        print(f"    #{i:<9} {pc:08x} {kind:12} {t}")
    print(f"  exceptions taken: {len(exc)}")
    for i, v, sr, spc in exc[:40]:
        print(f"    at #{i:<9} vector {v:3d} stacked sr {sr} pc {spc}")
    print(f"  floppy-register accesses: {len(fdd)}")
    for n_, t_, ad, d in fdd[:60]:
        print(f"    #{n_:<9} {ad:06x} {fdd_line(t_, ad, d)}")
    if len(fdd) > 60:
        print(f"    ... {len(fdd) - 60} more")
    lv = collections.Counter(l for _, l in irqs)
    print(f"  interrupts taken out of STOP: {len(irqs)} (" + ", ".join(f"level {l}: {c}" for l, c in sorted(lv.items())) + ")")
    for adr, (i, d) in sorted(writes_first.items()):
        print(f"  first write to {adr:06x} at #{i}: {d}")
    tags = romtags(rom)
    print(f"  RomTags in ROM: {len(tags)}; init code reached (first instruction index):")
    for t in sorted(tags, key=lambda t: (first_pc.get(t['entry'], 1 << 62), -t['pri'])):
        hit = first_pc.get(t['entry'])
        fl = ''.join(c for c, b in (('A', 0x80), ('D', 0x04), ('S', 0x02), ('C', 0x01)) if t['flags'] & b)
        print(f"    {'#%-9d' % hit if hit is not None else '-         '} {t['name']:<24} pri {t['pri']:4d} flags {fl:<3} entry {t['entry']:08x}")
    h = collections.Counter(tail)
    print(f"  last {len(tail)} instructions: {len(h)} distinct PCs; hottest:")
    for pc, c in h.most_common(12):
        print(f"    {pc:08x} x{c:<8} {romdis.dis1(rom, pc)[1] if (pc >> 19) == 0x1F else '(RAM)'}")


if __name__ == "__main__":
    main()
